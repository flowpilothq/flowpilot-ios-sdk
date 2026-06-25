import Foundation

// MARK: - Schema Version Constants

/// SDK schema version constants
enum SchemaVersion {
    static let minSupported = "1.0.0"
    static let maxSupported = "1.0.0"
}

// MARK: - Flow Definition

/// Complete flow definition
public struct FlowDefinition: Codable, Sendable {
    public let id: String
    public let name: String
    public let version: Int
    public let schemaVersion: String
    public let nodes: [FlowNode]
    let edges: [FlowEdge]
    public let entryNodeId: String
    /// New persistent UI zones (navigationBar, footer, overlay)
    let persistentUI: PersistentUI?
    /// @deprecated Use persistentUI. Kept for backward compatibility.
    let chrome: GlobalChrome?
    let variables: [FlowVariable]?
    let globalStyles: FlowGlobalStyles?
    let settings: FlowSettings?
    let background: ScreenBackground?  // Flow-level default background

    enum CodingKeys: String, CodingKey {
        case id, name, version, schemaVersion, nodes, edges, entryNodeId
        case persistentUI, chrome, variables, globalStyles, settings, background
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // id and name may not be present in flow_schema (they come from parent response)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1

        // Handle schemaVersion as either String or Int
        if let stringVersion = try? container.decodeIfPresent(String.self, forKey: .schemaVersion) {
            schemaVersion = stringVersion
        } else if let intVersion = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion) {
            schemaVersion = "\(intVersion).0.0"
        } else {
            schemaVersion = "1.0.0"
        }

        // Decode nodes individually so one bad node doesn't fail the entire array
        do {
            var decodedNodes: [FlowNode] = []
            var nodesContainer = try container.nestedUnkeyedContainer(forKey: .nodes)
            while !nodesContainer.isAtEnd {
                do {
                    let node = try nodesContainer.decode(FlowNode.self)
                    decodedNodes.append(node)
                } catch {
                    Logger.shared.error("FlowDefinition: Failed to decode node at index \(decodedNodes.count): \(error)")
                    // Skip the bad element — advance the container past it
                    _ = try? nodesContainer.decode(AnyCodable.self)
                }
            }
            nodes = decodedNodes
            Logger.shared.debug("FlowDefinition: Successfully decoded \(nodes.count) nodes")
        } catch {
            Logger.shared.error("FlowDefinition: Failed to decode nodes container: \(error)")
            nodes = []
        }
        edges = try container.decodeIfPresent([FlowEdge].self, forKey: .edges) ?? []

        // Handle entryNodeId - use first screen node if empty
        let rawEntryNodeId = try container.decodeIfPresent(String.self, forKey: .entryNodeId) ?? ""
        Logger.shared.debug("FlowDefinition: rawEntryNodeId = '\(rawEntryNodeId)'")
        if rawEntryNodeId.isEmpty {
            Logger.shared.debug("FlowDefinition: entryNodeId is empty, looking for fallback. Nodes count: \(nodes.count)")
            // Find first screen node as default entry point
            if let firstScreenNode = nodes.first(where: {
                if case .screen = $0 { return true }
                return false
            }) {
                entryNodeId = firstScreenNode.id
                Logger.shared.debug("FlowDefinition: Using first screen node as entry: \(entryNodeId)")
            } else if let firstNode = nodes.first {
                entryNodeId = firstNode.id
                Logger.shared.debug("FlowDefinition: Using first node as entry: \(entryNodeId)")
            } else {
                entryNodeId = ""
                Logger.shared.error("FlowDefinition: No nodes found, entryNodeId is empty!")
            }
        } else {
            entryNodeId = rawEntryNodeId
            Logger.shared.debug("FlowDefinition: Using provided entryNodeId: \(entryNodeId)")
        }

        persistentUI = try container.decodeIfPresent(PersistentUI.self, forKey: .persistentUI)
        chrome = try container.decodeIfPresent(GlobalChrome.self, forKey: .chrome)
        variables = try container.decodeIfPresent([FlowVariable].self, forKey: .variables)
        globalStyles = try container.decodeIfPresent(FlowGlobalStyles.self, forKey: .globalStyles)
        settings = try container.decodeIfPresent(FlowSettings.self, forKey: .settings)
        background = try container.decodeIfPresent(ScreenBackground.self, forKey: .background)
    }

    /// Resolved persistent UI — prefers persistentUI, falls back to migrated chrome.
    var resolvedPersistentUI: PersistentUI? {
        if let p = persistentUI { return p }
        guard let chrome = chrome else { return nil }
        return PersistentUI(
            navigationBar: chrome.header.map { section in
                PersistentZone(
                    id: section.id,
                    visible: section.visible,
                    layout: section.layout,
                    behavior: ZoneBehavior(
                        allowScreenOverride: section.behavior?.allowScreenOverride,
                        transitionMode: section.behavior?.animateIndependently != false ? "crossfade" : "persistent"
                    ),
                    props: section.props.map { ZoneProps(backgroundColor: $0.backgroundColor, padding: $0.padding, safeArea: $0.safeArea) }
                )
            },
            footer: chrome.footer.map { section in
                PersistentZone(
                    id: section.id,
                    visible: section.visible,
                    layout: section.layout,
                    behavior: ZoneBehavior(
                        allowScreenOverride: section.behavior?.allowScreenOverride,
                        transitionMode: section.behavior?.animateIndependently != false ? "crossfade" : "persistent"
                    ),
                    props: section.props.map { ZoneProps(backgroundColor: $0.backgroundColor, padding: $0.padding, safeArea: $0.safeArea) }
                )
            },
            overlay: nil,
            settings: chrome.settings.map { PersistentUISettings(persistDuringTransition: $0.persistDuringTransition) }
        )
    }
}

// MARK: - Flow Node

/// A node in the flow graph
public enum FlowNode: Codable, Sendable {
    case screen(ScreenNode)
    case condition(ConditionNode)
    case assign(AssignNode)
    case abTest(ABTestNode)

    enum CodingKeys: String, CodingKey {
        case kind, id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        case "screen":
            let node = try ScreenNode(from: decoder)
            self = .screen(node)
        case "condition":
            let node = try ConditionNode(from: decoder)
            self = .condition(node)
        case "assign":
            let node = try AssignNode(from: decoder)
            self = .assign(node)
        case "abTest":
            let node = try ABTestNode(from: decoder)
            self = .abTest(node)
        default:
            // Unknown node type - create a pass-through screen
            Logger.shared.warn("Unknown node kind: \(kind), treating as pass-through")
            let id = try container.decode(String.self, forKey: .id)
            self = .screen(ScreenNode(
                id: id,
                kind: "screen",
                name: "Unknown",
                screenType: .standard,
                props: nil,
                layout: nil,
                customScreen: nil
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .screen(let node): try node.encode(to: encoder)
        case .condition(let node): try node.encode(to: encoder)
        case .assign(let node): try node.encode(to: encoder)
        case .abTest(let node): try node.encode(to: encoder)
        }
    }

    public var id: String {
        switch self {
        case .screen(let node): return node.id
        case .condition(let node): return node.id
        case .assign(let node): return node.id
        case .abTest(let node): return node.id
        }
    }

    public var kind: String {
        switch self {
        case .screen: return "screen"
        case .condition: return "condition"
        case .assign: return "assign"
        case .abTest: return "abTest"
        }
    }
}

// MARK: - Screen Node

public enum ScreenType: String, Codable, Sendable {
    case standard
    case modal
    case bottomSheet
    case fullScreen
    case custom
}

public struct ScreenNode: Codable, Sendable {
    public let id: String
    public let kind: String
    public let name: String
    public let screenType: ScreenType?
    public let props: ScreenProps?
    public let layout: ComponentNode?
    /// New per-screen settings for persistent UI zones
    let screenSettings: ScreenSettings?
    /// @deprecated Use screenSettings. Kept for backward compatibility.
    let chromeOverrides: ScreenChromeOverrides?
    let customScreen: CustomScreenConfig?
    let enterTransition: TransitionConfig?
    let exitTransition: TransitionConfig?
    let timeline: [ScreenTimelineEvent]?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, screenType, props, layout, screenSettings, chromeOverrides, customScreen
        case enterTransition, exitTransition, timeline
    }

    init(
        id: String,
        kind: String,
        name: String,
        screenType: ScreenType?,
        props: ScreenProps?,
        layout: ComponentNode?,
        screenSettings: ScreenSettings? = nil,
        chromeOverrides: ScreenChromeOverrides? = nil,
        customScreen: CustomScreenConfig?,
        enterTransition: TransitionConfig? = nil,
        exitTransition: TransitionConfig? = nil,
        timeline: [ScreenTimelineEvent]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.screenType = screenType
        self.props = props
        self.layout = layout
        self.screenSettings = screenSettings
        self.chromeOverrides = chromeOverrides
        self.customScreen = customScreen
        self.enterTransition = enterTransition
        self.exitTransition = exitTransition
        self.timeline = timeline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        screenType = try container.decodeIfPresent(ScreenType.self, forKey: .screenType)
        props = try container.decodeIfPresent(ScreenProps.self, forKey: .props)
        layout = try container.decodeIfPresent(ComponentNode.self, forKey: .layout)
        screenSettings = try container.decodeIfPresent(ScreenSettings.self, forKey: .screenSettings)
        chromeOverrides = try container.decodeIfPresent(ScreenChromeOverrides.self, forKey: .chromeOverrides)
        customScreen = try container.decodeIfPresent(CustomScreenConfig.self, forKey: .customScreen)
        enterTransition = try container.decodeIfPresent(TransitionConfig.self, forKey: .enterTransition)
        exitTransition = try container.decodeIfPresent(TransitionConfig.self, forKey: .exitTransition)
        timeline = try container.decodeIfPresent([ScreenTimelineEvent].self, forKey: .timeline)
    }

    /// Resolved screen settings — prefers screenSettings, falls back to migrated chromeOverrides.
    var resolvedScreenSettings: ScreenSettings? {
        if let ss = screenSettings { return ss }
        // Check legacy hideChrome first
        if props?.hideChrome == true && chromeOverrides == nil {
            return ScreenSettings(hideAllZones: true, navigationBar: nil, footer: nil, overlay: nil, progressOverride: nil)
        }
        guard let co = chromeOverrides else {
            if props?.hideChrome == true {
                return ScreenSettings(hideAllZones: true, navigationBar: nil, footer: nil, overlay: nil, progressOverride: nil)
            }
            return nil
        }
        return ScreenSettings(
            hideAllZones: props?.hideChrome,
            navigationBar: co.header.map { ZoneScreenOverride(visible: $0.visible, replaceLayout: $0.customLayout) },
            footer: co.footer.map { ZoneScreenOverride(visible: $0.visible, replaceLayout: $0.customLayout) },
            overlay: nil,
            progressOverride: co.progressOverride
        )
    }
}

// MARK: - Screen Timeline Event

/// A single event in a screen-level animation timeline.
/// The timeline coordinates WHEN components start their animations.
struct ScreenTimelineEvent: Codable, Sendable {
    let id: String
    let target: String
    let action: ScreenTimelineAction?
    let at: Double?
    let after: String?
    let afterGap: Double?

    /// The resolved action, defaulting to `.startTimeline` when not specified.
    var resolvedAction: ScreenTimelineAction {
        action ?? .startTimeline
    }
}

/// The action a timeline event performs on its target component.
enum ScreenTimelineAction: Codable, Sendable {
    case startTimeline
    case triggerStep(stepId: String)
    case particle(effect: String, duration: Double?, colors: [String]?, emoji: [String]?,
                  density: String?, size: String?, direction: String?,
                  spread: Double?, gravity: Double?, speed: Double?, haptic: String?)

    enum CodingKeys: String, CodingKey {
        case type, stepId, effect, duration, colors, emoji
        case density, size, direction, spread, gravity, speed, haptic
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "triggerStep":
            let stepId = try container.decode(String.self, forKey: .stepId)
            self = .triggerStep(stepId: stepId)
        case "particle":
            let effect = try container.decode(String.self, forKey: .effect)
            let duration = try container.decodeIfPresent(Double.self, forKey: .duration)
            let colors = try container.decodeIfPresent([String].self, forKey: .colors)
            let emoji = try container.decodeIfPresent([String].self, forKey: .emoji)
            let density = try container.decodeIfPresent(String.self, forKey: .density)
            let size = try container.decodeIfPresent(String.self, forKey: .size)
            let direction = try container.decodeIfPresent(String.self, forKey: .direction)
            let spread = try container.decodeIfPresent(Double.self, forKey: .spread)
            let gravity = try container.decodeIfPresent(Double.self, forKey: .gravity)
            let speed = try container.decodeIfPresent(Double.self, forKey: .speed)
            let haptic = try container.decodeIfPresent(String.self, forKey: .haptic)
            self = .particle(effect: effect, duration: duration, colors: colors, emoji: emoji,
                             density: density, size: size, direction: direction,
                             spread: spread, gravity: gravity, speed: speed, haptic: haptic)
        default:
            self = .startTimeline
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .startTimeline:
            try container.encode("startTimeline", forKey: .type)
        case .triggerStep(let stepId):
            try container.encode("triggerStep", forKey: .type)
            try container.encode(stepId, forKey: .stepId)
        case .particle(let effect, let duration, let colors, let emoji,
                       let density, let size, let direction,
                       let spread, let gravity, let speed, let haptic):
            try container.encode("particle", forKey: .type)
            try container.encode(effect, forKey: .effect)
            try container.encodeIfPresent(duration, forKey: .duration)
            try container.encodeIfPresent(colors, forKey: .colors)
            try container.encodeIfPresent(emoji, forKey: .emoji)
            try container.encodeIfPresent(density, forKey: .density)
            try container.encodeIfPresent(size, forKey: .size)
            try container.encodeIfPresent(direction, forKey: .direction)
            try container.encodeIfPresent(spread, forKey: .spread)
            try container.encodeIfPresent(gravity, forKey: .gravity)
            try container.encodeIfPresent(speed, forKey: .speed)
            try container.encodeIfPresent(haptic, forKey: .haptic)
        }
    }
}

public struct ScreenProps: Codable, Sendable {
    public let backgroundColor: String?
    public let safeArea: Bool?
    public let includeInProgress: Bool?
    /// Whether to hide chrome (header/footer) on this screen. Defaults to false.
    public let hideChrome: Bool?

    // Layered background system
    let background: ScreenBackground?
    public let backgroundInherit: Bool?       // default true (inherit from flow)

    // Legacy gradient (for backward compat migration)
    let gradient: LegacyGradient?

    /// Global animation speed multiplier for all component animations on this screen.
    /// Defaults to 1.0 (normal speed). Values < 1 slow down, values > 1 speed up.
    public let animationSpeed: Double?

    /// Screen-level particle effect that auto-plays on screen appear or after a delay.
    let particleEffect: ScreenParticleEffect?

    enum CodingKeys: String, CodingKey {
        case backgroundColor, safeArea, includeInProgress, hideChrome
        case background, backgroundInherit
        case gradient, animationSpeed, particleEffect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backgroundColor = try container.decodeIfPresent(String.self, forKey: .backgroundColor)
        safeArea = try container.decodeIfPresent(Bool.self, forKey: .safeArea)
        includeInProgress = try container.decodeIfPresent(Bool.self, forKey: .includeInProgress)
        hideChrome = try container.decodeIfPresent(Bool.self, forKey: .hideChrome)
        background = try container.decodeIfPresent(ScreenBackground.self, forKey: .background)
        backgroundInherit = try container.decodeIfPresent(Bool.self, forKey: .backgroundInherit)
        gradient = try container.decodeIfPresent(LegacyGradient.self, forKey: .gradient)
        animationSpeed = try container.decodeIfPresent(Double.self, forKey: .animationSpeed)
        particleEffect = try container.decodeIfPresent(ScreenParticleEffect.self, forKey: .particleEffect)
    }
}

/// Screen-level particle effect configuration for auto-play particles.
///
/// Matches the frontend `ScreenParticleEffect` interface. Contains all
/// particle config options plus screen-specific trigger and loop settings.
struct ScreenParticleEffect: Codable, Sendable {
    let enabled: Bool
    let effect: String
    let trigger: String           // "onAppear" or "afterDelay"
    let loop: Bool?
    let duration: Double?         // ms
    let delay: Double?            // ms
    let colors: [String]?
    let emoji: [String]?
    let density: String?
    let size: String?
    let direction: String?
    let spread: Double?
    let gravity: Double?
    let speed: Double?
    let haptic: String?

    /// Converts to a ParticleEffectConfig dictionary for the rendering system.
    func toConfigDict() -> [String: Any] {
        var dict: [String: Any] = ["effect": effect]
        if let duration = duration { dict["duration"] = duration }
        if let delay = delay { dict["delay"] = delay }
        if let colors = colors { dict["colors"] = colors }
        if let emoji = emoji { dict["emoji"] = emoji }
        if let density = density { dict["density"] = density }
        if let size = size { dict["size"] = size }
        if let direction = direction { dict["direction"] = direction }
        if let spread = spread { dict["spread"] = spread }
        if let gravity = gravity { dict["gravity"] = gravity }
        if let speed = speed { dict["speed"] = speed }
        if let haptic = haptic { dict["haptic"] = haptic }
        if let loop = loop { dict["loop"] = loop }
        return dict
    }
}

/// Legacy gradient format from old schema (2-color linear only)
struct LegacyGradient: Codable, Sendable {
    let colors: [String]
    let angle: Double?
}

struct CustomScreenConfig: Codable, Sendable {
    let identifier: String
    let props: [String: AnyCodable]?
    let inputs: [String: String]?
    let outputs: [String: OutputHandler]?
}

// MARK: - Condition Node

public struct ConditionNode: Codable, Sendable {
    public let id: String
    public let kind: String
    public let name: String?
    let condition: Condition
}

// MARK: - Assign Node

public struct AssignNode: Codable, Sendable {
    public let id: String
    public let kind: String
    public let name: String?
    let assignments: [Assignment]
}

struct Assignment: Codable, Sendable {
    let variableKey: String
    let expression: AssignmentExpression
}

struct AssignmentExpression: Codable, Sendable {
    let operation: String
    let value: VariableValue?
}

// MARK: - AB Test Node

public struct ABTestNode: Codable, Sendable {
    public let id: String
    public let kind: String
    public let name: String?
    public let experimentKey: String
    public let variants: [ABTestVariant]
}

public struct ABTestVariant: Codable, Sendable {
    public let id: String
    public let label: String?
    public let weight: Double
    public let targetNodeId: String
}

// MARK: - Flow Edge

struct FlowEdge: Codable, Sendable {
    let id: String
    let fromNodeId: String
    let toNodeId: String
    let kind: EdgeKind?
    let label: String?
    let guard_: Condition?
    let priority: Int?
    let transition: TransitionConfig?

    enum CodingKeys: String, CodingKey {
        case id, fromNodeId, toNodeId, kind, label, priority, transition
        case guard_ = "guard"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fromNodeId = try container.decode(String.self, forKey: .fromNodeId)
        toNodeId = try container.decode(String.self, forKey: .toNodeId)
        kind = try container.decodeIfPresent(EdgeKind.self, forKey: .kind)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        guard_ = try container.decodeIfPresent(Condition.self, forKey: .guard_)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        transition = try container.decodeIfPresent(TransitionConfig.self, forKey: .transition)
    }
}

enum EdgeKind: String, Codable, Sendable {
    case normal
    case conditionTrue
    case conditionFalse
    case error
    case event
    case abVariant
}

// MARK: - Persistent UI (Zones)

/// Persistent UI zones that wrap all screens.
/// Three zones: navigationBar (top), footer (bottom), overlay (floating over content).
struct PersistentUI: Codable, Sendable {
    let navigationBar: PersistentZone?
    let footer: PersistentZone?
    let overlay: OverlayZone?
    let settings: PersistentUISettings?
}

/// A persistent zone (navigation bar or footer).
/// Contains a regular component tree rendered outside the screen transition container.
struct PersistentZone: Codable, Sendable {
    let id: String
    let visible: Bool
    let layout: ComponentNode
    let behavior: ZoneBehavior?
    let props: ZoneProps?
}

/// Overlay zone — a persistent floating layer rendered on top of the content area.
struct OverlayZone: Codable, Sendable {
    let id: String
    let visible: Bool
    let layout: ComponentNode
    let behavior: OverlayBehavior?
    let props: OverlayProps?
}

struct ZoneBehavior: Codable, Sendable {
    let allowScreenOverride: Bool?
    /// "persistent", "crossfade", "reflow", "participate"
    let transitionMode: String?
}

struct ZoneProps: Codable, Sendable {
    let backgroundColor: String?
    let padding: Double?
    let safeArea: Bool?
}

struct PersistentUISettings: Codable, Sendable {
    let persistDuringTransition: Bool?
}

struct OverlayBehavior: Codable, Sendable {
    let allowScreenOverride: Bool?
}

struct OverlayProps: Codable, Sendable {
    /// "topLeading", "top", "topTrailing", "leading", "center", "trailing",
    /// "bottomLeading", "bottom", "bottomTrailing"
    let alignment: String?
    /// Whether overlay passes touch events through to content below (default: false).
    let passthrough: Bool?
}

/// Per-screen settings for persistent UI zones.
struct ScreenSettings: Codable, Sendable {
    /// Hide all persistent zones on this screen
    let hideAllZones: Bool?
    let navigationBar: ZoneScreenOverride?
    let footer: ZoneScreenOverride?
    let overlay: ZoneScreenOverride?
    /// Override progress value for progress/progressDots components in any zone (0-1).
    /// nil = use auto-calculated value.
    let progressOverride: Double?

    init(hideAllZones: Bool?, navigationBar: ZoneScreenOverride?, footer: ZoneScreenOverride?, overlay: ZoneScreenOverride?, progressOverride: Double?) {
        self.hideAllZones = hideAllZones
        self.navigationBar = navigationBar
        self.footer = footer
        self.overlay = overlay
        self.progressOverride = progressOverride
    }
}

/// Per-screen override for a persistent zone (navigation bar or footer).
struct ZoneScreenOverride: Codable, Sendable {
    /// Show/hide this zone on this screen
    let visible: Bool?
    /// Replace the zone's entire component tree on this screen (advanced escape hatch).
    let replaceLayout: ComponentNode?
    /// Per-screen prop patches for individual zone components, keyed by component
    /// id. Each patch is shallow-merged over the component's own props while this
    /// screen is active (e.g. required-question gating writes a conditional
    /// `disabled` onto a shared continue button for one screen only).
    let componentProps: [String: [String: AnyCodable]]?

    init(visible: Bool?, replaceLayout: ComponentNode?, componentProps: [String: [String: AnyCodable]]? = nil) {
        self.visible = visible
        self.replaceLayout = replaceLayout
        self.componentProps = componentProps
    }
}

// MARK: - Legacy Chrome (backward compatibility)

/// @deprecated Use PersistentUI. Kept for migration/backward compatibility.
struct GlobalChrome: Codable, Sendable {
    let header: ChromeSection?
    let footer: ChromeSection?
    let settings: ChromeSettings?
}

struct ChromeSection: Codable, Sendable {
    let id: String
    let visible: Bool
    let layout: ComponentNode
    let behavior: ChromeBehavior?
    let props: ChromeProps?
}

struct ChromeBehavior: Codable, Sendable {
    let allowScreenOverride: Bool?
    let animateIndependently: Bool?
}

struct ChromeProps: Codable, Sendable {
    let backgroundColor: String?
    let padding: Double?
    let safeArea: Bool?
}

struct ChromeSettings: Codable, Sendable {
    let persistDuringTransition: Bool?
    let animateOnScreenChange: Bool?
}

/// @deprecated Use ScreenSettings. Kept for migration/backward compatibility.
struct ScreenChromeOverrides: Codable, Sendable {
    let header: ChromeOverride?
    let footer: ChromeOverride?
    let progressOverride: Double?
}

struct ChromeOverride: Codable, Sendable {
    let visible: Bool?
    let customLayout: ComponentNode?
}

// MARK: - Transition Types

enum TransitionType: String, Codable, Sendable {
    case none
    case fade
    case slideFromRight
    case slideFromLeft
    case slideFromBottom
    case slideFromTop
    case push
    case scale
    case flip

    /// Map legacy transition type strings to new types.
    static func legacyMapping(_ value: String) -> TransitionType? {
        switch value {
        case "slide": return .slideFromRight
        case "modal", "bottom": return .slideFromBottom
        default: return nil
        }
    }
}

enum TransitionEasing: String, Codable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case spring
}

// MARK: - Flow Settings

struct FlowSettings: Codable, Sendable {
    let defaultTransition: TransitionConfig?
    let backTransition: TransitionConfig?
    /// When true, persist the user's in-progress run of this flow on device and
    /// resume from where they left off on a later launch. See `FlowProgressStore`.
    let saveProgress: Bool?
}

struct TransitionConfig: Codable, Sendable {
    let type: String?
    let duration: Int?
    let easing: String?
    let springDamping: Double?
    let springResponse: Double?

    // Legacy support: old schema used "durationMs" instead of "duration"
    let durationMs: Int?

    /// Resolved duration in milliseconds, preferring `duration` over legacy `durationMs`.
    var resolvedDurationMs: Int {
        duration ?? durationMs ?? 300
    }

    /// Resolved duration in seconds for SwiftUI animations.
    var resolvedDurationSeconds: TimeInterval {
        Double(resolvedDurationMs) / 1000.0
    }

    /// Resolved transition type, mapping legacy values and falling back to fade for unknowns.
    var resolvedType: TransitionType {
        guard let type = type else { return .slideFromRight }
        return TransitionType(rawValue: type)
            ?? TransitionType.legacyMapping(type)
            ?? .fade
    }

    /// Resolved easing type with fallback.
    var resolvedEasing: TransitionEasing {
        guard let easing = easing else { return .easeInOut }
        return TransitionEasing(rawValue: easing) ?? .easeInOut
    }

    /// Memberwise initializer for programmatic construction.
    init(
        type: String? = nil,
        duration: Int? = nil,
        easing: String? = nil,
        springDamping: Double? = nil,
        springResponse: Double? = nil,
        durationMs: Int? = nil
    ) {
        self.type = type
        self.duration = duration
        self.easing = easing
        self.springDamping = springDamping
        self.springResponse = springResponse
        self.durationMs = durationMs
    }
}

// MARK: - Global Styles

struct FlowGlobalStyles: Codable, Sendable {
    let colors: [String: String]?
    let fonts: [String: String]?
}

// MARK: - Output Handler

struct OutputHandler: Codable, Sendable {
    let map: [String: String]?
    let actions: [ComponentAction]
}

// MARK: - AnyCodable Helper

public struct AnyCodable: Codable, Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
