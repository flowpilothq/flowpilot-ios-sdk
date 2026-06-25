import Foundation
import Combine

// MARK: - Screen Transition State

/// Bundles the current screen and its transition info into a single value
/// so that FlowPresenterView can observe a single publisher and avoid
/// race conditions between separate `currentScreen` / `lastTransitionInfo` updates.
struct ScreenTransitionState {
    let screen: ScreenNode?
    let transitionInfo: NavigationTransitionInfo?
}

// MARK: - Flow Session

/// Represents an active flow presentation session
public final class FlowSession: ObservableObject, @unchecked Sendable {
    // MARK: - Properties

    public private(set) var flow: ResolvedFlow
    public let placementId: String?

    @Published public private(set) var currentScreen: ScreenNode?
    @Published private(set) var lastTransitionInfo: NavigationTransitionInfo?

    /// Bundled screen + transition info for atomic updates.
    /// FlowPresenterView observes this single property to avoid race conditions
    /// between separate `currentScreen` and `lastTransitionInfo` publishers.
    @Published private(set) var screenTransitionState = ScreenTransitionState(screen: nil, transitionInfo: nil)
    @Published public private(set) var isActive: Bool = true
    @Published private(set) var variableUpdateTrigger: Int = 0

    /// Media preload progress (0.0 to 1.0)
    @Published public private(set) var mediaPreloadProgress: Double = 0.0

    /// Whether media preloading is complete
    @Published public private(set) var isMediaPreloaded: Bool = false

    // Engine components — internal-only. Customers interact via the delegating
    // methods below (setVariable, navigate(to:), etc.) rather than poking at
    // the underlying stores directly.
    let variableStore: VariableStore
    let navigationController: NavigationController
    let analyticsTracker: AnalyticsTracker?
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext

    /// Media preloader for loading all flow content
    private let mediaPreloader: MediaPreloader

    // Timing
    private let startTime = Date()

    // Progress persistence ("save user progress")
    private let enableProgressPersistence: Bool
    private let progressUserId: String

    /// Whether this session should persist/restore progress: opt-in per flow via
    /// `settings.saveProgress`, and never for preview/mirror sessions.
    private var shouldPersistProgress: Bool {
        enableProgressPersistence && flow.definition.settings?.saveProgress == true
    }

    // Cancellables
    private var cancellables = Set<AnyCancellable>()

    // Result promise
    private var resultContinuation: CheckedContinuation<FlowResult, Never>?

    // Preload task
    private var preloadTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        flow: ResolvedFlow,
        placementId: String?,
        sdkContext: SDKContext?,
        eventService: EventService?,
        analyticsCallback: AnalyticsCallback?,
        preloadMedia: Bool = true,
        deliverySource: FlowDeliverySource = .network,
        enableProgressPersistence: Bool = true
    ) {
        self.flow = flow
        self.placementId = placementId
        self.enableProgressPersistence = enableProgressPersistence
        self.progressUserId = SessionManager.shared.userId

        // Initialize variable store
        self.variableStore = VariableStore()
        variableStore.initialize(
            variables: flow.definition.variables ?? [],
            sdkContext: sdkContext
        )
        // Seed the theme palette for `token:` color reference resolution (v9)
        variableStore.setThemeColors(flow.definition.globalStyles?.colors)

        // Initialize navigation controller
        self.navigationController = NavigationController(
            flow: flow.definition,
            variableStore: variableStore
        )

        // Initialize analytics tracker
        self.analyticsTracker = AnalyticsTracker(
            eventService: eventService,
            externalCallback: analyticsCallback
        )
        analyticsTracker?.configure(
            appId: eventService?.appId ?? "",
            placementId: placementId,
            flowId: flow.flowId,
            flowVersionId: flow.flowVersionId,
            flowVersion: flow.flowVersion,
            experimentId: flow.experimentId,
            variantId: flow.variantId,
            variantName: flow.variantName,
            deliverySource: deliverySource
        )

        // Initialize action executor
        self.actionExecutor = ActionExecutor()

        // Initialize media preloader
        self.mediaPreloader = MediaPreloader()

        // Create action context (will set flowSession after init)
        self.actionContext = ActionContext(
            navigationController: navigationController,
            variableStore: variableStore,
            analyticsTracker: analyticsTracker,
            flowSession: nil
        )

        // Set the flow session reference
        actionContext.flowSession = self

        // Setup navigation observation
        setupNavigationObserver()

        // Setup variable change observation for UI reactivity
        setupVariableObserver()

        // Setup flow close handler
        navigationController.onFlowClose = { [weak self] outcome in
            self?.handleFlowClose(outcome: outcome)
        }

        // Setup direct screen display callback (more reliable than Combine)
        navigationController.onScreenDisplayed = { [weak self] screen, index, transitionInfo in
            Logger.shared.debug("FlowSession.onScreenDisplayed callback - screen: \(screen.name)")
            self?.handleScreenDisplayed(screen: screen, index: index, transitionInfo: transitionInfo)
        }

        // Start preloading media immediately (in screen order priority)
        if preloadMedia {
            startMediaPreloading()
        } else {
            isMediaPreloaded = true
        }

        // Don't start navigation here - let the presenter start it when the view appears
        // This avoids race conditions with SwiftUI state updates
        Logger.shared.debug("FlowSession.init - session created, waiting for startNavigation() call")
    }

    // MARK: - Public Preview Initializer

    /// Creates a preview session from a ResolvedFlow.
    /// Used by the FlowPilot Preview app — skips placement resolution and suppresses analytics.
    public convenience init(
        flow: ResolvedFlow,
        suppressAnalytics: Bool = true,
        sdkContext: SDKContext? = nil
    ) {
        self.init(
            flow: flow,
            placementId: nil,
            sdkContext: sdkContext,
            eventService: nil,
            analyticsCallback: suppressAnalytics ? nil : nil,
            preloadMedia: true,
            // Preview/mirror sessions hot-swap flows constantly and must never
            // read or write persisted progress.
            enableProgressPersistence: false
        )
    }

    // MARK: - Flow Hot-Replace (Live Mirror)

    /// Replaces the entire flow definition and re-renders.
    /// Used by Live Mirror to hot-reload flow JSON from the editor.
    /// - Parameters:
    ///   - newDefinition: The updated flow definition from the editor.
    ///   - fonts: Optional font manifest from the server's enriched flow_update message.
    ///           When provided, fonts are downloaded/registered before the UI updates.
    @MainActor
    public func replaceFlow(_ newDefinition: FlowDefinition, fonts: [FontFile]? = nil) {
        if let fonts = fonts, !fonts.isEmpty {
            // Load fonts asynchronously, then apply the update.
            // Fonts already cached/registered resolve instantly (<1ms).
            Task { @MainActor in
                await FontManager.shared.loadFonts(fonts)
                self.applyFlowReplacement(newDefinition, fonts: fonts)
            }
        } else {
            applyFlowReplacement(newDefinition, fonts: nil)
        }
    }

    /// Internal implementation of flow replacement after fonts are loaded.
    @MainActor
    private func applyFlowReplacement(_ newDefinition: FlowDefinition, fonts: [FontFile]?) {
        let currentScreenId = currentScreen?.id

        // Drop any delayed hops scheduled against the outgoing definition so a
        // hot-reload doesn't fire stale stepped-reveal actions over the new flow.
        actionExecutor.cancelAllScheduledActions()

        // Update the resolved flow with new definition
        self.flow = ResolvedFlow(
            flowId: flow.flowId,
            flowVersionId: flow.flowVersionId,
            flowVersion: flow.flowVersion,
            schemaVersion: flow.schemaVersion,
            definition: newDefinition,
            mediaBaseUrl: flow.mediaBaseUrl,
            iconBaseUrl: flow.iconBaseUrl,
            fonts: fonts ?? flow.fonts
        )

        // Re-initialize navigation controller with new flow graph,
        // preserving current position when possible
        navigationController.replaceFlow(newDefinition, preservingCurrentNodeId: currentScreenId)

        // Reset flow-closed state so actions work again after a hot-reload.
        // This is needed because goBack() on the first screen marks the flow
        // closed, but in live mirror mode the view stays visible and should
        // remain interactive after replaceFlow re-initialises the graph.
        actionContext.resetFlowClosed()
        isActive = true

        // Re-initialize variables, preserving user-mutated values
        let existingValues = variableStore.getAll()
        variableStore.initialize(
            variables: newDefinition.variables ?? [],
            sdkContext: nil
        )
        // Re-seed the theme palette (live mirror pushes re-themed definitions)
        variableStore.setThemeColors(newDefinition.globalStyles?.colors)
        // Restore previously set variable values
        for (key, value) in existingValues {
            _ = variableStore.set(key, value: value)
        }

        // Check if current screen still exists in the new definition
        let updatedScreen: ScreenNode? = {
            guard let currentId = currentScreenId else { return nil }
            for node in newDefinition.nodes {
                if case .screen(let s) = node, s.id == currentId {
                    return s
                }
            }
            return nil
        }()

        if let screen = updatedScreen {
            // Screen still exists — update in place WITHOUT triggering a full navigation
            // event. This avoids tearing down and rebuilding the entire view tree, which
            // causes glitches (text rewrapping, animation resets) during live mirror edits.
            self.currentScreen = screen
            self.screenTransitionState = ScreenTransitionState(
                screen: screen,
                transitionInfo: self.lastTransitionInfo
            )
        } else {
            // Screen was removed — navigate to entry screen
            navigationController.start()
        }

        // Trigger re-render
        objectWillChange.send()
        variableUpdateTrigger += 1
    }

    // MARK: - Media Preloading

    /// Start preloading all media content in screen order priority
    private func startMediaPreloading() {
        Logger.shared.debug("FlowSession: Starting media preloading for flow \(flow.flowId)")

        // Setup progress callback
        mediaPreloader.onProgress = { [weak self] progress in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.mediaPreloadProgress = progress.progress
                if progress.isComplete {
                    self.isMediaPreloaded = true
                    Logger.shared.debug("FlowSession: Media preloading complete - \(progress.completedItems)/\(progress.totalItems) items")
                }
            }
        }

        // Start preloading in background
        preloadTask = Task { [weak self] in
            guard let self = self else { return }

            let result = await self.mediaPreloader.preloadFlow(
                self.flow,
                variableStore: self.variableStore
            )

            await MainActor.run {
                self.isMediaPreloaded = true
                Logger.shared.info("FlowSession: Preload finished - \(result.successfulItems)/\(result.totalItems) succeeded in \(result.durationMs)ms")

                if !result.failedURLs.isEmpty {
                    Logger.shared.warn("FlowSession: Failed to preload \(result.failedItems) items")
                }
            }
        }
    }

    /// Wait for media preloading to complete (optional - flow will work without waiting)
    public func waitForMediaPreload() async {
        guard !isMediaPreloaded else { return }
        await preloadTask?.value
    }

    /// Cancel ongoing media preloading
    public func cancelMediaPreload() {
        preloadTask?.cancel()
        preloadTask = nil
    }

    // MARK: - Conversion

    /// Track a purchase / paywall conversion attributed to this flow.
    ///
    /// Delegates to the session's analytics tracker, which enriches the event
    /// with the flow's full context (flow_id, flow_version_id, placement_id,
    /// experiment_id, variant_id, current screen). Safe to call after the flow
    /// has dismissed — the tracker keeps its configured context for the
    /// session's lifetime.
    ///
    /// For purchases triggered from outside an active flow callback, see
    /// `FlowPilot.trackConversion(amount:currency:productId:metadata:)`,
    /// which routes through the most-recent session automatically.
    ///
    /// - Parameters:
    ///   - amount: Purchase amount in `currency`'s decimal units.
    ///   - currency: ISO 4217 currency code (e.g. `"USD"`).
    ///   - productId: Optional product identifier (e.g. Apple IAP product ID).
    ///   - metadata: Optional dictionary of additional properties.
    public func trackConversion(
        amount: Double,
        currency: String,
        productId: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        analyticsTracker?.trackConversion(
            revenue: amount,
            currency: currency,
            productId: productId,
            metadata: metadata
        )
    }

    // MARK: - Variable Access

    /// Get the current value of a flow variable.
    public func getVariable(_ key: String) -> VariableValue? {
        variableStore.get(key)
    }

    /// Get a snapshot of all flow variables.
    public func getAllVariables() -> [String: VariableValue] {
        variableStore.getAll()
    }

    /// Set a flow variable. Returns `true` if the variable existed and was updated.
    @discardableResult
    public func setVariable(_ key: String, value: VariableValue) -> Bool {
        variableStore.set(key, value: value)
    }

    /// Reset all variables to their declared defaults, optionally merging in fresh SDK context.
    /// Useful when restarting a flow without re-resolving from the backend.
    public func resetVariables(sdkContext: SDKContext? = nil) {
        variableStore.initialize(
            variables: flow.definition.variables ?? [],
            sdkContext: sdkContext
        )
        variableStore.setThemeColors(flow.definition.globalStyles?.colors)
    }

    // MARK: - Navigation

    /// Navigate directly to a screen by its node id.
    /// Used by power-user tooling (e.g. live preview deep-linking). Bypasses
    /// the normal edge-driven traversal — call sites are responsible for
    /// ensuring the target screen is part of the active flow.
    public func navigate(to screenNodeId: String) {
        navigationController.navigate(to: screenNodeId)
    }

    // MARK: - Session Lifecycle

    /// Start the flow navigation immediately (call this after creating the session)
    public func startNavigation() {
        guard !hasStartedNavigation else {
            Logger.shared.debug("FlowSession.startNavigation() - already started, skipping")
            return
        }
        hasStartedNavigation = true

        Logger.shared.debug("FlowSession.startNavigation() called for flow: \(flow.flowId)")

        // Track flow start
        analyticsTracker?.trackFlowStarted()

        // Track experiment exposure if applicable
        if let experimentId = flow.experimentId,
           let variantId = flow.variantId {
            analyticsTracker?.trackExperimentAssigned(
                experimentKey: experimentId,
                variantId: variantId,
                variantLabel: flow.variantName
            )
        }

        // Start navigation — resuming from saved progress when enabled.
        if shouldPersistProgress, restoreSavedProgress() {
            Logger.shared.debug("FlowSession.startNavigation() resumed from saved progress")
        } else {
            Logger.shared.debug("FlowSession.startNavigation() calling navigationController.start()")
            navigationController.start()
            Logger.shared.debug("FlowSession.startNavigation() navigationController.start() returned")
        }
    }

    // MARK: - Progress Persistence

    /// Attempt to resume this flow from a previously saved snapshot. Returns
    /// `true` only when a valid snapshot for the current flow version was applied
    /// and its screen displayed; otherwise the caller starts the flow normally.
    private func restoreSavedProgress() -> Bool {
        guard let snapshot = FlowProgressStore.shared.load(flowId: flow.flowId, userId: progressUserId) else {
            return false
        }

        // The flow may have been republished since the snapshot was written; the
        // graph could differ, so only resume an exact version match.
        guard snapshot.flowVersionId == flow.flowVersionId else {
            Logger.shared.debug("Discarding saved progress: version \(snapshot.flowVersionId) != \(flow.flowVersionId)")
            FlowProgressStore.shared.clear(flowId: flow.flowId, userId: progressUserId)
            return false
        }

        // Restore answers/variables first so any re-evaluated conditions or
        // assignments downstream see the user's prior state.
        variableStore.restoreValues(snapshot.variables)

        guard navigationController.restore(from: snapshot.navigation) else {
            FlowProgressStore.shared.clear(flowId: flow.flowId, userId: progressUserId)
            return false
        }
        return true
    }

    /// Persist the current screen + variables so the flow can resume later.
    /// No-op unless `settings.saveProgress` is on and a screen is showing.
    private func persistProgress() {
        guard shouldPersistProgress, currentScreen != nil else { return }
        let snapshot = FlowProgressSnapshot(
            flowId: flow.flowId,
            flowVersionId: flow.flowVersionId,
            userId: progressUserId,
            navigation: navigationController.snapshotProgress(),
            variables: variableStore.getAll(),
            savedAt: Date()
        )
        FlowProgressStore.shared.save(snapshot)
    }

    /// Wait for the flow to complete and return the result
    public func waitForCompletion() async -> FlowResult {
        Logger.shared.debug("FlowSession.waitForCompletion() called")
        return await withCheckedContinuation { continuation in
            Logger.shared.debug("FlowSession.waitForCompletion() setting continuation")
            self.resultContinuation = continuation

            // If already inactive, resume immediately
            if !isActive {
                Logger.shared.debug("FlowSession.waitForCompletion() - already inactive, resuming immediately")
                let result = FlowResult(
                    outcome: .dismissed,
                    finalVariables: variableStore.getAll(),
                    screensVisited: navigationController.history,
                    durationMs: Int(Date().timeIntervalSince(startTime) * 1000),
                    experimentAssignments: navigationController.experimentAssignments
                )
                continuation.resume(returning: result)
                self.resultContinuation = nil
            }
        }
    }

    @available(*, deprecated, message: "Use startNavigation() followed by waitForCompletion() instead")
    public func start() async -> FlowResult {
        Logger.shared.debug("FlowSession.start() called for flow: \(flow.flowId)")
        startNavigation()
        return await waitForCompletion()
    }

    private var hasStartedNavigation = false

    public func dismiss() {
        handleFlowClose(outcome: .dismissed)
    }

    /// Abort a presentation that never produced a screen (e.g. a navigation
    /// graph dead-end). Closes the session with an `.error` outcome so the
    /// host's completion fires and the UI dismisses, rather than the user
    /// being stranded on the loading spinner. Safety net behind
    /// `ResolvedFlow.validateForPresentation()`.
    public func failPresentation() {
        guard isActive else { return }
        Logger.shared.warn("FlowSession.failPresentation() - no screen displayed; closing flow with .error")
        handleFlowClose(outcome: .error)
    }

    // MARK: - Private Methods

    private func setupNavigationObserver() {
        Logger.shared.debug("FlowSession.setupNavigationObserver() - setting up subscriber")
        navigationController.navigationPublisher
            .sink { [weak self] event in
                Logger.shared.debug("FlowSession subscriber received event: \(event)")
                // Ensure we're on main thread for UI updates
                if Thread.isMainThread {
                    self?.handleNavigationEvent(event)
                } else {
                    DispatchQueue.main.async {
                        self?.handleNavigationEvent(event)
                    }
                }
            }
            .store(in: &cancellables)
        Logger.shared.debug("FlowSession.setupNavigationObserver() - subscriber stored, cancellables count: \(cancellables.count)")
    }

    private func setupVariableObserver() {
        Logger.shared.debug("FlowSession.setupVariableObserver() - setting up variable change subscriber")
        variableStore.anyChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self else { return }
                Logger.shared.verbose("FlowSession - variable changed, triggering UI update (trigger: \(self.variableUpdateTrigger + 1))")
                self.variableUpdateTrigger += 1
                // Persist freshly-entered answers so an interruption before the
                // user advances still resumes with their input intact.
                self.persistProgress()
            }
            .store(in: &cancellables)
    }

    private func handleScreenDisplayed(screen: ScreenNode, index: Int, transitionInfo: NavigationTransitionInfo) {
        Logger.shared.debug("FlowSession.handleScreenDisplayed: \(screen.name) (id: \(screen.id))")

        // Update current screen on main thread
        // Must use MainActor to ensure @Published changes are observed correctly
        let updateScreen = { [weak self] in
            guard let self = self else { return }
            // Explicitly trigger objectWillChange for proper SwiftUI observation
            self.objectWillChange.send()
            // Set transition info BEFORE screen change so presenter can resolve transition first
            self.lastTransitionInfo = transitionInfo
            self.currentScreen = screen
            // Atomic bundled update — FlowPresenterView observes this single property
            // to resolve transition and update screen in one pass, avoiding race conditions
            self.screenTransitionState = ScreenTransitionState(screen: screen, transitionInfo: transitionInfo)
            // Increment trigger to force re-render of components that depend on navigation state
            // (e.g., progress bar in auto mode)
            self.variableUpdateTrigger += 1
            Logger.shared.debug("FlowSession - currentScreen set to: \(screen.name), trigger: \(self.variableUpdateTrigger)")
            // Checkpoint progress on every screen arrival (forward and back).
            self.persistProgress()
        }

        if Thread.isMainThread {
            updateScreen()
        } else {
            DispatchQueue.main.async(execute: updateScreen)
        }

        // Track screen view
        analyticsTracker?.trackScreenViewed(
            screenId: screen.id,
            screenName: screen.name,
            screenIndex: index
        )
    }

    private func handleNavigationEvent(_ event: NavigationEvent) {
        Logger.shared.debug("FlowSession.handleNavigationEvent: \(event)")
        switch event {
        case .screenDisplayed(let screen, let index, let transitionInfo):
            // Already handled by direct callback — only update if screen actually changed
            // to avoid overwriting the atomic screenTransitionState with a stale duplicate
            Logger.shared.debug("FlowSession.handleNavigationEvent - screenDisplayed (via Combine): \(screen.name)")
            if currentScreen?.id != screen.id {
                lastTransitionInfo = transitionInfo
                currentScreen = screen
                screenTransitionState = ScreenTransitionState(screen: screen, transitionInfo: transitionInfo)
                analyticsTracker?.trackScreenViewed(
                    screenId: screen.id,
                    screenName: screen.name,
                    screenIndex: index
                )
            }

        case .navigatedBack(_, let transitionInfo):
            // Already handled by direct callback — only update if screen actually changed
            if let node = navigationController.currentNode,
               case .screen(let screen) = node,
               currentScreen?.id != screen.id {
                lastTransitionInfo = transitionInfo
                currentScreen = screen
                screenTransitionState = ScreenTransitionState(screen: screen, transitionInfo: transitionInfo)
            }

        case .experimentAssigned(let experimentKey, let variantId, let variantLabel):
            analyticsTracker?.trackExperimentAssigned(
                experimentKey: experimentKey,
                variantId: variantId,
                variantLabel: variantLabel
            )

        case .flowClosed(let outcome):
            handleFlowClose(outcome: outcome)
        }
    }

    private func handleFlowClose(outcome: FlowOutcome) {
        guard isActive else { return }

        isActive = false

        // Snapshot the current screen BEFORE trackScreenExited clears the
        // analytics tracker's internal screen state. Otherwise the
        // subsequent trackFlowDismissed call would emit flow_exit with
        // screen_id=null, which makes the dashboard's per-screen drop-off
        // math meaningless (every flow_exit attributes to the "no screen"
        // bucket and the funnel query drops them all on the
        // `AND screen_id IS NOT NULL` predicate).
        let exitScreen = currentScreen

        // Emit screen_exit for the current screen so its dwell time lands in
        // ClickHouse. This must run before trackFlowCompleted/Dismissed so the
        // exit event is enqueued before the flush those methods trigger.
        // trackScreenExited is a no-op if no screen is active, so .error and
        // "flow never displayed a screen" cases are safe.
        analyticsTracker?.trackScreenExited()

        // Track completion/dismissal. trackFlowDismissed takes explicit
        // screen context (snapshotted above) because the tracker's
        // currentScreen* fields were nilled by trackScreenExited.
        // Completing the flow clears saved progress so the next run starts fresh.
        // A dismissal/error keeps the snapshot so the user resumes on reopen.
        if shouldPersistProgress, outcome == .completed {
            FlowProgressStore.shared.clear(flowId: flow.flowId, userId: progressUserId)
        }

        switch outcome {
        case .completed:
            analyticsTracker?.trackFlowCompleted()
        case .dismissed:
            let screenIndex = exitScreen.flatMap { screen in
                navigationController.history.firstIndex(of: screen.id)
            }
            analyticsTracker?.trackFlowDismissed(
                screenId: exitScreen?.id,
                screenName: exitScreen?.name,
                screenIndex: screenIndex
            )
        case .error:
            break
        }

        // Build result
        let result = FlowResult(
            outcome: outcome,
            finalVariables: variableStore.getAll(),
            screensVisited: navigationController.history,
            durationMs: Int(Date().timeIntervalSince(startTime) * 1000),
            experimentAssignments: navigationController.experimentAssignments
        )

        // Resume continuation
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}
