import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UIKit) && canImport(StoreKit)
import StoreKit
#endif

// MARK: - Action Context

/// Context for action execution
final class ActionContext: @unchecked Sendable {
    let navigationController: NavigationController
    let variableStore: VariableStore
    let analyticsTracker: AnalyticsTracker?
    weak var flowSession: FlowSession?

    private var _isFlowClosed = false
    private let lock = NSLock()

    var isFlowClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isFlowClosed
    }

    init(
        navigationController: NavigationController,
        variableStore: VariableStore,
        analyticsTracker: AnalyticsTracker?,
        flowSession: FlowSession?
    ) {
        self.navigationController = navigationController
        self.variableStore = variableStore
        self.analyticsTracker = analyticsTracker
        self.flowSession = flowSession
    }

    func markFlowClosed() {
        lock.lock()
        _isFlowClosed = true
        lock.unlock()
    }

    /// Resets the closed flag so the context can be reused after a flow restart
    /// (e.g. live mirror hot-reload or manual reset).
    func resetFlowClosed() {
        lock.lock()
        _isFlowClosed = false
        lock.unlock()
    }
}

// MARK: - Custom Action Handler

/// Handler for custom actions
typealias CustomActionHandler = @Sendable (
    _ params: [String: Any]?,
    _ context: ActionContext
) async throws -> Void

// MARK: - Action Executor

/// Executes component actions
final class ActionExecutor: @unchecked Sendable {
    // Configuration
    private static let actionChainTimeoutMs: UInt64 = 5000
    private static let singleActionTimeoutMs: UInt64 = 2000

    // Custom action registry
    private var customActions: [String: CustomActionHandler] = [:]
    private let lock = NSLock()

    // In-flight delayed-action tasks, keyed by the scheduling element's id (and
    // a per-task token so a finished task removes only itself). Lets a component
    // cancel its own pending hops when it leaves the hierarchy — e.g. navigating
    // away from a screen mid stepped-reveal. Without this, revisiting the screen
    // starts a fresh chain while the previous visit's sleeps are still alive, so
    // overlapping sequences fight over the bound variable and the value (a
    // stepped ring) jitters. Guarded by `lock`.
    private var scheduledTasks: [String: [UUID: Task<Void, Never>]] = [:]
    private static let unkeyedElementId = "__no_element__"

    // Error callback
    var onError: ((FlowPilotError) -> Void)?

    // MARK: - Scheduled Action Cancellation

    /// Cancel pending delayed actions scheduled by a specific element. Called
    /// when that element disappears so its in-flight stepped sequence stops
    /// cleanly instead of overlapping a fresh one on the next appearance.
    func cancelScheduledActions(for elementId: String) {
        lock.lock()
        let tasks = scheduledTasks.removeValue(forKey: elementId)
        lock.unlock()
        tasks?.values.forEach { $0.cancel() }
    }

    /// Cancel every pending delayed action (flow close / reset / hot-swap).
    func cancelAllScheduledActions() {
        lock.lock()
        let snapshot = scheduledTasks
        scheduledTasks.removeAll()
        lock.unlock()
        for tasks in snapshot.values {
            for task in tasks.values { task.cancel() }
        }
    }

    private func registerScheduledTask(_ task: Task<Void, Never>, key: String, token: UUID) {
        lock.lock(); defer { lock.unlock() }
        scheduledTasks[key, default: [:]][token] = task
    }

    private func unregisterScheduledTask(key: String, token: UUID) {
        lock.lock(); defer { lock.unlock() }
        scheduledTasks[key]?.removeValue(forKey: token)
        if scheduledTasks[key]?.isEmpty == true {
            scheduledTasks.removeValue(forKey: key)
        }
    }

    // MARK: - Custom Action Registration

    func registerCustomAction(_ key: String, handler: @escaping CustomActionHandler) {
        lock.lock()
        defer { lock.unlock() }
        customActions[key] = handler
    }

    func unregisterCustomAction(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        customActions.removeValue(forKey: key)
    }

    // MARK: - Action Execution

    /// Execute a list of actions
    /// - Parameters:
    ///   - actions: The actions to execute
    ///   - context: The action context containing navigation, variables, etc.
    ///   - payload: Optional event payload for resolving {{payload.*}} expressions
    ///   - elementId: Optional element ID for tracking
    ///   - elementType: Optional element type for tracking
    ///   - interactionType: Optional semantic interaction kind (e.g. "tap",
    ///     "toggle", "change"). When non-nil alongside `elementId` and
    ///     `elementType`, an `element_interaction` analytics event is emitted
    ///     once before the chain runs.
    func execute(
        actions: [ScheduledAction],
        context: ActionContext,
        payload: [String: Any]? = nil,
        elementId: String? = nil,
        elementType: String? = nil,
        interactionType: String? = nil
    ) async {
        // Emit element_interaction once per user-driven action chain.
        // Coupled to action execution so we don't track no-op gestures or
        // listener-less events. Skipped when the chain is empty (nothing for
        // the user to react to), when the element identity is unknown, or when
        // the caller doesn't classify the interaction (e.g. input onChange/
        // onFocus, custom-component emits — see callsites).
        if !actions.isEmpty,
           let elementId = elementId,
           let elementType = elementType,
           let interactionType = interactionType {
            context.analyticsTracker?.trackElementInteraction(
                elementId: elementId,
                elementType: elementType,
                interactionType: interactionType
            )
        }

        let chainStart = Date()

        for scheduled in actions {
            // Check if flow was closed
            guard !context.isFlowClosed else {
                Logger.shared.warn("Flow closed, cancelling remaining actions")
                return
            }

            let action = scheduled.action

            // A delayed action is dispatched on its own task at an absolute
            // offset from the chain start and runs independently, so it does
            // NOT block the rest of the chain or count against the chain
            // timeout. This is what lets `[setVariable@0, setVariable@1000,
            // ...]` walk a variable through values over time (e.g. a stepped
            // ring eased between hops). Immediate actions (no delay) keep the
            // original inline, sequential semantics and timeout budget.
            if let delay = scheduled.delay, delay > 0 {
                scheduleDelayedAction(
                    action,
                    context: context,
                    payload: payload,
                    elementId: elementId,
                    elementType: elementType,
                    delayMs: delay
                )
                continue
            }

            // Check chain timeout
            let elapsed = Date().timeIntervalSince(chainStart) * 1000
            if elapsed > Double(Self.actionChainTimeoutMs) {
                Logger.shared.error("Action chain timeout exceeded")
                onError?(.actionChainTimeout())
                return
            }

            do {
                try await executeWithTimeout(
                    action: action,
                    context: context,
                    payload: payload,
                    elementId: elementId,
                    elementType: elementType
                )
            } catch {
                let fpError: FlowPilotError
                if let flowError = error as? FlowPilotError {
                    fpError = flowError
                } else {
                    fpError = .actionError(action: action.kind, reason: error.localizedDescription)
                }

                Logger.shared.error("Action '\(action.kind)' failed: \(error)")
                onError?(fpError)

                // Continue to next action (non-fatal by default)
            }
        }
    }

    /// Dispatch a single action after `delayMs`, independent of the chain that
    /// scheduled it. The task is tracked by `elementId` so it can be cancelled
    /// when the scheduling element disappears (see `cancelScheduledActions`);
    /// without that, navigating away and back overlaps stepped sequences. The
    /// flow-closed guard is re-checked at fire time (not just at schedule time)
    /// because the delay window can outlive the screen. Sleep happens OUTSIDE
    /// `executeWithTimeout`, so the per-action timeout covers only the action's
    /// own work, not the intentional wait.
    private func scheduleDelayedAction(
        _ action: ComponentAction,
        context: ActionContext,
        payload: [String: Any]?,
        elementId: String?,
        elementType: String?,
        delayMs: Int
    ) {
        let key = elementId ?? Self.unkeyedElementId
        let token = UUID()
        let task = Task { [weak self] in
            defer { self?.unregisterScheduledTask(key: key, token: token) }

            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)

            // Cancelled because the scheduling element left the hierarchy
            // (e.g. navigated away mid-sequence) — drop this hop silently.
            if Task.isCancelled { return }
            guard let self else { return }

            guard !context.isFlowClosed else {
                Logger.shared.debug("Flow closed, skipping delayed action")
                return
            }

            do {
                try await self.executeWithTimeout(
                    action: action,
                    context: context,
                    payload: payload,
                    elementId: elementId,
                    elementType: elementType
                )
            } catch {
                let fpError: FlowPilotError
                if let flowError = error as? FlowPilotError {
                    fpError = flowError
                } else {
                    fpError = .actionError(action: action.kind, reason: error.localizedDescription)
                }

                Logger.shared.error("Delayed action '\(action.kind)' failed: \(error)")
                onError?(fpError)
            }
        }
        registerScheduledTask(task, key: key, token: token)
    }

    private func executeWithTimeout(
        action: ComponentAction,
        context: ActionContext,
        payload: [String: Any]?,
        elementId: String?,
        elementType: String?
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.executeAction(action, context: context, payload: payload, elementId: elementId, elementType: elementType)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: Self.singleActionTimeoutMs * 1_000_000)
                throw FlowPilotError.timeout()
            }

            // Wait for first to complete
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func executeAction(
        _ action: ComponentAction,
        context: ActionContext,
        payload: [String: Any]?,
        elementId: String?,
        elementType: String?
    ) async throws {
        switch action {
        case .navigate(let targetNodeId):
            await MainActor.run {
                // Look up the edge being followed for transition config
                let currentNodeId = context.navigationController.currentNodeId
                let edge = context.navigationController.findEdge(from: currentNodeId, to: targetNodeId)
                context.navigationController.navigate(to: targetNodeId, via: edge)
            }

        case .goNext:
            await MainActor.run {
                let currentNodeId = context.navigationController.currentNodeId
                context.navigationController.followDefaultEdge(from: currentNodeId)
            }

        case .goBack:
            await MainActor.run {
                // goBack() returns false when history is empty and internally
                // calls closeFlow(.dismissed) in that case — no need to call
                // closeFlow again.
                context.navigationController.goBack()
            }

        case .closeFlow:
            await MainActor.run {
                context.navigationController.closeFlow(outcome: .completed)
                context.markFlowClosed()
            }

        case .assign(let assignments):
            handleAssign(assignments: assignments, context: context)

        case .setVariable(let variableKey, let operation, let value):
            // Resolve {{payload.*}} expressions in the value if present
            let resolvedValue = resolveValueWithPayload(value, payload: payload, store: context.variableStore)
            VariableOperationExecutor.apply(
                operation: operation,
                key: variableKey,
                operand: resolvedValue,
                store: context.variableStore
            )

        case .trackEvent(let eventKey, let properties):
            let props = properties?.mapValues { $0.value }
            context.analyticsTracker?.trackCustomEvent(
                eventKey: eventKey,
                properties: props,
                elementId: elementId,
                elementType: elementType
            )

        case .openUrl(let url):
            let interpolatedUrl = context.variableStore.interpolate(url)
            await openURL(interpolatedUrl)

        case .haptic(let intensity):
            await triggerHaptic(intensity: intensity)

        case .requestReview:
            await requestReview()

        case .custom(let actionKey, let params):
            lock.lock()
            let handler = customActions[actionKey]
            lock.unlock()

            if let handler = handler {
                let paramsDict = params?.mapValues { $0.value }
                try await handler(paramsDict, context)
            } else {
                Logger.shared.warn("Custom action not registered: \(actionKey)")
            }

        case .triggerAnimation(let targetComponentId, let animation, let stepId):
            await MainActor.run {
                var userInfo: [String: Any] = [
                    "targetComponentId": targetComponentId,
                    "animation": animation
                ]
                if let stepId = stepId {
                    userInfo["stepId"] = stepId
                }
                NotificationCenter.default.post(
                    name: .triggerComponentAnimation,
                    object: nil,
                    userInfo: userInfo
                )
            }
            Logger.shared.debug("Posted triggerComponentAnimation: target=\(targetComponentId) animation=\(animation) stepId=\(stepId ?? "nil")")

        case .triggerParticle(let effect, let duration, let colors, let emoji,
                              let density, let size, let direction,
                              let spread, let gravity, let speed,
                              let delay, let haptic):
            await MainActor.run {
                var userInfo: [String: Any] = ["effect": effect]
                if let duration = duration { userInfo["duration"] = duration }
                if let colors = colors { userInfo["colors"] = colors }
                if let emoji = emoji { userInfo["emoji"] = emoji }
                if let density = density { userInfo["density"] = density }
                if let size = size { userInfo["size"] = size }
                if let direction = direction { userInfo["direction"] = direction }
                if let spread = spread { userInfo["spread"] = spread }
                if let gravity = gravity { userInfo["gravity"] = gravity }
                if let speed = speed { userInfo["speed"] = speed }
                if let delay = delay { userInfo["delay"] = delay }
                if let haptic = haptic { userInfo["haptic"] = haptic }

                NotificationCenter.default.post(
                    name: .triggerParticleEffect,
                    object: nil,
                    userInfo: userInfo
                )
            }
            Logger.shared.debug("Posted triggerParticleEffect: effect=\(effect)")
        }
    }

    // MARK: - Assign

    /// Evaluate each assignment's FlowExpression against the variable store and
    /// write the resolved value back. Assignments whose expressions can't be
    /// evaluated are skipped — the variable keeps its previous value instead of
    /// getting overwritten with `nil`.
    private func handleAssign(
        assignments: [AssignmentEntry],
        context: ActionContext
    ) {
        if assignments.isEmpty { return }

        for assignment in assignments {
            let key = assignment.variableKey
            if key.isEmpty {
                Logger.shared.warn("Assign: skipped entry with empty variableKey")
                continue
            }

            guard let resolved = ExpressionEvaluator.evaluate(
                assignment.expression,
                store: context.variableStore
            ) else {
                Logger.shared.warn(
                    "Assign: skipped \"\(key)\" — expression \"\(assignment.expression)\" did not evaluate to a value"
                )
                continue
            }

            context.variableStore.set(key, value: resolved)
        }
    }

    // MARK: - URL Opening

    @MainActor
    private func openURL(_ urlString: String) async {
        #if canImport(UIKit)
        guard let url = URL(string: urlString) else {
            Logger.shared.warn("Invalid URL: \(urlString)")
            return
        }

        if await UIApplication.shared.canOpenURL(url) {
            await UIApplication.shared.open(url)
        } else {
            Logger.shared.warn("Cannot open URL: \(urlString)")
        }
        #endif
    }

    // MARK: - Haptic Feedback

    @MainActor
    private func triggerHaptic(intensity: String) async {
        #if canImport(UIKit)
        let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch intensity {
        case "light":
            feedbackStyle = .light
        case "heavy":
            feedbackStyle = .heavy
        default:
            feedbackStyle = .medium
        }

        let generator = UIImpactFeedbackGenerator(style: feedbackStyle)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    // MARK: - App Store Review

    /// Ask the OS to present its native App Store rating prompt. Fire-and-forget:
    /// the system decides whether and when to actually show the prompt (rate
    /// limited by iOS), so there's nothing to await or surface back to the flow.
    @MainActor
    private func requestReview() async {
        #if canImport(UIKit) && canImport(StoreKit)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            Logger.shared.warn("requestReview: no active UIWindowScene")
            return
        }
        SKStoreReviewController.requestReview(in: scene)
        #endif
    }

    // MARK: - Payload Expression Resolution

    /// Resolve {{payload.*}} and {{variableName}} expressions in a VariableValue
    /// - Parameters:
    ///   - value: The value that may contain template expressions (only strings are interpolated)
    ///   - payload: The event payload to read from for {{payload.*}} expressions
    ///   - store: The variable store for {{variableName}} expressions
    /// - Returns: The resolved value, or the original value if no interpolation needed
    private func resolveValueWithPayload(
        _ value: VariableValue?,
        payload: [String: Any]?,
        store: VariableStore
    ) -> VariableValue? {
        guard let value = value else { return nil }

        // Only string values can contain template expressions
        guard case .string(let template) = value else {
            return value
        }

        // Check if this is a template expression
        guard template.contains("{{") && template.contains("}}") else {
            return value
        }

        // Resolve the template with both payload and variable store
        let resolved = interpolateWithPayload(template, payload: payload, store: store)

        // If the entire template was a single expression, try to preserve the original type
        // e.g., {{payload.height}} where height is a number should return a number
        if isSimpleExpression(template) {
            return parseResolvedValue(resolved, originalTemplate: template, payload: payload)
        }

        // For compound templates, return as string
        return .string(resolved)
    }

    /// Check if the template is a simple single expression like "{{payload.foo}}"
    private func isSimpleExpression(_ template: String) -> Bool {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("{{") &&
               trimmed.hasSuffix("}}") &&
               trimmed.dropFirst(2).dropLast(2).filter({ $0 == "{" || $0 == "}" }).isEmpty
    }

    /// Interpolate a template string, resolving both {{payload.*}} and {{variableName}} expressions
    private func interpolateWithPayload(
        _ template: String,
        payload: [String: Any]?,
        store: VariableStore
    ) -> String {
        var result = template
        let pattern = "\\{\\{([^}]+)\\}\\}"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return template
        }

        let range = NSRange(template.startIndex..., in: template)
        let matches = regex.matches(in: template, range: range)

        // Process matches in reverse order to maintain correct indices
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: template) else { continue }
            let key = String(template[keyRange]).trimmingCharacters(in: .whitespaces)

            let replacement: String

            if key.hasPrefix("payload.") {
                // Resolve from event payload
                let payloadKey = String(key.dropFirst("payload.".count))
                if let payloadValue = payload?[payloadKey] {
                    replacement = stringValue(from: payloadValue)
                } else {
                    Logger.shared.warn("Payload key '\(payloadKey)' not found in event payload")
                    replacement = ""
                }
            } else {
                // Resolve from variable store
                if let variableValue = store.get(key) {
                    replacement = variableValue.displayString
                } else {
                    replacement = ""
                }
            }

            if let fullRange = Range(match.range, in: result) {
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        return result
    }

    /// Convert any value to its string representation
    private func stringValue(from value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as Double:
            return number.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(number))" : "\(number)"
        case let number as Int:
            return "\(number)"
        case let bool as Bool:
            return bool ? "true" : "false"
        default:
            return "\(value)"
        }
    }

    /// Parse a resolved string value back to the appropriate VariableValue type
    /// based on the original payload type
    private func parseResolvedValue(
        _ resolved: String,
        originalTemplate: String,
        payload: [String: Any]?
    ) -> VariableValue {
        // Extract the key from the template
        let pattern = "\\{\\{\\s*payload\\.([^}\\s]+)\\s*\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: originalTemplate, range: NSRange(originalTemplate.startIndex..., in: originalTemplate)),
              let keyRange = Range(match.range(at: 1), in: originalTemplate) else {
            return .string(resolved)
        }

        let payloadKey = String(originalTemplate[keyRange])

        // Get the original type from payload
        if let originalValue = payload?[payloadKey] {
            switch originalValue {
            case is Int:
                if let intVal = Int(resolved) {
                    return .number(Double(intVal))
                }
            case is Double, is Float:
                if let doubleVal = Double(resolved) {
                    return .number(doubleVal)
                }
            case is Bool:
                return .boolean(resolved.lowercased() == "true")
            default:
                break
            }
        }

        // Default to string
        return .string(resolved)
    }
}
