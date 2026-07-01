import Foundation
import Combine

// MARK: - Navigation Transition Info

/// Metadata about a screen transition, published alongside screen changes.
struct NavigationTransitionInfo: Sendable {
    /// Whether this navigation is going backward (goBack).
    let isBack: Bool
    /// The edge that was traversed (if any). Carries potential per-edge transition config.
    let traversedEdge: FlowEdge?
    /// The source screen we're navigating away from.
    let sourceScreen: ScreenNode?
    /// The destination screen we're navigating to.
    let destinationScreen: ScreenNode?
}

// MARK: - Navigation History Entry

/// An entry in the navigation history stack, preserving the edge used for back-reversal.
struct NavigationHistoryEntry: Sendable {
    let nodeId: String
    /// The edge that was used to navigate away from this screen (for back-reversal).
    let forwardEdge: FlowEdge?
}

// MARK: - Navigation State

/// Current state of flow navigation
struct NavigationState: Sendable {
    var currentNodeId: String
    var history: [NavigationHistoryEntry]
    /// In-flow A/B stickiness, keyed by `ABTestNode.experimentKey` → variant id.
    var experimentAssignments: [String: String]
    /// In-flow A/B attribution, keyed by abTest `FlowNode.id` → chosen variant
    /// id. Stamped onto analytics events (`ab_assignments`) so per-variant
    /// funnels are possible; parallel to `experimentAssignments`, which is
    /// keyed by experimentKey for stickiness.
    var abAssignmentsByNode: [String: String]
    var screenIndex: Int

    init(entryNodeId: String) {
        self.currentNodeId = entryNodeId
        self.history = []
        self.experimentAssignments = [:]
        self.abAssignmentsByNode = [:]
        self.screenIndex = 0
    }
}

// MARK: - Navigation Progress Snapshot

/// A Codable snapshot of navigation state, persisted for "save user progress"
/// so a flow can resume on the screen the user last reached. Captured/restored
/// by `NavigationController.snapshotProgress()` / `restore(from:)` and stored by
/// `FlowProgressStore`.
struct NavigationProgressSnapshot: Codable, Sendable {
    let currentNodeId: String
    let history: [HistoryEntry]
    let experimentAssignments: [String: String]
    /// Persisted node→variant in-flow A/B attribution so `ab_assignments` keeps
    /// riding events after a resumed session. Optional for backward-compatible
    /// decoding of snapshots written before this field existed.
    let abAssignments: [String: String]?
    let screenIndex: Int

    struct HistoryEntry: Codable, Sendable {
        let nodeId: String
        let forwardEdge: FlowEdge?
    }
}

// MARK: - Navigation Controller

/// Controls navigation through the flow graph
final class NavigationController: @unchecked Sendable {
    // MARK: - Properties

    private var flow: FlowDefinition
    private let variableStore: VariableStore
    private var state: NavigationState
    private let lock = NSLock()

    // Node lookup caches
    private var nodesById: [String: FlowNode]
    private var edgesByFromNode: [String: [FlowEdge]]
    private var screenNodes: [ScreenNode]

    // Publishers
    private let navigationSubject = PassthroughSubject<NavigationEvent, Never>()
    var navigationPublisher: AnyPublisher<NavigationEvent, Never> {
        navigationSubject.eraseToAnyPublisher()
    }

    // Flow closure callback
    var onFlowClose: ((FlowOutcome) -> Void)?

    // Direct callback for screen display (backup for Combine)
    var onScreenDisplayed: ((ScreenNode, Int, NavigationTransitionInfo) -> Void)?

    // MARK: - Initialization

    init(flow: FlowDefinition, variableStore: VariableStore) {
        self.flow = flow
        self.variableStore = variableStore
        self.state = NavigationState(entryNodeId: flow.entryNodeId)

        // Build lookup caches
        var nodeDict: [String: FlowNode] = [:]
        var screenList: [ScreenNode] = []
        for node in flow.nodes {
            nodeDict[node.id] = node
            if case .screen(let screenNode) = node {
                screenList.append(screenNode)
            }
        }
        self.nodesById = nodeDict
        self.screenNodes = screenList

        var edgeDict: [String: [FlowEdge]] = [:]
        for edge in flow.edges {
            if edgeDict[edge.fromNodeId] == nil {
                edgeDict[edge.fromNodeId] = []
            }
            edgeDict[edge.fromNodeId]?.append(edge)
        }
        self.edgesByFromNode = edgeDict
    }

    // MARK: - Public API

    /// Get the current node
    var currentNode: FlowNode? {
        lock.lock()
        defer { lock.unlock() }
        return nodesById[state.currentNodeId]
    }

    /// Get the current screen node (if current node is a screen)
    var currentScreen: ScreenNode? {
        guard let node = currentNode, case .screen(let screen) = node else {
            return nil
        }
        return screen
    }

    /// Get the current node ID
    var currentNodeId: String {
        lock.lock()
        defer { lock.unlock() }
        return state.currentNodeId
    }

    /// Get the current screen index
    var currentScreenIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.screenIndex
    }

    /// Can we go back?
    var canGoBack: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !state.history.isEmpty
    }

    /// Get navigation history (node IDs only, for backward compatibility).
    var history: [String] {
        lock.lock()
        defer { lock.unlock() }
        return state.history.map { $0.nodeId }
    }

    /// Get experiment assignments (keyed by experimentKey, for stickiness)
    var experimentAssignments: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return state.experimentAssignments
    }

    /// Get the cumulative in-flow A/B attribution map (abTest node id → variant
    /// id) so the session/tracker can stamp it onto events as `ab_assignments`.
    var abAssignmentsByNode: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return state.abAssignmentsByNode
    }

    /// Start the flow (process entry node)
    func start() {
        Logger.shared.debug("NavigationController.start() - entryNodeId: '\(flow.entryNodeId)', nodes count: \(nodesById.count)")
        if nodesById[flow.entryNodeId] == nil {
            Logger.shared.error("Entry node not found! Available node IDs: \(Array(nodesById.keys))")
        }
        processNode(flow.entryNodeId)
    }

    /// Navigate to a specific node, optionally carrying the edge that was traversed.
    func navigate(to targetNodeId: String, via edge: FlowEdge? = nil) {
        lock.lock()

        guard nodesById[targetNodeId] != nil else {
            lock.unlock()
            Logger.shared.error("Navigation target not found: \(targetNodeId)")
            return
        }

        // Capture source screen before changing state
        let sourceScreen: ScreenNode? = {
            if case .screen(let screen) = nodesById[state.currentNodeId] {
                return screen
            }
            return nil
        }()

        // Push current screen to history (also store the edge for back-navigation reversal)
        if case .screen = nodesById[state.currentNodeId] {
            state.history.append(NavigationHistoryEntry(
                nodeId: state.currentNodeId,
                forwardEdge: edge
            ))
        }

        state.currentNodeId = targetNodeId
        lock.unlock()

        processNode(targetNodeId, sourceScreen: sourceScreen, traversedEdge: edge, isBack: false)
    }

    /// Go back in history
    @discardableResult
    func goBack() -> Bool {
        lock.lock()

        guard !state.history.isEmpty else {
            lock.unlock()
            // No history - close the flow
            closeFlow(outcome: .dismissed)
            return false
        }

        // Capture current screen as source for the back transition
        let sourceScreen: ScreenNode? = {
            if case .screen(let screen) = nodesById[state.currentNodeId] {
                return screen
            }
            return nil
        }()

        let entry = state.history.removeLast()
        state.currentNodeId = entry.nodeId

        // Get the screen node and update index
        var destinationScreen: ScreenNode?
        if let node = nodesById[entry.nodeId], case .screen(let screen) = node {
            destinationScreen = screen
            state.screenIndex = screenNodes.firstIndex(where: { $0.id == screen.id }) ?? max(0, state.screenIndex - 1)
        }

        let screenIndex = state.screenIndex
        lock.unlock()

        let transitionInfo = NavigationTransitionInfo(
            isBack: true,
            traversedEdge: entry.forwardEdge,
            sourceScreen: sourceScreen,
            destinationScreen: destinationScreen
        )

        Logger.shared.debug("Navigated back to: \(entry.nodeId)")

        // Trigger screen displayed callback FIRST to update UI (including progress bar).
        // This must happen before the Combine event so that FlowSession's currentScreen
        // is already updated when handleNavigationEvent receives .navigatedBack — matching
        // the order used by forward navigation in processScreenNode(). Firing the Combine
        // event first caused a double screenTransitionState update which could interfere
        // with SwiftUI transitions when replaceFlow fires mid-animation (live mirror).
        if let screen = destinationScreen {
            onScreenDisplayed?(screen, screenIndex, transitionInfo)
        }

        navigationSubject.send(.navigatedBack(nodeId: entry.nodeId, transitionInfo: transitionInfo))

        return true
    }

    /// Close the flow
    func closeFlow(outcome: FlowOutcome = .completed) {
        Logger.shared.info("Flow closed with outcome: \(outcome)")
        navigationSubject.send(.flowClosed(outcome: outcome))
        onFlowClose?(outcome)
    }

    // MARK: - Progress Calculation

    /// Calculate current progress (0-100)
    func calculateProgress() -> Double {
        lock.lock()
        defer { lock.unlock() }

        // Get eligible screens (those with includeInProgress != false)
        let eligibleScreens = screenNodes.filter { screen in
            screen.props?.includeInProgress != false
        }

        guard !eligibleScreens.isEmpty else { return 0 }

        // Get current screen directly from state (don't call currentScreen which would deadlock)
        let currentNodeId = state.currentNodeId
        guard let node = nodesById[currentNodeId],
              case .screen(let currentScreenNode) = node else {
            return 0
        }

        if let currentIndex = eligibleScreens.firstIndex(where: { $0.id == currentScreenNode.id }) {
            return Double(currentIndex + 1) / Double(eligibleScreens.count) * 100
        }

        // Current screen is excluded from progress: HOLD at the last eligible
        // screen before it (matches the editor's getProgressInfo). Returning 0
        // here would make the bar collapse on every interstitial / excluded
        // screen, diverging from the dashboard reference render.
        guard let currentAllIndex = screenNodes.firstIndex(where: { $0.id == currentScreenNode.id }) else {
            return 0
        }
        var lastProgressStep = 0
        var i = currentAllIndex - 1
        while i >= 0 {
            if let priorIndex = eligibleScreens.firstIndex(where: { $0.id == screenNodes[i].id }) {
                lastProgressStep = priorIndex + 1
                break
            }
            i -= 1
        }
        return Double(lastProgressStep) / Double(eligibleScreens.count) * 100
    }

    // MARK: - Flow Replacement (Live Mirror)

    /// Replaces the flow definition with a new one, rebuilding all internal caches.
    /// Used by Live Mirror for hot-reloading flow JSON from the editor.
    func replaceFlow(_ newFlow: FlowDefinition, preservingCurrentNodeId: String? = nil) {
        lock.lock()

        // Update flow definition
        self.flow = newFlow

        // Rebuild node lookup
        var nodeDict: [String: FlowNode] = [:]
        var screenList: [ScreenNode] = []
        for node in newFlow.nodes {
            nodeDict[node.id] = node
            if case .screen(let screenNode) = node {
                screenList.append(screenNode)
            }
        }
        self.nodesById = nodeDict
        self.screenNodes = screenList

        // Rebuild edge lookup
        var edgeDict: [String: [FlowEdge]] = [:]
        for edge in newFlow.edges {
            if edgeDict[edge.fromNodeId] == nil {
                edgeDict[edge.fromNodeId] = []
            }
            edgeDict[edge.fromNodeId]?.append(edge)
        }
        self.edgesByFromNode = edgeDict

        // Preserve current position if the node still exists in the new flow,
        // otherwise reset to entry. This prevents unnecessary navigation events
        // during live mirror hot-reload that would tear down the view tree.
        if let currentId = preservingCurrentNodeId, nodeDict[currentId] != nil {
            self.state.currentNodeId = currentId
            // Keep existing history intact — don't reset
        } else {
            self.state = NavigationState(entryNodeId: newFlow.entryNodeId)
        }

        lock.unlock()
    }

    // MARK: - Progress Persistence

    /// Capture the current navigation state for "save user progress".
    func snapshotProgress() -> NavigationProgressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let history = state.history.map {
            NavigationProgressSnapshot.HistoryEntry(nodeId: $0.nodeId, forwardEdge: $0.forwardEdge)
        }
        return NavigationProgressSnapshot(
            currentNodeId: state.currentNodeId,
            history: history,
            experimentAssignments: state.experimentAssignments,
            abAssignments: state.abAssignmentsByNode,
            screenIndex: state.screenIndex
        )
    }

    /// Restore navigation to a previously persisted state and display the saved
    /// screen. Returns `false` (leaving state untouched) when the snapshot can't
    /// be safely applied to the current graph — e.g. the saved screen no longer
    /// exists — so the caller can fall back to `start()`.
    @discardableResult
    func restore(from snapshot: NavigationProgressSnapshot) -> Bool {
        lock.lock()

        // The saved position must still be a real screen in this graph.
        guard let node = nodesById[snapshot.currentNodeId],
              case .screen(let screen) = node else {
            lock.unlock()
            Logger.shared.warn("Cannot restore progress: node '\(snapshot.currentNodeId)' missing or not a screen")
            return false
        }

        // Drop any history entries whose nodes no longer exist so goBack stays valid.
        let restoredHistory = snapshot.history
            .filter { nodesById[$0.nodeId] != nil }
            .map { NavigationHistoryEntry(nodeId: $0.nodeId, forwardEdge: $0.forwardEdge) }

        state.currentNodeId = snapshot.currentNodeId
        state.history = restoredHistory
        state.experimentAssignments = snapshot.experimentAssignments
        state.abAssignmentsByNode = snapshot.abAssignments ?? [:]
        state.screenIndex = screenNodes.firstIndex(where: { $0.id == screen.id }) ?? 0
        lock.unlock()

        Logger.shared.info("Restored flow progress at screen '\(screen.id)' with \(restoredHistory.count) history entries")

        // Display the restored screen (no transition) the same way forward
        // navigation does, so the presenter renders it immediately.
        processScreenNode(screen, sourceScreen: nil, traversedEdge: nil, isBack: false)
        return true
    }

    // MARK: - Node Processing

    private func processNode(_ nodeId: String, sourceScreen: ScreenNode? = nil,
                             traversedEdge: FlowEdge? = nil, isBack: Bool = false) {
        guard let node = nodesById[nodeId] else {
            Logger.shared.error("Node not found: \(nodeId)")
            return
        }

        switch node {
        case .screen(let screenNode):
            processScreenNode(screenNode, sourceScreen: sourceScreen,
                            traversedEdge: traversedEdge, isBack: isBack)

        case .condition(let conditionNode):
            processConditionNode(conditionNode)

        case .assign(let assignNode):
            processAssignNode(assignNode)

        case .abTest(let abTestNode):
            processABTestNode(abTestNode)
        }
    }

    private func processScreenNode(_ node: ScreenNode, sourceScreen: ScreenNode? = nil,
                                    traversedEdge: FlowEdge? = nil, isBack: Bool = false) {
        lock.lock()
        state.screenIndex = screenNodes.firstIndex(where: { $0.id == node.id }) ?? state.screenIndex
        let screenIndex = state.screenIndex
        lock.unlock()

        let transitionInfo = NavigationTransitionInfo(
            isBack: isBack,
            traversedEdge: traversedEdge,
            sourceScreen: sourceScreen,
            destinationScreen: node
        )

        Logger.shared.debug("Screen displayed: \(node.name) (\(node.id))")

        // Use direct callback (more reliable than Combine in some scenarios)
        Logger.shared.debug("NavigationController - calling onScreenDisplayed callback")
        onScreenDisplayed?(node, screenIndex, transitionInfo)

        // Also send via Combine for any other subscribers
        Logger.shared.debug("NavigationController - about to send screenDisplayed event via Combine")
        let event = NavigationEvent.screenDisplayed(screen: node, index: screenIndex, transitionInfo: transitionInfo)
        navigationSubject.send(event)
        Logger.shared.debug("NavigationController - screenDisplayed event sent")
    }

    private func processConditionNode(_ node: ConditionNode) {
        let result = ConditionEvaluator.evaluate(node.condition, store: variableStore)
        Logger.shared.debug("Condition \(node.id) evaluated to: \(result)")

        let edgeKind: EdgeKind = result ? .conditionTrue : .conditionFalse
        if let edge = findEdge(from: node.id, kind: edgeKind) {
            navigate(to: edge.toNodeId)
        } else {
            Logger.shared.error("No edge found for condition \(node.id) with result \(result)")
        }
    }

    private func processAssignNode(_ node: AssignNode) {
        for assignment in node.assignments {
            VariableOperationExecutor.apply(
                operation: assignment.expression.operation,
                key: assignment.variableKey,
                operand: assignment.expression.value,
                store: variableStore
            )
        }

        Logger.shared.debug("Assignments processed for node \(node.id)")

        // Continue to next node
        if let edge = findEdge(from: node.id, kind: .normal) ?? findEdge(from: node.id) {
            navigate(to: edge.toNodeId)
        }
    }

    private func processABTestNode(_ node: ABTestNode) {
        lock.lock()

        // Check for existing assignment (sticky by experimentKey).
        var variantId = state.experimentAssignments[node.experimentKey]
        // First bucketing of this node this session — gates the once-only
        // exposure emit below (re-traversals reuse the sticky assignment).
        let isFirstBucketing = (variantId == nil)

        if variantId == nil {
            // Select a new variant
            variantId = selectVariant(node.variants)
            state.experimentAssignments[node.experimentKey] = variantId
            // Record node id → chosen variant id for in-flow A/B attribution so
            // it can be stamped onto every event as `ab_assignments`.
            if let variantId {
                state.abAssignmentsByNode[node.id] = variantId
            }
        }

        lock.unlock()

        Logger.shared.debug("AB Test \(node.experimentKey) assigned variant: \(variantId ?? "none")")

        // Navigate to variant's target
        if let variant = node.variants.first(where: { $0.id == variantId }) {
            // Emit the exposure ONCE per session per abTest node — only on the
            // first bucketing. It's the per-variant denominator, so re-firing on
            // every traversal would inflate it (the prior bug).
            if isFirstBucketing {
                navigationSubject.send(.experimentAssigned(
                    nodeId: node.id,
                    experimentKey: node.experimentKey,
                    variantId: variant.id,
                    variantLabel: variant.label
                ))
            }
            navigate(to: variant.targetNodeId)
        } else {
            Logger.shared.error("Variant not found: \(variantId ?? "nil")")
        }
    }

    private func selectVariant(_ variants: [ABTestVariant]) -> String {
        let totalWeight = variants.reduce(0.0) { $0 + $1.weight }
        var random = Double.random(in: 0..<totalWeight)

        for variant in variants {
            random -= variant.weight
            if random <= 0 {
                return variant.id
            }
        }

        return variants.last?.id ?? ""
    }

    // MARK: - Edge Finding

    private func findEdge(from nodeId: String, kind: EdgeKind? = nil) -> FlowEdge? {
        guard let edges = edgesByFromNode[nodeId] else { return nil }

        if let kind = kind {
            // Sort by priority and find matching kind
            return edges
                .filter { $0.kind == kind }
                .sorted { ($0.priority ?? 0) < ($1.priority ?? 0) }
                .first
        } else {
            // Return first edge (sorted by priority)
            return edges
                .sorted { ($0.priority ?? 0) < ($1.priority ?? 0) }
                .first
        }
    }

    /// Follow the default edge from a node (used for navigation actions)
    func followDefaultEdge(from nodeId: String) {
        if let edge = findEdge(from: nodeId) {
            navigate(to: edge.toNodeId, via: edge)
        } else {
            // No outgoing edge means we've reached the end of the flow.
            // Matches Expo SDK behavior so `goNext` on the last screen
            // completes the flow instead of being a silent no-op.
            Logger.shared.debug("No outgoing edge from \(nodeId), closing flow as completed")
            closeFlow(outcome: .completed)
        }
    }

    /// Find a specific edge from one node to another.
    func findEdge(from sourceId: String, to targetId: String) -> FlowEdge? {
        edgesByFromNode[sourceId]?.first(where: { $0.toNodeId == targetId })
    }
}

// MARK: - Navigation Events

enum NavigationEvent: Sendable {
    case screenDisplayed(screen: ScreenNode, index: Int, transitionInfo: NavigationTransitionInfo)
    case navigatedBack(nodeId: String, transitionInfo: NavigationTransitionInfo)
    case experimentAssigned(nodeId: String, experimentKey: String, variantId: String, variantLabel: String?)
    case flowClosed(outcome: FlowOutcome)
}
