import Foundation

// MARK: - Custom Component Reference

/// Reference to a custom component with key and version
struct CustomComponentRef: Sendable, Equatable {
    /// Component key (e.g., "test_3", "my_paywall")
    let key: String

    /// Component version (defaults to 1)
    let version: Int

    init(key: String, version: Int = 1) {
        self.key = key
        self.version = version
    }

    /// Creates a registry key for lookup (e.g., "test_3_v1")
    var registryKey: String {
        "\(key)_v\(version)"
    }
}

// MARK: - Component Type

/// Type of a component
enum ComponentType: String, Codable, Sendable {
    case screenRoot
    case stack
    case text
    case image
    case button
    case input
    case toggle
    case progress
    case ringProgress
    case icon
    case slider
    case picker
    case ruler
    case lottie
    case comparisonChart
    case custom

    /// A component type this SDK build doesn't recognize. A newer flow can ship
    /// component types an older SDK has never heard of; rather than throwing
    /// (which would drop the entire screen), unknown types decode to this case
    /// and render as nothing in release builds (or a placeholder in DEBUG).
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ComponentType(rawValue: raw) ?? .unknown
    }
}

// MARK: - Component Node

/// A component in the UI tree
public struct ComponentNode: Codable, Sendable {
    public let id: String
    let type: ComponentType
    let props: ComponentProps?
    public let children: [ComponentNode]?
    let interactions: [ComponentInteraction]?

    enum CodingKeys: String, CodingKey {
        case id, type, props, children, interactions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(ComponentType.self, forKey: .type)
        props = try container.decodeIfPresent(ComponentProps.self, forKey: .props)
        children = ComponentNode.decodeChildrenLeniently(from: container)
        interactions = try container.decodeIfPresent([ComponentInteraction].self, forKey: .interactions)
    }

    /// Decodes the `children` array element-by-element so a single malformed or
    /// unrecognizable child is skipped instead of throwing and taking the whole
    /// subtree (and therefore the entire screen) down with it. Mirrors the
    /// lenient node-decoding used by `FlowDefinition`.
    private static func decodeChildrenLeniently(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [ComponentNode]? {
        guard var childrenContainer = try? container.nestedUnkeyedContainer(forKey: .children) else {
            return nil
        }
        var decoded: [ComponentNode] = []
        while !childrenContainer.isAtEnd {
            do {
                decoded.append(try childrenContainer.decode(ComponentNode.self))
            } catch {
                Logger.shared.warn("ComponentNode: skipping undecodable child at index \(decoded.count): \(error)")
                // Advance past the bad element so decoding can continue.
                _ = try? childrenContainer.decode(AnyCodable.self)
            }
        }
        return decoded.isEmpty ? nil : decoded
    }
}

extension ComponentNode {
    /// Memberwise initializer for constructing nodes in code (props patching in
    /// `ZoneRenderer`, `replacingProps`, and test fixtures). Swift does not
    /// synthesize this automatically because the type defines a custom
    /// `init(from:)`. Must stay outside any `#if DEBUG` guard — release builds
    /// of the rendering pipeline depend on it.
    init(
        id: String,
        type: ComponentType,
        props: ComponentProps?,
        children: [ComponentNode]?,
        interactions: [ComponentInteraction]?
    ) {
        self.id = id
        self.type = type
        self.props = props
        self.children = children
        self.interactions = interactions
    }

    /// Returns a copy of this node with its props replaced.
    func replacingProps(_ newProps: ComponentProps?) -> ComponentNode {
        ComponentNode(
            id: id,
            type: type,
            props: newProps,
            children: children,
            interactions: interactions
        )
    }
}

// MARK: - Component Props

/// Properties for a component (supports both static and conditional values)
struct ComponentProps: Codable, Sendable {
    private let rawProps: [String: AnyCodable]

    // MARK: Universal Properties - Visibility & Opacity

    var isVisible: PropertyValue<Bool>? { getPropertyValue("isVisible") }
    var opacity: PropertyValue<Double>? { getPropertyValue("opacity") }
    var visibility: PropertyValue<String>? { getPropertyValue("visibility") }
    var disabled: PropertyValue<Bool>? { getPropertyValue("disabled") }

    // MARK: Universal Properties - Size

    var width: DimensionValue? { getDimensionValue("width") }
    var height: DimensionValue? { getDimensionValue("height") }
    var minWidth: DimensionValue? { getDimensionValue("minWidth") }
    var maxWidth: DimensionValue? { getDimensionValue("maxWidth") }
    var minHeight: DimensionValue? { getDimensionValue("minHeight") }
    var maxHeight: DimensionValue? { getDimensionValue("maxHeight") }

    // MARK: Universal Properties - Padding

    var paddingVertical: PropertyValue<Double>? { getPropertyValue("paddingVertical") }
    var paddingHorizontal: PropertyValue<Double>? { getPropertyValue("paddingHorizontal") }
    var paddingTop: PropertyValue<Double>? {
        // First try paddingTop, then fall back to padding.top object
        if let value: PropertyValue<Double> = getPropertyValue("paddingTop") {
            return value
        }
        if let paddingObj = rawProps["padding"]?.value as? [String: Any],
           let top = paddingObj["top"] as? Double {
            return .static(top)
        }
        if let paddingObj = rawProps["padding"]?.value as? [String: Any],
           let top = paddingObj["top"] as? Int {
            return .static(Double(top))
        }
        return nil
    }
    var paddingBottom: PropertyValue<Double>? {
        if let value: PropertyValue<Double> = getPropertyValue("paddingBottom") {
            return value
        }
        if let paddingObj = rawProps["padding"]?.value as? [String: Any],
           let bottom = paddingObj["bottom"] as? Double {
            return .static(bottom)
        }
        if let paddingObj = rawProps["padding"]?.value as? [String: Any],
           let bottom = paddingObj["bottom"] as? Int {
            return .static(Double(bottom))
        }
        return nil
    }
    var paddingLeft: PropertyValue<Double>? {
        if let value: PropertyValue<Double> = getPropertyValue("paddingLeft") {
            return value
        }
        if let paddingObj = rawProps["padding"]?.value as? [String: Any],
           let left = paddingObj["left"] as? Double {
            return .static(left)
        }
        if let paddingObj = rawProps["padding"]?.value as? [String: Any],
           let left = paddingObj["left"] as? Int {
            return .static(Double(left))
        }
        return nil
    }
    var paddingRight: PropertyValue<Double>? {
        if let value: PropertyValue<Double> = getPropertyValue("paddingRight") {
            return value
        }
        if let paddingObj = rawProps["padding"]?.value as? [String: Any],
           let right = paddingObj["right"] as? Double {
            return .static(right)
        }
        if let paddingObj = rawProps["padding"]?.value as? [String: Any],
           let right = paddingObj["right"] as? Int {
            return .static(Double(right))
        }
        return nil
    }
    var paddingAdvanced: Bool? { getRawValue("paddingAdvanced") }

    // MARK: Universal Properties - Margin

    var marginTop: PropertyValue<Double>? { getPropertyValue("marginTop") }
    var marginBottom: PropertyValue<Double>? { getPropertyValue("marginBottom") }
    var marginLeft: PropertyValue<Double>? { getPropertyValue("marginLeft") }
    var marginRight: PropertyValue<Double>? { getPropertyValue("marginRight") }

    // MARK: Universal Properties - Corner Radius

    var cornerRadius: PropertyValue<Double>? { getPropertyValue("cornerRadius") }
    var cornerAdvanced: Bool? { getRawValue("cornerAdvanced") }
    var cornerTopLeft: PropertyValue<Double>? { getPropertyValue("cornerTopLeft") }
    var cornerTopRight: PropertyValue<Double>? { getPropertyValue("cornerTopRight") }
    var cornerBottomLeft: PropertyValue<Double>? { getPropertyValue("cornerBottomLeft") }
    var cornerBottomRight: PropertyValue<Double>? { getPropertyValue("cornerBottomRight") }

    // MARK: Universal Properties - Border

    var borderWidth: PropertyValue<Double>? { getPropertyValue("borderWidth") }
    var borderColor: PropertyValue<String>? { getPropertyValue("borderColor") }
    var borderStyle: PropertyValue<String>? { getPropertyValue("borderStyle") }
    var borderOpacity: PropertyValue<Double>? { getPropertyValue("borderOpacity") }

    // MARK: Universal Properties - Background

    var backgroundColor: PropertyValue<String>? { getPropertyValue("backgroundColor") }
    var fill: PropertyValue<String>? { getPropertyValue("fill") }
    var overflow: PropertyValue<String>? { getPropertyValue("overflow") }

    /// Optional gradient fill for any box-styled component (button / stack).
    /// Reuses `GradientDefinition` (the screen-background gradient shape) so the
    /// existing gradient renderer is reused at component scope — no new renderer.
    /// Parsed from the grouped `backgroundGradient` object (mirrors
    /// `ringAutoProgress` / `attention`), unwrapping a `{type:"static",value}`
    /// PropertyValue envelope if one is present. Stop colours may be `token:`
    /// refs / `{{var}}` — resolved per stop at render time in `StyleModifiers`.
    var backgroundGradient: GradientDefinition? {
        guard let raw = rawProps["backgroundGradient"]?.value else { return nil }

        var dict: [String: Any]?
        if let d = raw as? [String: Any] {
            if (d["type"] as? String) == "static", let inner = d["value"] as? [String: Any] {
                dict = inner
            } else {
                dict = d
            }
        }
        guard let cfg = dict,
              let data = try? JSONSerialization.data(withJSONObject: cfg),
              let gradient = try? JSONDecoder().decode(GradientDefinition.self, from: data),
              !gradient.colors.isEmpty else {
            return nil
        }
        return gradient
    }

    // MARK: Universal Properties - Shadow

    var boxShadowColor: PropertyValue<String>? { getPropertyValue("boxShadowColor") }
    var boxShadowOpacity: PropertyValue<Double>? { getPropertyValue("boxShadowOpacity") }
    var boxShadowX: PropertyValue<Double>? { getPropertyValue("boxShadowX") }
    var boxShadowY: PropertyValue<Double>? { getPropertyValue("boxShadowY") }
    var boxShadowBlur: PropertyValue<Double>? { getPropertyValue("boxShadowBlur") }
    var boxShadowSpread: PropertyValue<Double>? { getPropertyValue("boxShadowSpread") }
    var boxShadowInner: PropertyValue<Bool>? { getPropertyValue("boxShadowInner") }

    // MARK: Universal Properties - Position

    var positionType: PropertyValue<String>? { getPropertyValue("positionType") }
    var top: PropertyValue<Double>? { getPropertyValue("top") }
    var right: PropertyValue<Double>? { getPropertyValue("right") }
    var bottom: PropertyValue<Double>? { getPropertyValue("bottom") }
    var left: PropertyValue<Double>? { getPropertyValue("left") }
    var zIndex: PropertyValue<Double>? { getPropertyValue("zIndex") }

    // MARK: Universal Properties - Animation

    var animateOn: PropertyValue<String>? { getPropertyValue("animateOn") }
    var animOpacity: PropertyValue<Double>? { getPropertyValue("animOpacity") }
    var animMoveY: PropertyValue<Double>? { getPropertyValue("animMoveY") }
    var animMoveX: PropertyValue<Double>? { getPropertyValue("animMoveX") }
    var animScale: PropertyValue<Double>? { getPropertyValue("animScale") }
    var animRotate: PropertyValue<Double>? { getPropertyValue("animRotate") }
    var animDuration: PropertyValue<Double>? { getPropertyValue("animDuration") }
    var animDelay: PropertyValue<Double>? { getPropertyValue("animDelay") }
    var animEasing: PropertyValue<String>? { getPropertyValue("animEasing") }

    // MARK: Universal Properties - Haptic Feedback

    /// Haptic feedback style to fire during animations.
    /// Values: "none", "light", "medium", "heavy", "rigid", "soft", "success", "warning", "error", "selection"
    var hapticType: PropertyValue<String>? { getPropertyValue("hapticType") }

    /// When to fire the haptic relative to the animation.
    /// Values: "onAnimStart", "onAnimEnd", "onAppear", "onTap"
    var hapticTrigger: PropertyValue<String>? { getPropertyValue("hapticTrigger") }

    /// Additional delay (in ms) from the haptic trigger point before firing.
    var hapticDelay: PropertyValue<Double>? { getPropertyValue("hapticDelay") }

    // MARK: Universal Properties - Attention Animation

    /// Attention animation configuration for looping effects (pulse, bounce, shake, etc.).
    /// Reads a grouped JSON object: { "effect": "pulse", "duration": 1000, "intensity": 50, ... }
    var attention: [String: Any]? {
        rawProps["attention"]?.value as? [String: Any]
    }

    // MARK: Universal Properties - Press Feedback

    /// Press feedback configuration for tap/press visual effects.
    /// Reads a grouped JSON object: { "style": "scale", "scale": 0.96, ... }
    var pressFeedback: [String: Any]? {
        rawProps["pressFeedback"]?.value as? [String: Any]
    }

    // MARK: Stack Properties - Stagger

    /// Whether this container should stagger its children's appear animations.
    var staggerChildren: PropertyValue<Bool>? { getPropertyValue("staggerChildren") }

    /// Interval in milliseconds between each child's animation start.
    var staggerInterval: PropertyValue<Double>? { getPropertyValue("staggerInterval") }

    /// Order in which children are staggered.
    /// Values: "natural", "reverse", "center-out", "random"
    var staggerOrder: PropertyValue<String>? { getPropertyValue("staggerOrder") }

    /// Haptic pattern to play per child during stagger.
    /// Values: "none", "tick", "ramp"
    var staggerHaptic: PropertyValue<String>? { getPropertyValue("staggerHaptic") }

    // MARK: Stack Properties

    var axis: PropertyValue<String>? {
        getPropertyValue("axis") ?? getPropertyValue("direction")
    }
    var spacing: PropertyValue<Double>? {
        // Prefer `spacing` over `gap`.
        // The web editor uses `spacing` as the authoritative inter-item distance
        // in flex containers. `gap` may carry a stale default value that differs
        // from the user-configured spacing, so `spacing` takes precedence.
        getPropertyValue("spacing") ?? getPropertyValue("gap")
    }
    var align: PropertyValue<String>? { getPropertyValue("align") }
    var justify: PropertyValue<String>? { getPropertyValue("justify") }
    var verticalAlign: PropertyValue<String>? { getPropertyValue("verticalAlign") }
    var horizontalAlign: PropertyValue<String>? { getPropertyValue("horizontalAlign") }
    var alignItems: PropertyValue<String>? { getPropertyValue("alignItems") }
    var justifyContent: PropertyValue<String>? { getPropertyValue("justifyContent") }
    var wrap: PropertyValue<String>? { getPropertyValue("wrap") }
    var scrollBehavior: PropertyValue<String>? { getPropertyValue("scrollBehavior") }

    // MARK: Text Properties

    var text: PropertyValue<String>? { getPropertyValue("text") }
    var color: PropertyValue<String>? { getPropertyValue("color") }
    var fontSize: PropertyValue<Double>? { getPropertyValue("fontSize") }
    var fontWeight: PropertyValue<String>? { getPropertyValue("fontWeight") }
    var fontFamily: PropertyValue<String>? { getPropertyValue("fontFamily") }
    var textAlign: PropertyValue<String>? { getPropertyValue("textAlign") }
    var lineHeight: PropertyValue<Double>? { getPropertyValue("lineHeight") }
    var letterSpacing: PropertyValue<Double>? { getPropertyValue("letterSpacing") }
    var textCase: PropertyValue<String>? { getPropertyValue("textCase") }
    var maxLines: PropertyValue<Int>? { getPropertyValue("maxLines") }

    /// Rich Text runs (`props.richText`): inline-styled segments. When present
    /// and non-empty the text node renders styled runs instead of the single
    /// uniform `text` string (schema: `RichTextSegment`). Accepts a bare array or
    /// a `{ "type": "static", "value": [...] }` PropertyValue wrapper.
    var richText: [RichTextSegment]? {
        guard let raw = rawProps["richText"]?.value else { return nil }

        let items: [Any]?
        if let arr = raw as? [Any] {
            items = arr
        } else if let d = raw as? [String: Any],
                  (d["type"] as? String) == "static",
                  let inner = d["value"] as? [Any] {
            items = inner
        } else {
            items = nil
        }

        guard let list = items, !list.isEmpty else { return nil }

        let segments: [RichTextSegment] = list.compactMap { element in
            guard let seg = element as? [String: Any] else { return nil }
            return RichTextSegment(
                text: seg["text"] as? String ?? "",
                bold: seg["bold"] as? Bool ?? false,
                italic: seg["italic"] as? Bool ?? false,
                underline: seg["underline"] as? Bool ?? false,
                strikethrough: seg["strikethrough"] as? Bool ?? false,
                color: seg["color"] as? String
            )
        }
        return segments.isEmpty ? nil : segments
    }

    // MARK: Text Effect Properties

    /// Text effect configuration for typewriter, countUp, scramble, etc.
    /// Reads a grouped JSON object: { "type": "typewriter", "speed": 40, ... }
    var textEffect: TextEffectConfig? {
        guard let raw = rawProps["textEffect"]?.value else { return nil }

        var dict: [String: Any]?
        if let d = raw as? [String: Any] {
            // Check if it's a PropertyValue wrapper
            if let typeStr = d["type"] as? String, typeStr == "static",
               let innerValue = d["value"] as? [String: Any] {
                dict = innerValue
            } else if d["type"] != nil {
                // It could be a raw config dict with "type" being the effect type
                dict = d
            }
        }

        guard let effectDict = dict else { return nil }
        let effectType = effectDict["type"] as? String ?? "none"
        if effectType == "none" { return nil }

        return TextEffectConfig(
            type: effectType,
            speed: Self.asDouble(effectDict["speed"]) ?? 40,
            delay: Self.asDouble(effectDict["delay"]) ?? 0,
            duration: Self.asDouble(effectDict["duration"]),
            cursor: effectDict["cursor"] as? String ?? "blink",
            cursorChar: effectDict["cursorChar"] as? String ?? "|",
            haptic: effectDict["haptic"] as? Bool ?? false
        )
    }

    /// Text rotation configuration for cycling through multiple values.
    /// Reads a grouped JSON object: { "enabled": true, "values": [...], ... }
    var textRotation: TextRotationConfig? {
        guard let raw = rawProps["textRotation"]?.value else { return nil }

        var dict: [String: Any]?
        if let d = raw as? [String: Any] {
            if let typeStr = d["type"] as? String, typeStr == "static",
               let innerValue = d["value"] as? [String: Any] {
                dict = innerValue
            } else {
                dict = d
            }
        }

        guard let rotDict = dict else { return nil }
        let enabled = rotDict["enabled"] as? Bool ?? false
        if !enabled { return nil }

        let values: [String]
        if let v = rotDict["values"] as? [String] {
            values = v
        } else if let v = rotDict["values"] as? [Any] {
            values = v.map { "\($0)" }
        } else {
            values = []
        }

        return TextRotationConfig(
            enabled: true,
            values: values,
            interval: Self.asDouble(rotDict["interval"]) ?? 2000,
            transition: rotDict["transition"] as? String ?? "slideUp",
            transitionDuration: Self.asDouble(rotDict["transitionDuration"]) ?? 400,
            loop: rotDict["loop"] as? Bool ?? true,
            pauseOnLast: rotDict["pauseOnLast"] as? Bool ?? false
        )
    }

    // MARK: Image Properties

    var src: PropertyValue<String>? { getPropertyValue("src") }
    var alt: PropertyValue<String>? { getPropertyValue("alt") }
    var fit: PropertyValue<String>? { getPropertyValue("fit") }
    var tintColor: PropertyValue<String>? { getPropertyValue("tintColor") }

    // MARK: Button Properties

    var iconSize: PropertyValue<Double>? { getPropertyValue("iconSize") }

    // MARK: Input Properties

    /// Try "inputType" first (new format), fall back to "type" (legacy)
    var inputType: PropertyValue<String>? {
        getPropertyValue("inputType") ?? getPropertyValue("type")
    }
    var placeholder: PropertyValue<String>? { getPropertyValue("placeholder") }
    var placeholderColor: PropertyValue<String>? { getPropertyValue("placeholderColor") }
    var variableKey: String? { rawProps["variableKey"]?.value as? String }
    var maxLength: PropertyValue<Double>? { getPropertyValue("maxLength") }
    var rows: PropertyValue<Double>? { getPropertyValue("rows") }
    var returnKeyType: PropertyValue<String>? { getPropertyValue("returnKeyType") }
    var inputValidation: [String: Any]? { rawProps["validation"]?.value as? [String: Any] }

    // MARK: Toggle Properties

    var value: PropertyValue<Bool>? { getPropertyValue("value") }
    var activeColor: PropertyValue<String>? { getPropertyValue("activeColor") }
    var inactiveColor: PropertyValue<String>? { getPropertyValue("inactiveColor") }
    var label: PropertyValue<String>? { getPropertyValue("label") }
    var variant: PropertyValue<String>? { getPropertyValue("variant") }

    // MARK: Progress Properties

    var mode: PropertyValue<String>? { getPropertyValue("mode") }
    var progressValue: PropertyValue<Double>? { getPropertyValue("value") }
    var trackColor: PropertyValue<String>? { getPropertyValue("trackColor") }
    var animateProgress: PropertyValue<Bool>? { getPropertyValue("animateProgress") }
    var animationDuration: PropertyValue<Double>? { getPropertyValue("animationDuration") }
    var animationCurve: PropertyValue<String>? { getPropertyValue("animationCurve") }

    // MARK: Comparison Chart Properties

    /// Reveal the chart's series in sequence rather than all at once.
    var staggerSeries: PropertyValue<Bool>? { getPropertyValue("staggerSeries") }
    /// Milliseconds between each series' reveal start when `staggerSeries` is on.
    var staggerDelay: PropertyValue<Double>? { getPropertyValue("staggerDelay") }

    // MARK: Ring Progress Properties

    /// Outer diameter in points (raw key `"size"`).
    var ringSize: PropertyValue<Double>? { getPropertyValue("size") }
    /// Animate the arc to its value on appear / value change.
    var animateOnAppear: PropertyValue<Bool>? { getPropertyValue("animateOnAppear") }
    /// Scripted reveal: animate 0 -> value on appear, ignoring the variable.
    var revealOnAppear: PropertyValue<Bool>? { getPropertyValue("revealOnAppear") }

    // Center percent label styling (autoProgress.showPercent).
    var percentFontSize: PropertyValue<Double>? { getPropertyValue("percentFontSize") }
    var percentColor: PropertyValue<String>? { getPropertyValue("percentColor") }
    var percentFontWeight: PropertyValue<String>? { getPropertyValue("percentFontWeight") }
    // Per-stage caption styling (autoProgress stage captions).
    var captionFontSize: PropertyValue<Double>? { getPropertyValue("captionFontSize") }
    var captionColor: PropertyValue<String>? { getPropertyValue("captionColor") }
    var captionFontWeight: PropertyValue<String>? { getPropertyValue("captionFontWeight") }
    var captionSpacing: PropertyValue<Double>? { getPropertyValue("captionSpacing") }

    /// Self-driving "analysis loader" timeline. When present (and enabled) the
    /// ring ignores `mode`/`value` and eases through staged targets, pausing at
    /// each, with a live percent and a per-stage caption. Parsed from the
    /// grouped `autoProgress` object (mirrors `textRotation`/`attention`).
    var ringAutoProgress: RingAutoProgress? {
        guard let raw = rawProps["autoProgress"]?.value else { return nil }

        var dict: [String: Any]?
        if let d = raw as? [String: Any] {
            if (d["type"] as? String) == "static", let inner = d["value"] as? [String: Any] {
                dict = inner
            } else {
                dict = d
            }
        }
        guard let cfg = dict else { return nil }

        let enabled = cfg["enabled"] as? Bool ?? true
        guard enabled else { return nil }

        let rawStages = cfg["stages"] as? [Any] ?? []
        let stages: [RingAutoProgressStage] = rawStages.compactMap { element in
            guard let s = element as? [String: Any] else { return nil }
            return RingAutoProgressStage(
                target: max(0, min(1, Self.asDouble(s["target"]) ?? 0)),
                rampMs: max(0, Self.asDouble(s["rampMs"]) ?? 800),
                holdMs: max(0, Self.asDouble(s["holdMs"]) ?? 400),
                caption: s["caption"] as? String
            )
        }
        guard !stages.isEmpty else { return nil }

        var onComplete: [ComponentAction] = []
        if let rawActions = cfg["onComplete"] as? [Any] {
            for entry in rawActions {
                guard let adict = entry as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: adict),
                      let action = try? JSONDecoder().decode(ComponentAction.self, from: data) else {
                    continue
                }
                onComplete.append(action)
            }
        }

        return RingAutoProgress(
            stages: stages,
            easing: cfg["easing"] as? String ?? "ease-in-out",
            showPercent: cfg["showPercent"] as? Bool ?? true,
            percentSuffix: cfg["percentSuffix"] as? String ?? "%",
            haptic: cfg["haptic"] as? Bool ?? false,
            hapticIntensity: cfg["hapticIntensity"] as? String ?? "light",
            loop: cfg["loop"] as? Bool ?? false,
            onComplete: onComplete
        )
    }

    // MARK: Icon Properties

    var iconName: PropertyValue<String>? { getPropertyValue("iconName") }
    /// The editor stores the icon component's size under the raw key `"size"`.
    var iconComponentSize: PropertyValue<Double>? { getPropertyValue("size") }
    var strokeWidth: PropertyValue<Double>? { getPropertyValue("strokeWidth") }

    // MARK: Slider Properties

    var sliderMin: PropertyValue<Double>? { getPropertyValue("min") }
    var sliderMax: PropertyValue<Double>? { getPropertyValue("max") }
    var sliderStep: PropertyValue<Double>? { getPropertyValue("step") }
    /// Initial value (raw key `"value"`); the bound variable wins on appear.
    var sliderValue: PropertyValue<Double>? { getPropertyValue("value") }
    var sliderFillColor: PropertyValue<String>? { getPropertyValue("fillColor") }
    var sliderThumbColor: PropertyValue<String>? { getPropertyValue("thumbColor") }
    var showValueLabel: PropertyValue<Bool>? { getPropertyValue("showValueLabel") }
    var valueFormat: PropertyValue<String>? { getPropertyValue("valueFormat") }

    // Modern slider styling (additive; defaults preserve the legacy look).
    /// Thickness of the track & fill in points (default 6).
    var sliderTrackHeight: PropertyValue<Double>? { getPropertyValue("trackHeight") }
    /// Trailing fill color; when present the fill is a leading→trailing gradient
    /// from `fillColor` to this. Token-resolvable like the other colors.
    var sliderFillColorEnd: PropertyValue<String>? { getPropertyValue("fillColorEnd") }
    /// "circle" (default) or "pill".
    var sliderThumbStyle: PropertyValue<String>? { getPropertyValue("thumbStyle") }
    /// Circle: diameter (default 18). Pill: width (default 28).
    var sliderThumbSize: PropertyValue<Double>? { getPropertyValue("thumbSize") }
    /// "inline" (default) or "top".
    var sliderValueLabelPosition: PropertyValue<String>? { getPropertyValue("valueLabelPosition") }
    /// Readout font size (default 14 inline, 40 top).
    var sliderValueLabelSize: PropertyValue<Double>? { getPropertyValue("valueLabelSize") }
    /// Readout color (token-resolvable). Default: inline = secondary/gray;
    /// top = the resolved `fillColor`.
    var sliderValueLabelColor: PropertyValue<String>? { getPropertyValue("valueLabelColor") }

    // MARK: Picker Properties

    /// "wheel" (default) or "date". Reuses the shared `mode` accessor below where
    /// possible, but exposed here for clarity at the picker call sites.
    var pickerMode: PropertyValue<String>? { getPropertyValue("mode") }

    /// Raw wheel-mode column specs. Each entry is an untyped dictionary
    /// (header / variableKey / unit / defaultValue / width plus EXACTLY ONE
    /// source: min/max/step OR options). Parsed by `PickerView`.
    var pickerColumns: [[String: Any]]? {
        guard let arr = rawProps["columns"]?.value as? [Any] else { return nil }
        let dicts = arr.compactMap { $0 as? [String: Any] }
        return dicts.isEmpty ? nil : dicts
    }

    /// Imperial/Metric unit-toggle config (wheel mode only). When present with
    /// options it REPLACES top-level `columns`/`mode`. Untyped dictionary parsed
    /// by `PickerView` (systemVariableKey / default / canonicalSystem / options).
    var pickerUnitToggle: [String: Any]? {
        rawProps["unitToggle"]?.value as? [String: Any]
    }

    // Date mode
    var pickerMinDate: PropertyValue<String>? { getPropertyValue("minDate") }
    var pickerMaxDate: PropertyValue<String>? { getPropertyValue("maxDate") }
    var pickerDateOrder: PropertyValue<String>? { getPropertyValue("dateOrder") }
    var pickerMonthFormat: PropertyValue<String>? { getPropertyValue("monthFormat") }
    /// Date-mode initial ISO value (shares the raw key `"defaultValue"`); the
    /// bound variable wins on appear.
    var pickerDefaultDate: PropertyValue<String>? { getPropertyValue("defaultValue") }

    // Appearance (both modes)
    var pickerVisibleRows: PropertyValue<Double>? { getPropertyValue("visibleRows") }
    var pickerItemHeight: PropertyValue<Double>? { getPropertyValue("itemHeight") }
    var pickerSelectionStyle: PropertyValue<String>? { getPropertyValue("selectionStyle") }
    var pickerSelectionColor: PropertyValue<String>? { getPropertyValue("selectionColor") }
    var pickerTextColor: PropertyValue<String>? { getPropertyValue("textColor") }
    var pickerSelectedTextColor: PropertyValue<String>? { getPropertyValue("selectedTextColor") }
    var pickerHeaderColor: PropertyValue<String>? { getPropertyValue("headerColor") }
    var pickerFontSize: PropertyValue<Double>? { getPropertyValue("fontSize") }
    var pickerSelectedFontSize: PropertyValue<Double>? { getPropertyValue("selectedFontSize") }
    var pickerHaptics: PropertyValue<Bool>? { getPropertyValue("haptics") }
    /// Infinite wrap (raw key `"loop"`, shared with the lottie accessor).
    var pickerLoop: PropertyValue<Bool>? { getPropertyValue("loop") }

    // MARK: Ruler Properties

    /// "horizontal" (default) or "vertical".
    var rulerOrientation: PropertyValue<String>? { getPropertyValue("orientation") }

    // Single continuous scale (used when no `unitToggle` is present; the toggle's
    // active `track` supplies these instead). `min`/`max`/`step`/`value` share the
    // raw keys with the slider's accessors but are exposed here for clarity at the
    // ruler call sites. The bound variable wins over `value` on appear.
    var rulerMin: PropertyValue<Double>? { getPropertyValue("min") }
    var rulerMax: PropertyValue<Double>? { getPropertyValue("max") }
    var rulerStep: PropertyValue<Double>? { getPropertyValue("step") }
    var rulerValue: PropertyValue<Double>? { getPropertyValue("value") }
    var rulerUnit: PropertyValue<String>? { getPropertyValue("unit") }

    // Tick strip appearance.
    var rulerMajorEvery: PropertyValue<Double>? { getPropertyValue("majorEvery") }
    var rulerTickSpacing: PropertyValue<Double>? { getPropertyValue("tickSpacing") }
    var rulerTickThickness: PropertyValue<Double>? { getPropertyValue("tickThickness") }
    var rulerMinorTickLength: PropertyValue<Double>? { getPropertyValue("minorTickLength") }
    var rulerMajorTickLength: PropertyValue<Double>? { getPropertyValue("majorTickLength") }
    var rulerTickColor: PropertyValue<String>? { getPropertyValue("tickColor") }
    var rulerMajorTickColor: PropertyValue<String>? { getPropertyValue("majorTickColor") }
    var rulerIndicatorColor: PropertyValue<String>? { getPropertyValue("indicatorColor") }
    var rulerIndicatorThickness: PropertyValue<Double>? { getPropertyValue("indicatorThickness") }

    // Big value readout. (`showValueLabel` / `valueFormat` reuse the slider
    // accessors above — same raw keys.)
    var rulerValueTemplate: PropertyValue<String>? { getPropertyValue("valueTemplate") }
    var rulerValueColor: PropertyValue<String>? { getPropertyValue("valueColor") }
    var rulerValueFontSize: PropertyValue<Double>? { getPropertyValue("valueFontSize") }
    var rulerValueFontWeight: PropertyValue<String>? { getPropertyValue("valueFontWeight") }

    /// Optional Imperial/Metric unit-toggle config. When present with options it
    /// REPLACES the top-level scale: each system carries exactly ONE `track`.
    /// Untyped dictionary parsed by `RulerView` (systemVariableKey / default /
    /// canonicalSystem / toggleStyle / options[{ key, label, track }]).
    var rulerUnitToggle: [String: Any]? {
        rawProps["unitToggle"]?.value as? [String: Any]
    }

    // MARK: Lottie Properties

    /// Animation source URL (shares `src` resolution with the image primitive).
    var autoplay: PropertyValue<Bool>? { getPropertyValue("autoplay") }
    var loop: PropertyValue<Bool>? { getPropertyValue("loop") }
    var speed: PropertyValue<Double>? { getPropertyValue("speed") }

    // MARK: Custom Component Properties

    /// Legacy: direct componentType string (deprecated, use customComponent.key)
    var componentType: String? { getRawValue("componentType") }

    /// Custom component identifier with key and version
    /// Supports: { "customComponent": { "key": "test_3", "version": 1 } }
    var customComponent: CustomComponentRef? {
        guard let dict = rawProps["customComponent"]?.value as? [String: Any],
              let key = dict["key"] as? String else {
            return nil
        }
        let version = dict["version"] as? Int ?? 1
        return CustomComponentRef(key: key, version: version)
    }

    /// Resolved component key - prefers customComponent.key, falls back to componentType
    var resolvedComponentKey: String? {
        customComponent?.key ?? componentType
    }

    /// Resolved component version - from customComponent.version, defaults to 1
    var resolvedComponentVersion: Int {
        customComponent?.version ?? 1
    }

    /// Unified inputs for custom components
    /// Supports:
    /// - New format: { "source": "value", "value": "constant" } or { "source": "bind", "variable": "var_key" }
    /// - Legacy format: { "bind": "var.path" } or { "value": "constant" }
    var componentInputs: [String: ComponentInputValue]? {
        guard let inputsDict = rawProps["inputs"]?.value as? [String: Any] else {
            return nil
        }

        var result: [String: ComponentInputValue] = [:]
        for (key, value) in inputsDict {
            if let inputDict = value as? [String: Any] {
                // Check for "source" field (new schema format)
                if let source = inputDict["source"] as? String {
                    switch source {
                    case "bind":
                        // Try "variable" key first (new format), then "bind" key (legacy)
                        if let bindPath = inputDict["variable"] as? String {
                            result[key] = .bind(bindPath)
                        } else if let bindPath = inputDict["bind"] as? String {
                            result[key] = .bind(bindPath)
                        } else {
                            Logger.shared.warn("Bind input '\(key)' missing 'variable' or 'bind' key")
                        }
                    case "value":
                        if let constValue = inputDict["value"] {
                            result[key] = parseConstantValue(constValue)
                        }
                    default:
                        Logger.shared.warn("Unknown input source type: \(source) for key '\(key)'")
                    }
                }
                // Legacy format without "source" field: { "bind": "..." } or { "value": ... }
                else if let bindPath = inputDict["bind"] as? String {
                    result[key] = .bind(bindPath)
                } else if let bindPath = inputDict["variable"] as? String {
                    result[key] = .bind(bindPath)
                } else if let constValue = inputDict["value"] {
                    result[key] = parseConstantValue(constValue)
                }
            } else if let bindPath = value as? String {
                // Very old legacy format: "input_name": "var.path" (treat as bind)
                result[key] = .bind(bindPath)
            }
        }

        return result.isEmpty ? nil : result
    }

    /// Parse a constant value into ComponentInputValue
    /// Note: Order matters! Check Bool before numbers (since Bool bridges to Int),
    /// and check numbers before String (since NSNumber can bridge to String)
    private func parseConstantValue(_ value: Any) -> ComponentInputValue? {
        // Check Bool first (before Int, since Bool bridges to Int in ObjC)
        if let bool = value as? Bool, type(of: value) == Bool.self || "\(type(of: value))" == "__NSCFBoolean" {
            return .value(.boolean(bool))
        }
        // Check numbers before String (NSNumber can bridge to String)
        if let num = value as? Int {
            return .value(.number(Double(num)))
        }
        if let num = value as? Double {
            return .value(.number(num))
        }
        // String last
        if let str = value as? String {
            return .value(.string(str))
        }
        return nil
    }

    // MARK: Initialization

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawProps = try container.decode([String: AnyCodable].self)
    }

    init(rawProps: [String: AnyCodable]) {
        self.rawProps = rawProps
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawProps)
    }

    /// Returns a copy with `defaults` applied only for keys not already present.
    /// Used to feed button variant colors (background/border) into the universal
    /// style pass so they paint on the padded, clipped frame instead of an inner
    /// content view — keeping button styling unified with stack (overhaul §2.2).
    func merging(defaults: [String: AnyCodable]) -> ComponentProps {
        var merged = defaults
        for (key, value) in rawProps { merged[key] = value }
        return ComponentProps(rawProps: merged)
    }

    /// Returns a copy with `patch` values overriding existing keys — the inverse
    /// precedence of `merging(defaults:)`. Used by per-screen zone component
    /// patches (`ZoneScreenOverride.componentProps`).
    func merging(patch: [String: AnyCodable]) -> ComponentProps {
        var merged = rawProps
        for (key, value) in patch { merged[key] = value }
        return ComponentProps(rawProps: merged)
    }

    /// Returns a copy with the given dimension keys forced to `auto` so the box
    /// hugs its content on that axis. Used by single-edge absolute anchoring: a
    /// fill dimension (e.g. height `100%`) would make the box span the whole
    /// parent and park its content at the opposite edge, defeating the inset.
    /// Mirrors the editor canvas (`isFillSize` collapse) and the Expo SDK.
    func collapsingDimensionsToAuto(_ keys: [String]) -> ComponentProps {
        var merged = rawProps
        for key in keys { merged[key] = AnyCodable("auto") }
        return ComponentProps(rawProps: merged)
    }

    // MARK: Helper Methods

    private func getRawValue<T>(_ key: String) -> T? {
        return rawProps[key]?.value as? T
    }

    private func getPropertyValue<T: Codable>(_ key: String) -> PropertyValue<T>? {
        guard let anyValue = rawProps[key] else { return nil }

        // Check if it's a PropertyValue structure
        if let dict = anyValue.value as? [String: Any], let typeStr = dict["type"] as? String {
            // It's a PropertyValue - decode it properly
            Logger.shared.debug("getPropertyValue - key '\(key)' is a PropertyValue with type '\(typeStr)'")
            do {
                let data = try JSONSerialization.data(withJSONObject: dict)
                let decoded = try JSONDecoder().decode(PropertyValue<T>.self, from: data)
                Logger.shared.debug("getPropertyValue - successfully decoded PropertyValue for key '\(key)'")
                return decoded
            } catch {
                Logger.shared.warn("Failed to decode PropertyValue for key \(key): \(error)")
                return nil
            }
        }

        // It's a raw value - wrap it as static
        if let value = anyValue.value as? T {
            return .static(value)
        }

        // Handle type coercion
        if T.self == Double.self {
            if let intValue = anyValue.value as? Int {
                return .static(Double(intValue) as! T)
            }
        }

        if T.self == String.self {
            let value = anyValue.value
            return .static(String(describing: value) as! T)
        }

        return nil
    }

    private func getDimensionValue(_ key: String) -> DimensionValue? {
        guard let anyValue = rawProps[key] else { return nil }

        if let string = anyValue.value as? String {
            if string == "auto" || string == "hug_content" || string == "content" {
                return .auto
            } else if string == "fill_container" || string == "fill" {
                return .percent(100)
            } else if string.hasSuffix("%") {
                if let percent = Double(string.dropLast()) {
                    return .percent(percent)
                }
            } else if string.hasSuffix("px") {
                // Handle "70px" format - extract number before "px"
                let valueStr = string.dropLast(2)
                if let value = Double(valueStr) {
                    return .fixed(value)
                }
            } else if let value = Double(string) {
                // Handle plain numeric strings like "70"
                return .fixed(value)
            }
            return nil
        }

        if let number = anyValue.value as? Double {
            return .fixed(number)
        }

        if let number = anyValue.value as? Int {
            return .fixed(Double(number))
        }

        return nil
    }

    /// Get any raw property value
    func getRaw(_ key: String) -> Any? {
        return rawProps[key]?.value
    }

    /// Safely coerces a value to `Double`, handling both `Int` and `Double` JSON types.
    private static func asDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}

// MARK: - Ring Auto Progress

/// One stage of a self-driving `ringProgress` loader timeline.
struct RingAutoProgressStage: Sendable {
    /// Cumulative fill target for this stage, 0..1.
    let target: Double
    /// Milliseconds to ease from the previous target to this target.
    let rampMs: Double
    /// Milliseconds to hold/pause at the target (the "stop at 45%").
    let holdMs: Double
    /// Caption shown while this stage is active.
    let caption: String?
}

/// Self-driving "analysis loader" config parsed from the `autoProgress` prop.
///
/// When present and enabled, the ring eases through `stages` over a timeline,
/// pausing at each, rendering a live percent in the center and swapping the
/// caption below it. Pure rendering (no variables / action chains), so it
/// matches the dashboard canvas and Expo SDK 1:1. `onComplete` fires once when
/// the final stage finishes (e.g. `goNext` to auto-advance).
struct RingAutoProgress: Sendable {
    let stages: [RingAutoProgressStage]
    let easing: String
    let showPercent: Bool
    let percentSuffix: String
    /// Vibrate once each time the ring reaches a stage's target.
    let haptic: Bool
    /// Haptic strength string mapped by `HapticManager` (e.g. light/medium/heavy).
    let hapticIntensity: String
    let loop: Bool
    let onComplete: [ComponentAction]
}

// MARK: - Dimension Value

/// Value for width/height dimensions
enum DimensionValue: Sendable {
    case auto
    case fixed(Double)
    case percent(Double)

    var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    var fixedValue: Double? {
        if case .fixed(let value) = self { return value }
        return nil
    }

    var percentValue: Double? {
        if case .percent(let value) = self { return value }
        return nil
    }
}

// MARK: - Scheduled Action

/// A `ComponentAction` plus an optional per-action `delay`.
///
/// `delay` is an absolute offset (ms) from when the interaction's event fired,
/// not a cumulative wait after the previous action. Actions in one chain
/// schedule independently, so `[setVariable@0, setVariable@1000]` walks a
/// variable through two values one second apart — which is how a stepped ring
/// (eased hops via a bound variable) is authored. See
/// COMPONENT_OVERHAUL_PLAN.md §3.1.
///
/// The wire shape is flat: `delay` sits alongside `kind` on the same object,
/// so this decodes the action from the same container and reads `delay` as a
/// sibling key. Keeping it a wrapper (rather than threading `delay` through
/// every `ComponentAction` case) leaves the action enum untouched.
struct ScheduledAction: Codable, Sendable {
    let action: ComponentAction
    /// Absolute offset in milliseconds from event fire; `nil`/`0` runs inline.
    let delay: Int?

    init(action: ComponentAction, delay: Int? = nil) {
        self.action = action
        self.delay = delay
    }

    private enum DelayCodingKeys: String, CodingKey {
        case delay
    }

    init(from decoder: Decoder) throws {
        action = try ComponentAction(from: decoder)
        let container = try decoder.container(keyedBy: DelayCodingKeys.self)
        delay = try container.decodeIfPresent(Int.self, forKey: .delay)
    }

    func encode(to encoder: Encoder) throws {
        try action.encode(to: encoder)
        var container = encoder.container(keyedBy: DelayCodingKeys.self)
        try container.encodeIfPresent(delay, forKey: .delay)
    }
}

// MARK: - Component Interaction

/// Interaction definition for a component
struct ComponentInteraction: Codable, Sendable {
    let id: String
    let event: ComponentEventType
    let actions: [ScheduledAction]

    /// Original event name string (useful for native component events)
    let eventName: String

    /// Custom event key for custom components
    /// For custom components, this is the ONLY field used for event routing.
    /// The `event` field is ignored for custom components (it's editor metadata).
    let customEventKey: String?

    enum CodingKeys: String, CodingKey {
        case id, event, actions, customEventKey
    }

    /// Programmatic initializer. Accepts plain actions (the SDK constructs
    /// chrome buttons etc. without delays) and wraps each with no delay.
    init(id: String, event: ComponentEventType, actions: [ComponentAction]) {
        self.id = id
        self.event = event
        self.actions = actions.map { ScheduledAction(action: $0) }
        self.eventName = event.rawValue
        self.customEventKey = nil
    }

    /// Initializer for custom events with a specific event name
    init(id: String, eventName: String, actions: [ComponentAction]) {
        self.id = id
        self.eventName = eventName
        self.actions = actions.map { ScheduledAction(action: $0) }
        self.customEventKey = nil

        // Convert to enum (custom events become .onCustomEvent)
        if let standardEvent = ComponentEventType(rawValue: eventName) {
            self.event = standardEvent
        } else {
            self.event = .onCustomEvent
        }
    }

    /// Initializer for custom component events with customEventKey
    init(id: String, customEventKey: String, actions: [ComponentAction]) {
        self.id = id
        self.customEventKey = customEventKey
        self.actions = actions.map { ScheduledAction(action: $0) }
        self.event = .onCustomEvent
        self.eventName = "onCustomEvent"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        actions = try container.decode([ScheduledAction].self, forKey: .actions)

        // Decode customEventKey if present (for custom component routing)
        customEventKey = try container.decodeIfPresent(String.self, forKey: .customEventKey)

        // Decode event as string first to preserve the original name
        // For custom components, event field may be absent - only customEventKey is required
        if let eventString = try container.decodeIfPresent(String.self, forKey: .event) {
            eventName = eventString
            // Convert to enum (custom events become .onCustomEvent)
            if let standardEvent = ComponentEventType(rawValue: eventString) {
                event = standardEvent
            } else {
                event = .onCustomEvent
            }
        } else if customEventKey != nil {
            // Custom component interaction: no event field, only customEventKey
            event = .onCustomEvent
            eventName = "onCustomEvent"
        } else {
            // Neither event nor customEventKey - this is invalid
            throw DecodingError.keyNotFound(
                CodingKeys.event,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Interaction must have either 'event' or 'customEventKey'"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(eventName, forKey: .event)
        try container.encode(actions, forKey: .actions)
        try container.encodeIfPresent(customEventKey, forKey: .customEventKey)
    }
}

/// Type of component event
enum ComponentEventType: String, Codable, Sendable {
    case onPress
    case onChange
    case onFocus
    case onBlur
    case onAppear

    // Custom component events - these are dynamically matched by name
    case onCustomEvent

    /// Initialize from a string, supporting custom event names
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        // Try standard events first
        if let standardEvent = ComponentEventType(rawValue: rawValue) {
            self = standardEvent
        } else {
            // Treat unknown events as custom (they'll be matched by interaction ID)
            self = .onCustomEvent
        }
    }
}

// MARK: - Component Action

/// Single assignment entry inside an `assign` action.
///
/// The expression is a FlowExpression string evaluated by `ExpressionEvaluator`
/// (safe subset: literals, variable references, single binary op).
struct AssignmentEntry: Codable, Sendable, Equatable {
    let variableKey: String
    let expression: String
}

/// Action that can be triggered by a component
enum ComponentAction: Codable, Sendable {
    case navigate(targetNodeId: String)
    case goNext
    case goBack
    case closeFlow
    case assign(assignments: [AssignmentEntry])
    case setVariable(variableKey: String, operation: String, value: VariableValue?)
    case trackEvent(eventKey: String, properties: [String: AnyCodable]?)
    case openUrl(url: String)
    case haptic(intensity: String)
    case requestReview
    case custom(actionKey: String, params: [String: AnyCodable]?)
    case triggerAnimation(targetComponentId: String, animation: String, stepId: String?)
    case triggerParticle(effect: String, duration: Int?, colors: [String]?, emoji: [String]?,
                            density: String?, size: String?, direction: String?,
                            spread: Double?, gravity: Double?, speed: Double?,
                            delay: Int?, haptic: String?)

    enum CodingKeys: String, CodingKey {
        case kind, targetNodeId, variableKey, operation, value, assignments
        case eventKey, properties, url, intensity, actionKey, params
        case targetComponentId, animation, stepId, effect, duration, colors, emoji
        case density, size, direction, spread, gravity, speed, delay, haptic
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        case "navigate":
            let targetNodeId = try container.decode(String.self, forKey: .targetNodeId)
            self = .navigate(targetNodeId: targetNodeId)

        case "goNext":
            self = .goNext

        case "goBack":
            self = .goBack

        case "closeFlow":
            self = .closeFlow

        case "assign":
            let assignments = try container.decodeIfPresent([AssignmentEntry].self, forKey: .assignments) ?? []
            self = .assign(assignments: assignments)

        case "setVariable":
            let variableKey = try container.decode(String.self, forKey: .variableKey)
            let operation = try container.decode(String.self, forKey: .operation)
            let value = try container.decodeIfPresent(VariableValue.self, forKey: .value)
            self = .setVariable(variableKey: variableKey, operation: operation, value: value)

        case "trackEvent":
            let eventKey = try container.decode(String.self, forKey: .eventKey)
            let properties = try container.decodeIfPresent([String: AnyCodable].self, forKey: .properties)
            self = .trackEvent(eventKey: eventKey, properties: properties)

        case "openUrl":
            let url = try container.decode(String.self, forKey: .url)
            self = .openUrl(url: url)

        case "haptic":
            let intensity = try container.decodeIfPresent(String.self, forKey: .intensity) ?? "medium"
            self = .haptic(intensity: intensity)

        case "requestReview":
            self = .requestReview

        case "custom":
            let actionKey = try container.decode(String.self, forKey: .actionKey)
            let params = try container.decodeIfPresent([String: AnyCodable].self, forKey: .params)
            self = .custom(actionKey: actionKey, params: params)

        case "triggerAnimation":
            let targetComponentId = try container.decode(String.self, forKey: .targetComponentId)
            let animation = try container.decodeIfPresent(String.self, forKey: .animation) ?? "enter"
            let stepId = try container.decodeIfPresent(String.self, forKey: .stepId)
            self = .triggerAnimation(targetComponentId: targetComponentId, animation: animation, stepId: stepId)

        case "triggerParticle":
            let effect = try container.decode(String.self, forKey: .effect)
            let duration = try container.decodeIfPresent(Int.self, forKey: .duration)
            let colors = try container.decodeIfPresent([String].self, forKey: .colors)
            let emoji = try container.decodeIfPresent([String].self, forKey: .emoji)
            let density = try container.decodeIfPresent(String.self, forKey: .density)
            let size = try container.decodeIfPresent(String.self, forKey: .size)
            let direction = try container.decodeIfPresent(String.self, forKey: .direction)
            let spread = try container.decodeIfPresent(Double.self, forKey: .spread)
            let gravity = try container.decodeIfPresent(Double.self, forKey: .gravity)
            let speed = try container.decodeIfPresent(Double.self, forKey: .speed)
            let delay = try container.decodeIfPresent(Int.self, forKey: .delay)
            let haptic = try container.decodeIfPresent(String.self, forKey: .haptic)
            self = .triggerParticle(effect: effect, duration: duration, colors: colors, emoji: emoji,
                                   density: density, size: size, direction: direction,
                                   spread: spread, gravity: gravity, speed: speed,
                                   delay: delay, haptic: haptic)

        default:
            Logger.shared.warn("Unknown action kind: \(kind)")
            self = .custom(actionKey: kind, params: nil)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .navigate(let targetNodeId):
            try container.encode("navigate", forKey: .kind)
            try container.encode(targetNodeId, forKey: .targetNodeId)

        case .goNext:
            try container.encode("goNext", forKey: .kind)

        case .goBack:
            try container.encode("goBack", forKey: .kind)

        case .closeFlow:
            try container.encode("closeFlow", forKey: .kind)

        case .assign(let assignments):
            try container.encode("assign", forKey: .kind)
            try container.encode(assignments, forKey: .assignments)

        case .setVariable(let variableKey, let operation, let value):
            try container.encode("setVariable", forKey: .kind)
            try container.encode(variableKey, forKey: .variableKey)
            try container.encode(operation, forKey: .operation)
            try container.encodeIfPresent(value, forKey: .value)

        case .trackEvent(let eventKey, let properties):
            try container.encode("trackEvent", forKey: .kind)
            try container.encode(eventKey, forKey: .eventKey)
            try container.encodeIfPresent(properties, forKey: .properties)

        case .openUrl(let url):
            try container.encode("openUrl", forKey: .kind)
            try container.encode(url, forKey: .url)

        case .haptic(let intensity):
            try container.encode("haptic", forKey: .kind)
            try container.encode(intensity, forKey: .intensity)

        case .requestReview:
            try container.encode("requestReview", forKey: .kind)

        case .custom(let actionKey, let params):
            try container.encode("custom", forKey: .kind)
            try container.encode(actionKey, forKey: .actionKey)
            try container.encodeIfPresent(params, forKey: .params)

        case .triggerAnimation(let targetComponentId, let animation, let stepId):
            try container.encode("triggerAnimation", forKey: .kind)
            try container.encode(targetComponentId, forKey: .targetComponentId)
            try container.encode(animation, forKey: .animation)
            try container.encodeIfPresent(stepId, forKey: .stepId)

        case .triggerParticle(let effect, let duration, let colors, let emoji,
                              let density, let size, let direction,
                              let spread, let gravity, let speed,
                              let delay, let haptic):
            try container.encode("triggerParticle", forKey: .kind)
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
            try container.encodeIfPresent(delay, forKey: .delay)
            try container.encodeIfPresent(haptic, forKey: .haptic)
        }
    }

    var kind: String {
        switch self {
        case .navigate: return "navigate"
        case .goNext: return "goNext"
        case .goBack: return "goBack"
        case .closeFlow: return "closeFlow"
        case .assign: return "assign"
        case .setVariable: return "setVariable"
        case .trackEvent: return "trackEvent"
        case .openUrl: return "openUrl"
        case .haptic: return "haptic"
        case .requestReview: return "requestReview"
        case .custom: return "custom"
        case .triggerAnimation: return "triggerAnimation"
        case .triggerParticle: return "triggerParticle"
        }
    }
}

// MARK: - Text Effect Config

/// Configuration for text reveal effects (typewriter, countUp, scramble, fadePerLine).
///
/// Parsed from the `textEffect` grouped prop on text components.
struct TextEffectConfig: Sendable {
    /// The effect type: "typewriter", "typewriterWord", "fadePerLine", "countUp", "scramble"
    let type: String

    /// Characters per second for typewriter/scramble effects (default: 40)
    let speed: Double

    /// Delay in milliseconds before the effect starts (default: 0)
    let delay: Double

    /// Explicit duration in milliseconds. Used by countUp (total animation time, default: 2000)
    /// and fadePerLine (interval between lines, default: 250). Nil means derive from speed.
    let duration: Double?

    /// Cursor style: "none", "blink", "solid" (default: "blink")
    let cursor: String

    /// Cursor character (default: "|")
    let cursorChar: String

    /// Whether to fire haptic tick per character (default: false)
    let haptic: Bool
}

// MARK: - Text Rotation Config

/// Configuration for cycling through multiple text values with transitions.
///
/// Parsed from the `textRotation` grouped prop on text components.
struct TextRotationConfig: Sendable {
    /// Whether text rotation is enabled
    let enabled: Bool

    /// Array of text values to cycle through (the component's content is the first value)
    let values: [String]

    /// Milliseconds per value display (default: 2000)
    let interval: Double

    /// Transition type: "slideUp", "slideDown", "fadeThrough", "crossFade", "flip", "scramble"
    let transition: String

    /// Transition duration in milliseconds (default: 400)
    let transitionDuration: Double

    /// Whether to loop the rotation (default: true)
    let loop: Bool

    /// Whether to pause on the last value (default: false)
    let pauseOnLast: Bool
}

// MARK: - Rich Text Segment

/// A single inline-styled run inside a Rich Text node (`props.richText`).
///
/// Rich Text is NOT a new component kind: it is the regular `text` component
/// carrying an optional `richText` array of styled runs. When present and
/// non-empty, `TextView` renders the runs as an `AttributedString`; otherwise it
/// renders the plain `text` string. `props.text` is always the concatenated
/// plain-text fallback, so an older build that ignores `richText` still shows the
/// content.
struct RichTextSegment: Sendable {
    let text: String
    let bold: Bool
    let italic: Bool
    let underline: Bool
    let strikethrough: Bool
    /// Per-run colour (hex). Falls back to the node's `color` when nil.
    let color: String?
}

// MARK: - Input Validation

/// Lightweight client-side validation for input components
struct InputValidation {
    let required: Bool
    let minLength: Int?
    let maxLength: Int?
    let pattern: String?
    let patternMessage: String?

    init?(from dict: [String: Any]?) {
        guard let dict = dict else { return nil }
        self.required = dict["required"] as? Bool ?? false
        self.minLength = dict["minLength"] as? Int
        self.maxLength = dict["maxLength"] as? Int
        self.pattern = dict["pattern"] as? String
        self.patternMessage = dict["patternMessage"] as? String
    }

    func validate(_ value: String) -> ValidationResult {
        if required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalid("This field is required")
        }
        if let min = minLength, value.count < min {
            return .invalid("Minimum \(min) characters required")
        }
        if let max = maxLength, value.count > max {
            return .invalid("Maximum \(max) characters allowed")
        }
        if let pattern = pattern, !value.isEmpty {
            let regex = try? NSRegularExpression(pattern: pattern)
            let range = NSRange(value.startIndex..., in: value)
            if regex?.firstMatch(in: value, range: range) == nil {
                return .invalid(patternMessage ?? "Invalid format")
            }
        }
        return .valid
    }
}

/// Result of input validation
enum ValidationResult {
    case valid
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .invalid(let msg) = self { return msg }
        return nil
    }
}
