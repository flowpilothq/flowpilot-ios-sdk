import SwiftUI
import Combine

// MARK: - Flow Presenter View

/// SwiftUI view that renders flow content
@MainActor
public struct FlowPresenterView: View {
    @ObservedObject var session: FlowSession
    @State private var displayedScreen: ScreenNode?
    @State private var hasStartedNavigation = false
    @State private var screenLifecycle = ScreenLifecyclePublisher()
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    /// Safe area insets captured from the UIKit window. We read directly from
    /// UIKit rather than SwiftUI's GeometryReader because `.ignoresSafeArea`
    /// applied to child views can propagate and zero out the insets reported
    /// by GeometryReader, causing chrome safe area padding to be lost.
    @State private var capturedSafeAreaInsets: EdgeInsets = EdgeInsets()

    /// Tracks whether this is the very first screen (no transition on initial load).
    @State private var isFirstScreen = true

    /// Dynamic transition state resolved per navigation event.
    @State private var currentTransition: AnyTransition = .opacity
    @State private var currentAnimation: Animation? = nil

    /// Observes the soft keyboard height so the foreground stack (navBar +
    /// content + footer) can shift up to match the Expo SDK behavior: when
    /// the keyboard appears, the navBar stays at the top, screen content
    /// shrinks, and the footer rises just above the keyboard.
    #if os(iOS)
    @StateObject private var keyboardObserver = KeyboardObserver()
    #endif

    /// The current keyboard height that the foreground stack should pad
    /// itself by. Returns zero on non-iOS platforms.
    private var keyboardBottomInset: CGFloat {
        #if os(iOS)
        return keyboardObserver.keyboardHeight
        #else
        return 0
        #endif
    }

    public init(session: FlowSession) {
        self.session = session
    }

    public var body: some View {
        // Access variableUpdateTrigger to ensure view re-renders when variables change
        let _ = session.variableUpdateTrigger

        VStack(spacing: 0) {
            if let screen = displayedScreen {
                screenContent(for: screen)
            } else {
                loadingView
            }
        }
        .environment(\.flowGlobalStyles, session.flow.definition.globalStyles)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Keyboard avoidance: pad the foreground stack so the footer rises
        // above the keyboard and content shrinks. The `KeyboardObserver`
        // already wraps its publishes in `withAnimation(.easeOut(0.25))`,
        // so this padding animates implicitly.
        .padding(.bottom, keyboardBottomInset)
        .background {
            // Background cross-fade: use .id() + .transition(.opacity) so SwiftUI
            // cross-fades between old and new backgrounds during screen transitions.
            // The .animation() modifier ties it to the same timing as screen content.
            // `.ignoresSafeArea(.keyboard)` keeps the background full-screen so it
            // doesn't shrink up with the foreground stack when the keyboard appears.
            ZStack {
                backgroundView(for: resolvedBackground)
                    .id(backgroundIdentity)
                    .transition(.opacity)
            }
            .animation(isFirstScreen ? nil : currentAnimation, value: backgroundIdentity)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        // Opt the entire presenter out of SwiftUI's automatic keyboard
        // safe-area inset. We drive the shift ourselves via the `.padding`
        // above, so without this SwiftUI would double-shift the layout.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            // Read safe area insets from UIKit window. If the window layout
            // hasn't completed yet (e.g., during modal presentation animation),
            // the insets may be zero — schedule a follow-up read.
            let insets = Self.readSafeAreaInsetsFromWindow()
            capturedSafeAreaInsets = insets
            Logger.shared.debug("FlowPresenterView.onAppear - capturedInsets: top=\(insets.top), bottom=\(insets.bottom)")
            if insets.top == 0 && insets.bottom == 0 {
                DispatchQueue.main.async {
                    let retryInsets = Self.readSafeAreaInsetsFromWindow()
                    capturedSafeAreaInsets = retryInsets
                    Logger.shared.debug("FlowPresenterView.onAppear retry - capturedInsets: top=\(retryInsets.top), bottom=\(retryInsets.bottom)")
                }
            }
            // Start navigation when view appears (if not already started)
            if !hasStartedNavigation {
                hasStartedNavigation = true
                startNavigationAfterDelay()
            }
        }
        .onReceive(session.$screenTransitionState) { state in
            let isScreenChange = state.screen?.id != displayedScreen?.id

            if isScreenChange {
                // Actual screen navigation — resolve transition and trigger exit animations.
                resolveAndApplyTransition(for: state.transitionInfo)
                Logger.shared.debug("FlowPresenterView.onReceive - screen change: \(state.screen?.name ?? "nil")")

                if displayedScreen != nil {
                    screenLifecycle.triggerExit()
                    screenLifecycle = ScreenLifecyclePublisher()
                }
            }

            // Update screen (same ID = in-place content update, different ID = navigation)
            displayedScreen = state.screen
            if state.screen != nil && isFirstScreen {
                DispatchQueue.main.async {
                    isFirstScreen = false
                }
            }
        }
    }

    private func startNavigationAfterDelay() {
        // Small delay to ensure SwiftUI has fully set up observation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Logger.shared.debug("FlowPresenterView - starting navigation")
            session.startNavigation()
        }
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Zone Settings

    /// Resolved persistent UI (prefers new format, falls back to legacy chrome).
    private var resolvedPersistentUI: PersistentUI? {
        session.flow.definition.resolvedPersistentUI
    }

    /// Whether zones should stay fixed while content transitions.
    private var persistZonesDuringTransition: Bool {
        resolvedPersistentUI?.settings?.persistDuringTransition ?? true
    }

    /// Whether a specific zone should animate on screen change.
    /// Only zones with transitionMode "crossfade" or "reflow" should animate.
    /// "persistent" (default) means no animation — zone stays fixed.
    private func shouldAnimateZone(_ position: ZoneRenderer.ZonePosition) -> Bool {
        // Legacy: check old chrome settings for backward compat
        if let chrome = session.flow.definition.chrome {
            return chrome.settings?.animateOnScreenChange ?? false
        }
        // New schema: read per-zone transitionMode
        let pui = resolvedPersistentUI
        let mode: String?
        switch position {
        case .navigationBar:
            mode = pui?.navigationBar?.behavior?.transitionMode
        case .footer:
            mode = pui?.footer?.behavior?.transitionMode
        }
        // Only animate for crossfade/reflow; persistent (default) = no animation
        switch mode ?? "persistent" {
        case "crossfade", "reflow":
            return true
        default:
            return false
        }
    }

    /// Resolves and applies the transition for a navigation event.
    private func resolveAndApplyTransition(for transitionInfo: NavigationTransitionInfo?) {
        guard !accessibilityReduceMotion else {
            currentTransition = TransitionMapper.reduceMotionTransition()
            currentAnimation = isFirstScreen ? nil : TransitionMapper.reduceMotionAnimation()
            return
        }

        guard !isFirstScreen else {
            currentTransition = .identity
            currentAnimation = nil
            return
        }

        let config = TransitionResolver.resolve(
            transitionInfo: transitionInfo,
            flowSettings: session.flow.definition.settings,
            reverseEdgeLookup: { [weak session] fromId, toId in
                session?.navigationController.findEdge(from: fromId, to: toId)
            }
        )

        if config.resolvedType == .none {
            currentTransition = .identity
            currentAnimation = nil
        } else {
            currentTransition = TransitionMapper.transition(for: config)
            currentAnimation = TransitionMapper.animation(for: config)
        }
    }

    // MARK: - Screen Content

    @ViewBuilder
    private func screenContent(for screen: ScreenNode) -> some View {
        let ss = screen.resolvedScreenSettings
        let isHideAllZones = ss?.hideAllZones == true

        let zoneEdges: Edge.Set = {
            var edges: Edge.Set = []
            if resolvedPersistentUI?.navigationBar != nil {
                edges.insert(.top)
            }
            if resolvedPersistentUI?.footer != nil {
                edges.insert(.bottom)
            }
            if isHideAllZones {
                edges = [.top, .bottom]
            }
            return edges
        }()

        // Layout-mode selection must NOT depend on `hideAllZones`. Whether a
        // screen hides its zones is a per-screen visibility concern, not a
        // structural one: `persistentZoneLayout` already skips nav/footer/overlay
        // when `hideAllZones` is set. If we flipped layout modes here, navigating
        // to/from a hide-all-zones screen would swap the `if/else` branch that
        // hosts the `.id` + `.transition` + `.animation` container, so SwiftUI
        // would tear down/insert the whole subtree instead of animating the
        // content transition — making the flow-wide transition silently vanish
        // on that screen. Keep the layout structure stable across the flow.
        let hasZones = resolvedPersistentUI != nil

        if hasZones && persistZonesDuringTransition {
            // PERSISTENT ZONES: zones stay fixed, only content transitions.
            // (Zones are still hidden per-screen inside this layout when
            // `hideAllZones` is set.)
            persistentZoneLayout(screen: screen)
                .ignoresSafeArea(.container, edges: zoneEdges)
        } else {
            // UNIFIED: everything transitions together (or no zones)
            unifiedLayout(screen: screen, isHideAllZones: isHideAllZones)
                .ignoresSafeArea(.container, edges: zoneEdges)
        }
    }

    // MARK: - Persistent Zone Layout

    /// Zones stay fixed; only the content area animates on screen change.
    @ViewBuilder
    private func persistentZoneLayout(screen: ScreenNode) -> some View {
        let ss = screen.resolvedScreenSettings
        let hideAll = ss?.hideAllZones == true

        VStack(spacing: 0) {
            // Navigation Bar — OUTSIDE animation container
            if !hideAll, let navBar = resolvedPersistentUI?.navigationBar, navBar.visible,
               ss?.navigationBar?.visible != false {
                navigationBarView(for: screen)
            }

            // Content + Overlay in ZStack
            ZStack {
                // Animated content area — only this transitions
                ZStack {
                    screenContentView(for: screen)
                        .id(screen.id)
                        .transition(currentTransition)
                }
                .animation(currentAnimation, value: screen.id)
                .clipped()

                // Overlay — OUTSIDE animation container, floating over content
                if !hideAll, let overlay = resolvedPersistentUI?.overlay, overlay.visible,
                   ss?.overlay?.visible != false {
                    overlayView(for: screen)
                }
            }

            // Footer — OUTSIDE animation container
            if !hideAll, let footer = resolvedPersistentUI?.footer, footer.visible,
               ss?.footer?.visible != false {
                footerView(for: screen)
            }
        }
    }

    // MARK: - Unified Layout

    /// Everything (zones + content) transitions together as a single unit.
    @ViewBuilder
    private func unifiedLayout(screen: ScreenNode, isHideAllZones: Bool) -> some View {
        let ss = screen.resolvedScreenSettings

        ZStack {
            VStack(spacing: 0) {
                if !isHideAllZones, let navBar = resolvedPersistentUI?.navigationBar, navBar.visible,
                   ss?.navigationBar?.visible != false {
                    navigationBarView(for: screen)
                }

                ZStack {
                    screenContentView(for: screen)

                    if !isHideAllZones, let overlay = resolvedPersistentUI?.overlay, overlay.visible,
                       ss?.overlay?.visible != false {
                        overlayView(for: screen)
                    }
                }

                if !isHideAllZones, let footer = resolvedPersistentUI?.footer, footer.visible,
                   ss?.footer?.visible != false {
                    footerView(for: screen)
                }
            }
            .id(screen.id)
            .transition(currentTransition)
        }
        .animation(currentAnimation, value: screen.id)
    }

    // MARK: - Zone Helpers

    @ViewBuilder
    private func navigationBarView(for screen: ScreenNode) -> some View {
        ZoneRenderer(
            persistentUI: resolvedPersistentUI,
            screenSettings: screen.resolvedScreenSettings,
            variableStore: session.variableStore,
            actionExecutor: session.actionExecutor,
            actionContext: session.actionContext,
            position: .navigationBar,
            iconBaseUrl: session.flow.iconBaseUrl,
            renderTrigger: session.variableUpdateTrigger,
            safeAreaInset: capturedSafeAreaInsets.top
        )
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ZoneAnimationModifier(
            screenId: screen.id,
            animate: shouldAnimateZone(.navigationBar) && !isFirstScreen && !accessibilityReduceMotion
        ))
    }

    @ViewBuilder
    private func footerView(for screen: ScreenNode) -> some View {
        ZoneRenderer(
            persistentUI: resolvedPersistentUI,
            screenSettings: screen.resolvedScreenSettings,
            variableStore: session.variableStore,
            actionExecutor: session.actionExecutor,
            actionContext: session.actionContext,
            position: .footer,
            iconBaseUrl: session.flow.iconBaseUrl,
            renderTrigger: session.variableUpdateTrigger,
            safeAreaInset: capturedSafeAreaInsets.bottom
        )
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ZoneAnimationModifier(
            screenId: screen.id,
            animate: shouldAnimateZone(.footer) && !isFirstScreen && !accessibilityReduceMotion
        ))
    }

    @ViewBuilder
    private func overlayView(for screen: ScreenNode) -> some View {
        if let overlay = resolvedPersistentUI?.overlay {
            OverlayRenderer(
                overlay: overlay,
                screenSettings: screen.resolvedScreenSettings?.overlay,
                variableStore: session.variableStore,
                actionExecutor: session.actionExecutor,
                actionContext: session.actionContext,
                iconBaseUrl: session.flow.iconBaseUrl,
                renderTrigger: session.variableUpdateTrigger
            )
        }
    }

    // MARK: - Screen Content View

    /// The animation speed multiplier for the current screen.
    /// Defaults to 1.0 when the screen does not specify one.
    private var currentAnimationSpeed: Double {
        displayedScreen?.props?.animationSpeed ?? 1.0
    }

    @ViewBuilder
    private func screenContentView(for screen: ScreenNode) -> some View {
        let speed = screen.props?.animationSpeed ?? 1.0
        let timelineDelays = ScreenTimelineResolver.computeTimelineDelays(
            screen: screen,
            animationSpeed: speed
        )

        if let layout = screen.layout {
            let scrollBehavior = layout.props?.scrollBehavior
            let scrollEnabled = PropertyResolver.resolve(scrollBehavior, store: session.variableStore)
            let _ = Logger.shared.info("[ICON DEBUG] FlowPresenter.screenContentView: iconBaseUrl = \(session.flow.iconBaseUrl ?? "nil"), mediaBaseUrl = \(session.flow.mediaBaseUrl ?? "nil")")

            ZStack {
                if scrollEnabled == "none" || scrollEnabled == "no-scroll" {
                    ComponentRenderer(
                        node: layout,
                        variableStore: session.variableStore,
                        actionExecutor: session.actionExecutor,
                        actionContext: session.actionContext,
                        mediaBaseUrl: session.flow.mediaBaseUrl,
                        iconBaseUrl: session.flow.iconBaseUrl,
                        renderTrigger: session.variableUpdateTrigger
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(iOS)
                    .modifier(DismissKeyboardOnOutsideTapModifier())
                    #endif
                } else {
                    #if os(iOS)
                    KeyboardAwareScrollContent(
                        layout: layout,
                        session: session
                    )
                    #else
                    GeometryReader { geometry in
                        ScrollView(showsIndicators: false) {
                            ComponentRenderer(
                                node: layout,
                                variableStore: session.variableStore,
                                actionExecutor: session.actionExecutor,
                                actionContext: session.actionContext,
                                mediaBaseUrl: session.flow.mediaBaseUrl,
                                iconBaseUrl: session.flow.iconBaseUrl,
                                renderTrigger: session.variableUpdateTrigger
                            )
                            // Pin to viewport width so an over-wide child can't
                            // widen the whole scroll content and shove its
                            // full-width siblings off the right edge (see the iOS
                            // KeyboardAwareScrollContent note).
                            .frame(minWidth: geometry.size.width, maxWidth: geometry.size.width, minHeight: geometry.size.height)
                        }
                    }
                    #endif
                }

                // Particle overlay — renders above all components, passes touches through
                #if canImport(UIKit)
                ParticleOverlayView(
                    screenParticleConfig: resolveScreenParticleConfig(screen)
                )
                #endif
            }
            .modifier(timelineParticleModifier(for: screen, speed: speed))
            .environment(\.screenLifecyclePublisher, screenLifecycle)
            .environment(\.animationSpeedMultiplier, speed)
            .environment(\.timelineDelays, timelineDelays)
        } else {
            Spacer()
            Text("No content")
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    /// Resolves the screen-level particle effect configuration, if enabled.
    private func resolveScreenParticleConfig(_ screen: ScreenNode) -> ParticleEffectConfig? {
        guard let pe = screen.props?.particleEffect,
              pe.enabled else { return nil }

        var dict = pe.toConfigDict()
        // Apply trigger-based delay: "afterDelay" uses the delay field, "onAppear" uses 0
        if pe.trigger == "onAppear" {
            dict["delay"] = 0
        }
        return ParticleEffectConfig.from(dict: dict)
    }

    /// Creates a modifier that schedules particle timeline events for the screen.
    #if canImport(UIKit)
    private func timelineParticleModifier(for screen: ScreenNode, speed: Double) -> TimelineParticleScheduler {
        let events = ScreenTimelineResolver.computeParticleEvents(
            screen: screen,
            animationSpeed: speed
        )
        return TimelineParticleScheduler(events: events)
    }
    #else
    private func timelineParticleModifier(for screen: ScreenNode, speed: Double) -> EmptyModifier {
        return EmptyModifier()
    }
    #endif

    private var resolvedBackground: ResolvedBackground {
        guard let screen = displayedScreen else {
            return ResolvedBackground(layers: [], source: .default)
        }
        return resolveScreenBackground(screen: screen, flow: session.flow.definition)
    }

    /// A stable identity for the background that changes only when the background
    /// layers actually differ. This drives the `.id()` / `.transition(.opacity)`
    /// cross-fade: when two consecutive screens share the same background, the id
    /// stays the same and no transition fires. When they differ, the id changes
    /// and SwiftUI cross-fades between the old and new background views.
    private var backgroundIdentity: String {
        let bg = resolvedBackground
        if bg.layers.isEmpty {
            return "__default__"
        }
        // Build a stable identity from layer ids and their key visual properties.
        // This ensures the cross-fade only fires when the visual output changes.
        return bg.layers.map { layer in
            var parts = [layer.id, layer.type.rawValue, String(layer.enabled)]
            if let color = layer.color { parts.append(color) }
            if let opacity = layer.opacity { parts.append(String(opacity)) }
            if let gradient = layer.gradient {
                parts.append(gradient.type.rawValue)
                parts.append(contentsOf: gradient.colors.map { "\($0.color)@\($0.position)" })
                if let angle = gradient.angle { parts.append("a\(angle)") }
            }
            if let image = layer.image { parts.append(image.src) }
            if let motion = layer.motion { parts.append(motion.preset.rawValue) }
            return parts.joined(separator: "|")
        }.joined(separator: ";;")
    }

    /// Renders the background for a resolved background value.
    @ViewBuilder
    private func backgroundView(for bg: ResolvedBackground) -> some View {
        if bg.layers.isEmpty {
            defaultBackgroundColor
        } else {
            BackgroundRenderer(
                layers: bg.layers,
                reducedMotion: accessibilityReduceMotion
            )
        }
    }

    private var defaultBackgroundColor: Color {
        #if canImport(UIKit)
        return Color(UIColor.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }

    /// Reads safe area insets directly from the UIKit window.
    ///
    /// This is more reliable than SwiftUI's GeometryReader because
    /// `.ignoresSafeArea` modifiers on child views can propagate and
    /// zero out the insets reported by GeometryReader.
    private static func readSafeAreaInsetsFromWindow() -> EdgeInsets {
        #if canImport(UIKit)
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = windowScene.windows.first
        else {
            return EdgeInsets()
        }
        let insets = window.safeAreaInsets
        return EdgeInsets(
            top: insets.top,
            leading: insets.left,
            bottom: insets.bottom,
            trailing: insets.right
        )
        #else
        return EdgeInsets()
        #endif
    }
}

// MARK: - Zone Animation Modifier

/// Applies a cross-fade animation to zone content when the screen changes.
///
/// When `animate` is true, the zone briefly fades out and back in (200ms total)
/// so that content updates (progress bar, title, buttons) look smooth rather than
/// snapping instantly. Gated by zone transition mode or legacy `animateOnScreenChange`.
private struct ZoneAnimationModifier: ViewModifier {
    let screenId: String
    let animate: Bool

    @State private var opacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onChange(of: screenId) { _ in
                guard animate else { return }
                // Fade out, then fade back in after content updates
                withAnimation(.easeOut(duration: 0.1)) {
                    opacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeIn(duration: 0.1)) {
                        opacity = 1.0
                    }
                }
            }
    }
}

// MARK: - Flow Presenter Modifier

#if canImport(UIKit)
import UIKit

/// ViewModifier that presents flows using a UIKit window overlay
/// This is the only bulletproof way to show content on top of everything
public struct FlowPresenterModifier: ViewModifier {
    @Binding var session: FlowSession?
    let onResult: ((FlowResult) -> Void)?

    public func body(content: Content) -> some View {
        let _ = Logger.shared.debug("FlowPresenterModifier.body - session: \(session != nil ? "SET" : "nil")")

        return content
            .onAppear {
                Logger.shared.debug("FlowPresenterModifier.onAppear - session: \(session != nil ? "SET" : "nil")")
                checkAndPresent()
            }
            .onChange(of: session != nil) { hasSession in
                Logger.shared.debug("FlowPresenterModifier.onChange - hasSession: \(hasSession), session: \(session != nil ? "SET" : "nil")")
                checkAndPresent()
            }
    }

    @MainActor
    private func checkAndPresent() {
        Logger.shared.debug("FlowPresenterModifier.checkAndPresent - session: \(session != nil ? "SET" : "nil")")
        if let session = session {
            Logger.shared.debug("FlowPresenterModifier - presenting session")
            FlowWindowPresenter.shared.present(session: session) { result in
                self.session = nil
                onResult?(result)
            }
        }
        // Don't call dismiss here - let the completion handler handle it
    }
}

/// Singleton that manages modal presentation of flows
@MainActor
class FlowWindowPresenter {
    static let shared = FlowWindowPresenter()

    private var hostingController: UIHostingController<FlowWindowContent>?
    private var currentSession: FlowSession?
    private var completionHandler: ((FlowResult) -> Void)?
    private var completionTask: Task<Void, Never>?

    private init() {}

    func present(session: FlowSession, completion: @escaping (FlowResult) -> Void) {
        // Don't present if already presenting
        if hostingController != nil {
            Logger.shared.debug("FlowWindowPresenter: Already presenting, ignoring")
            return
        }

        currentSession = session
        completionHandler = completion

        // Find the topmost view controller and present from there
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first?.rootViewController
        else {
            Logger.shared.error("FlowWindowPresenter: No root view controller found")
            return
        }

        // Find the topmost presented controller
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        Logger.shared.debug("FlowWindowPresenter: Found top VC: \(type(of: topVC)), presenting from it")

        // Create the flow content
        let contentView = FlowWindowContent(
            session: session,
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let hostingController = UIHostingController(rootView: contentView)
        hostingController.modalPresentationStyle = .fullScreen
        hostingController.modalTransitionStyle = .coverVertical
        hostingController.view.backgroundColor = .systemBackground

        self.hostingController = hostingController

        // NOTE: Navigation is started by FlowWindowContent.onAppear
        // This ensures SwiftUI's observation is ready before state changes

        // Wait for completion
        self.completionTask = Task { [weak self] in
            let result = await session.waitForCompletion()
            await MainActor.run {
                self?.handleCompletion(result: result)
            }
        }

        // Present modally - use DispatchQueue to ensure we're not in a SwiftUI update cycle
        DispatchQueue.main.async { [weak self] in
            // Check if topVC can present
            guard topVC.view.window != nil else {
                Logger.shared.error("FlowWindowPresenter: topVC is not in window hierarchy!")
                self?.hostingController = nil
                return
            }

            guard topVC.presentedViewController == nil else {
                Logger.shared.error("FlowWindowPresenter: topVC is already presenting something!")
                self?.hostingController = nil
                return
            }

            Logger.shared.debug("FlowWindowPresenter: Calling present() on \(type(of: topVC)), view.window: \(topVC.view.window != nil)")
            topVC.present(hostingController, animated: true) {
                Logger.shared.debug("FlowWindowPresenter: Modal presentation completed")
            }
        }

        Logger.shared.debug("FlowWindowPresenter: Scheduled modal presentation")
    }

    func dismiss() {
        completionTask?.cancel()
        completionTask = nil

        // Dismiss the presented controller
        if let hc = hostingController {
            hc.dismiss(animated: true)
        }
        hostingController = nil

        // If session is still active, dismiss it
        if let session = currentSession, session.isActive {
            session.dismiss()
        }
        currentSession = nil

        Logger.shared.debug("FlowWindowPresenter: Dismissed flow")
    }

    private func handleCompletion(result: FlowResult) {
        let handler = completionHandler
        completionHandler = nil

        dismiss()
        handler?(result)
    }
}

/// Content view for the flow window
private struct FlowWindowContent: View {
    @ObservedObject var session: FlowSession
    let onDismiss: () -> Void

    var body: some View {
        let _ = Logger.shared.debug("FlowWindowContent.body - currentScreen: \(session.currentScreen?.name ?? "nil"), trigger: \(session.variableUpdateTrigger)")

        // FlowPresenterView handles navigation start internally
        FlowPresenterView(session: session)
    }
}

#else
// macOS fallback
public struct FlowPresenterModifier: ViewModifier {
    @Binding var session: FlowSession?
    let onResult: ((FlowResult) -> Void)?

    public func body(content: Content) -> some View {
        content
            .sheet(item: $session) { activeSession in
                // FlowPresenterView handles navigation start internally
                FlowPresenterView(session: activeSession)
                    .task {
                        let result = await activeSession.waitForCompletion()
                        session = nil
                        onResult?(result)
                    }
            }
    }
}
#endif

// MARK: - Flow Hosting Controller (UIKit)

#if canImport(UIKit)

/// UIKit hosting controller for presenting flows programmatically
@MainActor
public class FlowHostingController: UIHostingController<FlowPresenterView> {
    private let session: FlowSession
    private var completionHandler: ((FlowResult) -> Void)?
    private var completionTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    /// How long to wait for the first screen before treating the presentation
    /// as stuck and bailing out (so the user never sits on the loading spinner
    /// forever after a navigation dead-end).
    private let presentationWatchdogSeconds: UInt64 = 6

    public init(session: FlowSession) {
        self.session = session
        super.init(rootView: FlowPresenterView(session: session))

        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .coverVertical
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // NOTE: Navigation is now started by FlowPresenterView.onAppear
        // This ensures proper SwiftUI observation is set up

        // Wait for completion
        completionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let result = await self.session.waitForCompletion()
            self.completionHandler?(result)
            self.dismiss(animated: true)
        }

        // Presentation watchdog: if navigation never produces a screen (e.g. a
        // graph dead-end or an empty flow that slipped past validation), don't
        // hang on the loading spinner — fail the presentation so this controller
        // dismisses and the host's completion fires.
        watchdogTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: self.presentationWatchdogSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if self.session.isActive && self.session.currentScreen == nil {
                Logger.shared.warn("FlowHostingController: no screen displayed within watchdog window - failing presentation")
                self.session.failPresentation()
            }
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        completionTask?.cancel()
        watchdogTask?.cancel()
    }

    /// Set a completion handler to be called when the flow completes
    public func onCompletion(_ handler: @escaping (FlowResult) -> Void) {
        self.completionHandler = handler
    }
}
#endif

// MARK: - FlowSession Identifiable Conformance

extension FlowSession: Identifiable {
    public var id: String {
        "\(flow.flowId)_\(ObjectIdentifier(self).hashValue)"
    }
}

// MARK: - View Extension

extension View {
    /// Present a flow when the session is set
    public func flowPresenter(
        session: Binding<FlowSession?>,
        onResult: ((FlowResult) -> Void)? = nil
    ) -> some View {
        modifier(FlowPresenterModifier(session: session, onResult: onResult))
    }
}

// MARK: - Keyboard Helpers

#if os(iOS)

/// Adds `scrollDismissesKeyboard` (iOS 16+) and a UIKit tap-to-dismiss that
/// excludes taps landing on text inputs. The previous SwiftUI
/// `simultaneousGesture(TapGesture())` fired on the same tap that focused an
/// input, which immediately resigned the just-focused responder and caused
/// the keyboard to flicker open-and-shut.
struct ScrollDismissKeyboardModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .scrollDismissesKeyboard(.interactively)
                .modifier(DismissKeyboardOnOutsideTapModifier())
        } else {
            content
                .modifier(DismissKeyboardOnOutsideTapModifier())
        }
    }
}

/// Installs a UIKit `UITapGestureRecognizer` on the host view that dismisses
/// the keyboard on taps outside text inputs. Unlike SwiftUI's
/// `simultaneousGesture(TapGesture())`, this gesture is gated by a delegate
/// that skips touches landing on `UITextField`, `UITextView`, or any
/// `UIControl`, so tapping an input does not race with — and cancel — the
/// focus that the tap is granting.
struct DismissKeyboardOnOutsideTapModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(KeyboardDismissTapInstaller())
    }
}

/// Transparent SwiftUI-bridged view that mounts a tap recognizer on its
/// host UIView. The recognizer has `cancelsTouchesInView = false` so it
/// never blocks subview touches; it only fires `resignFirstResponder` for
/// taps that the delegate accepts.
private struct KeyboardDismissTapInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.onMoveToWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.install(on: window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class HostView: UIView {
        var onMoveToWindow: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onMoveToWindow?(window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private weak var recognizer: UITapGestureRecognizer?

        func install(on window: UIWindow?) {
            uninstall()
            guard let window = window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            self.window = window
            self.recognizer = tap
        }

        func uninstall() {
            if let tap = recognizer, let window = window {
                window.removeGestureRecognizer(tap)
            }
            recognizer = nil
            window = nil
        }

        @objc func handleTap() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            var view: UIView? = touch.view
            while let v = view {
                if v is UITextField || v is UITextView || v is UIControl {
                    return false
                }
                view = v.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Observes keyboard height and publishes it for keyboard avoidance.
final class KeyboardObserver: ObservableObject {
    @Published var keyboardHeight: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .compactMap { notification -> CGFloat? in
                (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                withAnimation(.easeOut(duration: 0.25)) {
                    self?.keyboardHeight = height
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    self?.keyboardHeight = 0
                }
            }
            .store(in: &cancellables)
    }
}

/// ScrollView wrapper that scrolls a focused input into view when the
/// keyboard appears. The parent `FlowPresenterView` now pads its foreground
/// stack by the keyboard height so the scroll container is already shrunk
/// to the visible area — no inner bottom padding is needed here (it would
/// double-pad). We still keep `ScrollViewReader.scrollTo` so a focused
/// input inside a long scroll list is brought into the visible area.
struct KeyboardAwareScrollContent: View {
    let layout: ComponentNode
    @ObservedObject var session: FlowSession
    @StateObject private var keyboardObserver = KeyboardObserver()
    @State private var focusedNodeId: String? = nil

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView(showsIndicators: false) {
                    ComponentRenderer(
                        node: layout,
                        variableStore: session.variableStore,
                        actionExecutor: session.actionExecutor,
                        actionContext: session.actionContext,
                        mediaBaseUrl: session.flow.mediaBaseUrl,
                        iconBaseUrl: session.flow.iconBaseUrl,
                        renderTrigger: session.variableUpdateTrigger
                    )
                    // Pin the scroll content to the viewport width (not maxWidth:
                    // .infinity). A vertical ScrollView sizes its content to the
                    // widest child, so any single over-wide child (e.g. a row of
                    // fixed-width logos wider than the screen) would otherwise
                    // widen the whole content and drag every full-width sibling
                    // off the right edge. Hard-pinning keeps siblings at the
                    // viewport width and lets only the over-wide child spill —
                    // matching the editor (CSS flex container width is fixed).
                    .frame(minWidth: geometry.size.width, maxWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .modifier(ScrollDismissKeyboardModifier())
                .onReceive(NotificationCenter.default.publisher(for: .flowPilotInputFocused)) { notification in
                    if let nodeId = notification.userInfo?["nodeId"] as? String {
                        focusedNodeId = nodeId
                    }
                }
                .onChange(of: keyboardObserver.keyboardHeight) { height in
                    // Scroll to the focused input after keyboard finishes appearing
                    if height > 0, let nodeId = focusedNodeId {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeOut(duration: 0.25)) {
                                scrollProxy.scrollTo(nodeId, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
}

#endif
