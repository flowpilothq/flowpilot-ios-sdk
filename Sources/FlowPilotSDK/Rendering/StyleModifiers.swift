import SwiftUI

// MARK: - Parent Size Environment Key

/// Environment key that carries the parent container's measured size.
///
/// Parent containers (StackView, ScreenRootView) inject their rendered size into
/// the environment so that child components can resolve percentage-based width and
/// height values (e.g., `width: "50%"`) relative to the parent.
///
/// When no parent has injected a size (i.e. at the very top of the view hierarchy
/// before ScreenRootView measures itself), the default value is `.zero`, which
/// causes percentage dimensions to fall back to `nil` (intrinsic sizing).
struct ParentSizeKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

extension EnvironmentValues {
    /// The measured size of the nearest parent container.
    ///
    /// Children use this to compute concrete point values for percentage-based
    /// dimension properties (e.g., `width: "50%"` becomes `parentSize.width * 0.5`).
    var parentSize: CGSize {
        get { self[ParentSizeKey.self] }
        set { self[ParentSizeKey.self] = newValue }
    }

    /// The CSS flex-shrink factor applied to a **direct** child's resolved width.
    ///
    /// A horizontal stack whose children's natural widths overflow the available
    /// space sets this (< 1.0) on its children to replicate CSS `flex-shrink: 1`:
    /// the children shrink proportionally to fit instead of overflowing (SwiftUI
    /// `HStack` has no flex-shrink — fixed-width children stay rigid). The default
    /// `1.0` is a no-op, and `UniversalStyleModifier` resets it to `1.0` for the
    /// subtree below each child so it never cascades past one level.
    var horizontalShrinkScale: CGFloat {
        get { self[HorizontalShrinkScaleKey.self] }
        set { self[HorizontalShrinkScaleKey.self] = newValue }
    }
}

/// Environment key carrying the CSS flex-shrink factor for a direct stack child.
struct HorizontalShrinkScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

// MARK: - Parent Size Injector

/// A view modifier that measures its own rendered size and injects it into
/// the environment as `parentSize` for all descendant views.
///
/// This is used by container views (StackView, ScreenRootView) so their children
/// can resolve percentage-based dimensions relative to the container's actual size.
///
/// Implementation note: A background `GeometryReader` captures the container's
/// rendered size without altering its layout. The size is written straight into
/// this modifier's own `@State` from the reader's `onAppear`/`onChange`, which
/// triggers a second layout pass the first time it becomes available. This is the
/// standard SwiftUI pattern for size-dependent layouts and produces no visible
/// flicker because the initial render with `.zero` parent size causes percentage
/// children to use intrinsic sizing, which is a reasonable default.
///
/// Why not a `PreferenceKey`: stacks nest, so a *shared* size preference key
/// leaks every descendant injector's reading up into its ancestors'
/// `onPreferenceChange` (last value wins in `reduce`). A nested injector then
/// settles on a child's size — or never settles off `.zero` — so percentage
/// children resolve against the wrong base (or `nil`). Writing each level's size
/// directly into its own `@State` keeps every injector isolated.
struct ParentSizeInjector: ViewModifier {
    @State private var measuredSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geometry in
                    Color.clear
                        // Write *this* injector's own size into its own @State.
                        // No shared PreferenceKey => no cross-talk between the
                        // nested injectors that stacks-within-stacks create.
                        .onAppear { updateSize(geometry.size) }
                        .onChange(of: geometry.size) { newSize in updateSize(newSize) }
                }
            )
            .environment(\.parentSize, measuredSize)
    }

    private func updateSize(_ newSize: CGSize) {
        // Only update when the size actually changes to avoid unnecessary re-renders.
        if measuredSize != newSize {
            measuredSize = newSize
        }
    }
}

extension View {
    /// Measures this view's rendered size and injects it as `parentSize` into
    /// the environment for all descendant views.
    ///
    /// Attach this to container views whose children may use percentage-based
    /// dimensions (e.g., `width: "50%"`).
    func injectParentSize() -> some View {
        modifier(ParentSizeInjector())
    }
}

// MARK: - Adaptive Corner Radius Shape

/// A shape that supports both uniform and per-corner radius values.
/// Uses `UnevenRoundedRectangle` on iOS 16+ for true per-corner support,
/// and falls back to the maximum corner radius with a standard `RoundedRectangle` on iOS 15.
struct AdaptiveCornerShape: Shape {
    let topLeft: CGFloat
    let topRight: CGFloat
    let bottomLeft: CGFloat
    let bottomRight: CGFloat

    /// Convenience initializer for uniform corner radius on all corners.
    init(uniform radius: CGFloat) {
        self.topLeft = radius
        self.topRight = radius
        self.bottomLeft = radius
        self.bottomRight = radius
    }

    /// Initializer for per-corner radius values.
    init(topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    func path(in rect: CGRect) -> Path {
        if #available(iOS 16.0, macOS 13.0, *) {
            return UnevenRoundedRectangle(
                topLeadingRadius: topLeft,
                bottomLeadingRadius: bottomLeft,
                bottomTrailingRadius: bottomRight,
                topTrailingRadius: topRight
            ).path(in: rect)
        } else {
            // Fallback: use the maximum corner value for a uniform RoundedRectangle
            let maxRadius = max(topLeft, topRight, bottomLeft, bottomRight)
            return RoundedRectangle(cornerRadius: maxRadius).path(in: rect)
        }
    }
}

// MARK: - Universal Style Modifier

/// Applies universal styling properties to any component
struct UniversalStyleModifier: ViewModifier {
    let props: ComponentProps?
    let variableStore: VariableStore
    var renderTrigger: Int = 0

    /// The measured size of the parent container, injected via the environment
    /// by StackView / ScreenRootView. Used to resolve non-100% percentage
    /// dimensions (e.g., `width: "50%"` -> `parentSize.width * 0.5`).
    @Environment(\.parentSize) private var parentSize

    /// CSS flex-shrink factor injected by an over-allocated horizontal stack onto
    /// this (direct) child. Multiplies the resolved fixed/percent width so the
    /// child shrinks to fit instead of overflowing. `1.0` (default) is a no-op.
    @Environment(\.horizontalShrinkScale) private var horizontalShrinkScale

    func body(content: Content) -> some View {
        // Force re-evaluation when renderTrigger changes
        let _ = renderTrigger

        let resolvedWidth = resolveWidth()
        let resolvedHeight = resolveHeight()
        let marginTop = CGFloat(resolveDouble(props?.marginTop, default: 0))
        let marginBottom = CGFloat(resolveDouble(props?.marginBottom, default: 0))
        let marginLeft = CGFloat(resolveDouble(props?.marginLeft, default: 0))
        let marginRight = CGFloat(resolveDouble(props?.marginRight, default: 0))
        let hasHorizontalMargin = marginLeft > 0 || marginRight > 0

        let _ = Logger.shared.debug("[StyleMod] resolvedWidth=\(resolvedWidth.map { String(describing: $0) } ?? "nil") resolvedHeight=\(resolvedHeight.map { String(describing: $0) } ?? "nil") padL=\(resolvePaddingLeft()) padR=\(resolvePaddingRight()) padT=\(resolvePaddingTop()) padB=\(resolvePaddingBottom()) isFullWidth=\(resolvedWidth == .infinity) hasHMargin=\(hasHorizontalMargin) fill=\(PropertyResolver.resolve(props?.fill, store: variableStore) ?? "nil")")

        // When width is .infinity (100%) and horizontal margins exist, we must
        // replicate the web editor's calc(100% - marginLeft - marginRight) behavior.
        // In SwiftUI, this means:
        //   1. Apply margin as outer padding FIRST so it reduces available space
        //   2. Then let .frame(maxWidth: .infinity) fill the remaining space
        //   3. Visual decorations (background, border, etc.) stay inside the margin
        //
        // For fixed-width or auto-width components, the original order is correct
        // because the frame size is independent of available space.
        let isFullWidth = resolvedWidth == .infinity

        // Reset the flex-shrink factor for this component's subtree. The scale an
        // over-wide parent row injects (consumed above by `resolveWidth`) must
        // affect ONLY this direct child's width, never cascade to grandchildren.
        let content = content.environment(\.horizontalShrinkScale, 1.0)

        if isFullWidth && hasHorizontalMargin {
            // Full-width with horizontal margins:
            // Replicates the web editor's calc(100% - marginLeft - marginRight).
            // Margin is applied OUTSIDE the frame so SwiftUI's layout system
            // reduces the available space before the frame fills it.
            content
                // Padding (inner spacing)
                .padding(.top, resolvePaddingTop())
                .padding(.bottom, resolvePaddingBottom())
                .padding(.leading, resolvePaddingLeft())
                .padding(.trailing, resolvePaddingRight())
                // Frame: use maxWidth so it fills whatever space remains after outer margin
                .frame(
                    maxWidth: .infinity,
                    minHeight: resolvedHeight,
                    maxHeight: resolvedHeight
                )
                // Min/Max size constraints (excluding maxWidth since we set it above)
                .frame(
                    minWidth: resolveMinWidth(),
                    minHeight: resolveMinHeight(),
                    maxHeight: resolveMaxHeight()
                )
                // Background (after frame so it covers the full frame area)
                .background { resolveBackgroundFill() }
                // Corner radius & overflow clipping
                .applyOverflowClipping(overflow: resolveOverflow(), cornerShape: resolveCornerShape())
                // Border
                .overlay(resolveBorderOverlay())
                // Shadow: inset shadows use an overlay technique; outer shadows use .shadow()
                .applyBoxShadow(
                    isInner: resolveShadowIsInner(),
                    color: resolveShadowColor(),
                    radius: resolveShadowRadius(),
                    x: resolveDouble(props?.boxShadowX, default: 0),
                    y: resolveDouble(props?.boxShadowY, default: 4),
                    innerOverlay: { resolveInnerShadowOverlay() }
                )
                // Margin applied OUTSIDE frame + decorations so it reduces available space
                .padding(.top, marginTop)
                .padding(.bottom, marginBottom)
                .padding(.leading, marginLeft)
                .padding(.trailing, marginRight)
                // Relative positioning (CSS position: relative → offset from normal flow)
                .modifier(PositionOffsetModifier(props: props, variableStore: variableStore))
                // Opacity
                .opacity(resolveDouble(props?.opacity, default: 100) / 100)
        } else {
            // Fixed-width, auto-width, or full-width without horizontal margin
            content
                // Padding (inner spacing) — applied BEFORE frame to match CSS
                // box-sizing: border-box, where padding is inside the declared
                // width/height. Previously padding was after frame, causing it to
                // expand beyond the declared dimensions.
                .padding(.top, resolvePaddingTop())
                .padding(.bottom, resolvePaddingBottom())
                .padding(.leading, resolvePaddingLeft())
                .padding(.trailing, resolvePaddingRight())
                // Size
                .frame(
                    width: resolvedWidth,
                    height: resolvedHeight
                )
                // Min/Max size constraints
                .frame(
                    minWidth: resolveMinWidth(),
                    maxWidth: resolveMaxWidth(),
                    minHeight: resolveMinHeight(),
                    maxHeight: resolveMaxHeight()
                )
                // Background
                .background { resolveBackgroundFill() }
                // Corner radius & overflow clipping
                .applyOverflowClipping(overflow: resolveOverflow(), cornerShape: resolveCornerShape())
                // Border
                .overlay(resolveBorderOverlay())
                // Shadow: inset shadows use an overlay technique; outer shadows use .shadow()
                .applyBoxShadow(
                    isInner: resolveShadowIsInner(),
                    color: resolveShadowColor(),
                    radius: resolveShadowRadius(),
                    x: resolveDouble(props?.boxShadowX, default: 0),
                    y: resolveDouble(props?.boxShadowY, default: 4),
                    innerOverlay: { resolveInnerShadowOverlay() }
                )
                // Margin (outside visual decorations)
                .padding(.top, marginTop)
                .padding(.bottom, marginBottom)
                .padding(.leading, marginLeft)
                .padding(.trailing, marginRight)
                // Relative positioning (CSS position: relative → offset from normal flow)
                .modifier(PositionOffsetModifier(props: props, variableStore: variableStore))
                // Opacity
                .opacity(resolveDouble(props?.opacity, default: 100) / 100)
        }
    }

    // MARK: - Size Resolution

    private func resolveWidth() -> CGFloat? {
        // Note: The `fill` property controls background fill type (solid/none),
        // NOT width sizing. The web editor's style-helpers.ts only uses `fill`
        // to decide whether to apply backgroundColor. Width comes exclusively
        // from the `width` property (auto, fixed, or percent).

        guard let dimension = props?.width else { return nil }

        switch dimension {
        case .auto:
            return nil
        case .fixed(let value):
            // Ensure value is valid (non-negative and finite)
            let cgValue = CGFloat(value)
            guard cgValue >= 0, cgValue.isFinite else { return nil }
            // Apply CSS flex-shrink (1.0 = no-op) so an over-wide horizontal row
            // shrinks its fixed-width children to fit instead of overflowing.
            return cgValue * horizontalShrinkScale
        case .percent(let value):
            if value == 100 {
                // CSS flex-shrink for a 100%-width child of an over-allocated
                // horizontal row: the row injects a shrink factor (< 1.0) so two
                // 100%-width siblings can share the row instead of each greedily
                // filling it. A `.infinity` frame cannot be scaled, so when a
                // shrink factor is present we must resolve 100% to a CONCRETE
                // width (the parent's content width × factor) — otherwise the
                // child overflows. Yoga/Expo treat `width: 100%` as flex-basis
                // with flex-shrink: 1; this matches that. With no shrink (factor
                // 1.0, the default) we keep block-level `.infinity` fill so a
                // lone 100%-width child still expands normally.
                if horizontalShrinkScale < 1.0, parentSize.width > 0 {
                    return parentSize.width * horizontalShrinkScale
                }
                return .infinity
            }
            // Non-100% percentage: compute from the parent container's measured width.
            // If parent size is not yet available (zero), fall back to nil (intrinsic sizing).
            guard parentSize.width > 0 else { return nil }
            return parentSize.width * CGFloat(value) / 100 * horizontalShrinkScale
        }
    }

    private func resolveHeight() -> CGFloat? {
        guard let dimension = props?.height else { return nil }

        switch dimension {
        case .auto:
            return nil
        case .fixed(let value):
            // Ensure value is valid (non-negative and finite)
            let cgValue = CGFloat(value)
            guard cgValue >= 0, cgValue.isFinite else { return nil }
            return cgValue
        case .percent(let value):
            if value == 100 {
                return .infinity
            }
            // Non-100% percentage: compute from the parent container's measured height.
            // If parent size is not yet available (zero), fall back to nil (intrinsic sizing).
            guard parentSize.height > 0 else { return nil }
            return parentSize.height * CGFloat(value) / 100
        }
    }

    // MARK: - Min/Max Size Resolution

    private func resolveMinWidth() -> CGFloat? {
        guard let dimension = props?.minWidth else { return nil }
        return resolveDimension(dimension, parentLength: parentSize.width)
    }

    private func resolveMaxWidth() -> CGFloat? {
        guard let dimension = props?.maxWidth else { return nil }
        return resolveDimension(dimension, parentLength: parentSize.width)
    }

    private func resolveMinHeight() -> CGFloat? {
        guard let dimension = props?.minHeight else { return nil }
        return resolveDimension(dimension, parentLength: parentSize.height)
    }

    private func resolveMaxHeight() -> CGFloat? {
        guard let dimension = props?.maxHeight else { return nil }
        return resolveDimension(dimension, parentLength: parentSize.height)
    }

    /// Shared helper to resolve a `DimensionValue` against a parent length.
    ///
    /// - Parameters:
    ///   - dimension: The dimension value to resolve (auto, fixed, percent).
    ///   - parentLength: The parent container's length along the relevant axis.
    /// - Returns: A concrete CGFloat, `.infinity` for 100%, or `nil` for auto / unavailable parent.
    private func resolveDimension(_ dimension: DimensionValue, parentLength: CGFloat) -> CGFloat? {
        switch dimension {
        case .auto:
            return nil
        case .fixed(let value):
            let cgValue = CGFloat(value)
            guard cgValue >= 0, cgValue.isFinite else { return nil }
            return cgValue
        case .percent(let value):
            if value == 100 {
                return .infinity
            }
            guard parentLength > 0 else { return nil }
            return parentLength * CGFloat(value) / 100
        }
    }

    // MARK: - Color Resolution

    /// The component's background fill: a `backgroundGradient` (the Simple-mode
    /// Gradient button and any gradient-filled box) wins over a solid
    /// `backgroundColor`, which stays a sensible fallback. `fill: "none"`
    /// suppresses it. Applied via `.background { }` so the corner-shape clip
    /// downstream rounds the gradient too.
    @ViewBuilder
    private func resolveBackgroundFill() -> some View {
        if let fill = PropertyResolver.resolve(props?.fill, store: variableStore),
           fill == "none" {
            Color.clear
        } else if let gradient = props?.backgroundGradient {
            GradientFill(gradient: resolveGradientColors(gradient))
        } else if let colorStr = PropertyResolver.resolve(props?.backgroundColor, store: variableStore) {
            Color(hex: colorStr) ?? Color.clear
        } else {
            Color.clear
        }
    }

    /// Resolve each gradient stop's colour (a `token:` ref or `{{var}}` or a
    /// literal hex) to a concrete colour string, so `Color(hex:)` can parse it —
    /// the same per-prop resolution solid colours get, applied per stop.
    private func resolveGradientColors(_ gradient: GradientDefinition) -> GradientDefinition {
        let stops = gradient.colors.map { stop in
            GradientStop(
                color: variableStore.resolveThemeToken(variableStore.interpolate(stop.color)),
                position: stop.position
            )
        }
        return GradientDefinition(
            type: gradient.type,
            colors: stops,
            angle: gradient.angle,
            centerX: gradient.centerX,
            centerY: gradient.centerY
        )
    }

    private func resolveBorderColor() -> Color {
        guard let colorStr = PropertyResolver.resolve(props?.borderColor, store: variableStore) else {
            return .clear
        }
        let borderOpacity = resolveDouble(props?.borderOpacity, default: 100) / 100.0
        return (Color(hex: colorStr) ?? .clear).opacity(borderOpacity)
    }

    // MARK: - Border Style Resolution

    /// Builds the border overlay view, respecting `borderStyle` (solid, dashed, dotted, none).
    /// Returns an `EmptyView` when the border should not be rendered (style is "none" or width is 0).
    @ViewBuilder
    private func resolveBorderOverlay() -> some View {
        let borderWidth = resolveDouble(props?.borderWidth, default: 0)
        let borderStyleStr = PropertyResolver.resolve(props?.borderStyle, store: variableStore) ?? "solid"

        if borderStyleStr == "none" || borderWidth <= 0 {
            EmptyView()
        } else {
            let strokeStyle = resolveBorderStrokeStyle(
                borderWidth: CGFloat(borderWidth),
                borderStyleStr: borderStyleStr
            )
            resolveCornerShape()
                .stroke(resolveBorderColor(), style: strokeStyle)
        }
    }

    /// Maps a border style string to a SwiftUI `StrokeStyle` with appropriate dash patterns.
    ///
    /// - Parameters:
    ///   - borderWidth: The resolved border width in points.
    ///   - borderStyleStr: One of "solid", "dashed", "dotted", or "none".
    /// - Returns: A configured `StrokeStyle`.
    private func resolveBorderStrokeStyle(borderWidth: CGFloat, borderStyleStr: String) -> StrokeStyle {
        switch borderStyleStr {
        case "dashed":
            return StrokeStyle(lineWidth: borderWidth, dash: [6, 3])
        case "dotted":
            return StrokeStyle(lineWidth: borderWidth, lineCap: .round, dash: [0.5, borderWidth * 2.5])
        default: // "solid" and any unrecognised value
            return StrokeStyle(lineWidth: borderWidth)
        }
    }

    private func resolveShadowColor() -> Color {
        guard let colorStr = PropertyResolver.resolve(props?.boxShadowColor, store: variableStore) else {
            return .clear
        }
        let opacity = resolveDouble(props?.boxShadowOpacity, default: 0) / 100
        return (Color(hex: colorStr) ?? .black).opacity(opacity)
    }

    /// Resolves the shadow radius, adjusting for the CSS `box-shadow` spread parameter.
    ///
    /// SwiftUI's `.shadow(radius:)` has no direct equivalent of CSS `box-shadow` spread.
    /// CSS spread uniformly expands (positive) or contracts (negative) the shadow shape.
    /// This method approximates the effect by adding the spread value to half the blur
    /// radius: `max(0, (blur / 2) + spread)`.
    ///
    /// - A positive spread increases the effective shadow radius, making the shadow larger.
    /// - A negative spread decreases it, shrinking or eliminating the shadow.
    /// - The result is clamped to zero so a large negative spread never produces a negative radius.
    private func resolveShadowRadius() -> CGFloat {
        let blur = resolveDouble(props?.boxShadowBlur, default: 8)
        let spread = resolveDouble(props?.boxShadowSpread, default: 0)
        let adjustedRadius = max(0, (blur / 2) + spread)
        return CGFloat(adjustedRadius)
    }

    /// Resolves whether the box shadow is an inset (inner) shadow.
    ///
    /// When `true`, the shadow is rendered inside the element using an overlay technique
    /// instead of the standard SwiftUI external `.shadow()` modifier. This replicates the
    /// CSS `box-shadow: inset` behavior.
    private func resolveShadowIsInner() -> Bool {
        PropertyResolver.resolve(props?.boxShadowInner, store: variableStore, default: false)
    }

    /// Builds an inner (inset) shadow overlay view that simulates CSS `box-shadow: inset`.
    ///
    /// SwiftUI has no built-in inset shadow modifier. This method approximates the effect by
    /// stroking the corner shape with the shadow color, blurring it, offsetting it by the
    /// shadow's x/y values, and clipping to the corner shape so only the interior portion
    /// of the blurred stroke is visible -- producing a convincing inner shadow.
    ///
    /// The stroke `lineWidth` is set to `max(shadowRadius * 2, 1)` so the blurred edge
    /// has enough material to create a soft glow inside the shape boundaries.
    ///
    /// Returns `EmptyView` when the shadow color is clear or the radius is zero, avoiding
    /// unnecessary compositing work.
    @ViewBuilder
    private func resolveInnerShadowOverlay() -> some View {
        let shadowColor = resolveShadowColor()
        let shadowRadius = resolveShadowRadius()
        let shadowX = resolveDouble(props?.boxShadowX, default: 0)
        let shadowY = resolveDouble(props?.boxShadowY, default: 4)

        if shadowColor != .clear, shadowRadius > 0 {
            resolveCornerShape()
                .stroke(shadowColor, lineWidth: max(shadowRadius * 2, 1))
                .blur(radius: shadowRadius)
                .offset(x: CGFloat(shadowX), y: CGFloat(shadowY))
                .clipShape(resolveCornerShape())
        } else {
            EmptyView()
        }
    }

    // MARK: - Corner Radius

    private func resolveCornerRadius() -> CGFloat {
        let radius = resolveDouble(props?.cornerRadius, default: 0)
        return CGFloat(radius)
    }

    /// Resolves the corner shape, supporting per-corner radius when `cornerAdvanced` is true.
    /// When advanced corners are enabled, reads `cornerTopLeft`, `cornerTopRight`,
    /// `cornerBottomLeft`, and `cornerBottomRight` individually.
    /// Falls back to the uniform `cornerRadius` value otherwise.
    private func resolveCornerShape() -> AdaptiveCornerShape {
        if props?.cornerAdvanced == true {
            let tl = CGFloat(resolveDouble(props?.cornerTopLeft, default: 0))
            let tr = CGFloat(resolveDouble(props?.cornerTopRight, default: 0))
            let bl = CGFloat(resolveDouble(props?.cornerBottomLeft, default: 0))
            let br = CGFloat(resolveDouble(props?.cornerBottomRight, default: 0))
            return AdaptiveCornerShape(topLeft: tl, topRight: tr, bottomLeft: bl, bottomRight: br)
        }
        return AdaptiveCornerShape(uniform: resolveCornerRadius())
    }

    // MARK: - Overflow Resolution

    /// Resolves the `overflow` property from props.
    ///
    /// Returns `"visible"`, `"hidden"`, or `nil` when the property is not set.
    /// The value `"auto"` is treated as unset (returns `nil`) so that default
    /// clipping behaviour applies.
    private func resolveOverflow() -> String? {
        guard let value = PropertyResolver.resolve(props?.overflow, store: variableStore) else {
            return nil
        }
        let normalized = value.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "visible", "hidden":
            return normalized
        default:
            // "auto", "scroll", or any unrecognised value -- fall back to default behaviour
            return nil
        }
    }

    // MARK: - Padding Resolution

    /// Whether advanced (per-edge) padding mode is enabled.
    ///
    /// The web editor uses `paddingAdvanced` as a gate:
    /// - `false` (default): ONLY reads `paddingVertical` / `paddingHorizontal`
    /// - `true`: ONLY reads `paddingTop` / `paddingBottom` / `paddingLeft` / `paddingRight`
    ///
    /// Previously the SDK ignored this flag and always checked per-edge props first,
    /// which caused mismatches when JSON contained both simple and advanced values
    /// (e.g., `paddingAdvanced: false, paddingVertical: 16, paddingTop: 0` → editor
    /// uses 16, SDK incorrectly used 0).
    private var isPaddingAdvanced: Bool {
        props?.paddingAdvanced == true
    }

    private func resolvePaddingTop() -> CGFloat {
        if isPaddingAdvanced {
            // Advanced mode: only read per-edge props
            if let top = props?.paddingTop {
                return CGFloat(resolveDouble(top, default: 0))
            }
            return 0
        } else {
            // Simple mode: only read axis-level props
            if let vertical = props?.paddingVertical {
                return CGFloat(resolveDouble(vertical, default: 0))
            }
            return 0
        }
    }

    private func resolvePaddingBottom() -> CGFloat {
        if isPaddingAdvanced {
            if let bottom = props?.paddingBottom {
                return CGFloat(resolveDouble(bottom, default: 0))
            }
            return 0
        } else {
            if let vertical = props?.paddingVertical {
                return CGFloat(resolveDouble(vertical, default: 0))
            }
            return 0
        }
    }

    private func resolvePaddingLeft() -> CGFloat {
        if isPaddingAdvanced {
            if let left = props?.paddingLeft {
                return CGFloat(resolveDouble(left, default: 0))
            }
            return 0
        } else {
            if let horizontal = props?.paddingHorizontal {
                return CGFloat(resolveDouble(horizontal, default: 0))
            }
            return 0
        }
    }

    private func resolvePaddingRight() -> CGFloat {
        if isPaddingAdvanced {
            if let right = props?.paddingRight {
                return CGFloat(resolveDouble(right, default: 0))
            }
            return 0
        } else {
            if let horizontal = props?.paddingHorizontal {
                return CGFloat(resolveDouble(horizontal, default: 0))
            }
            return 0
        }
    }

    // MARK: - Helpers

    private func resolveDouble(_ property: PropertyValue<Double>?, default defaultValue: Double) -> Double {
        PropertyResolver.resolve(property, store: variableStore, default: defaultValue)
    }
}

// MARK: - Overflow Clipping

extension View {
    /// Conditionally applies clipping based on the CSS `overflow` property and corner radius.
    ///
    /// - **`"visible"`** -- no clipping is applied; content may extend beyond the element bounds.
    /// - **`"hidden"`** -- always clips. Uses `clipShape` when a corner radius is present,
    ///   otherwise falls back to `.clipped()` for a rectangular clip.
    /// - **`nil`** (not set / default) -- preserves the existing SDK behaviour: clips only
    ///   when at least one corner radius value is greater than zero.
    @ViewBuilder
    func applyOverflowClipping(overflow: String?, cornerShape: AdaptiveCornerShape) -> some View {
        let hasCornerRadius = cornerShape.topLeft > 0
            || cornerShape.topRight > 0
            || cornerShape.bottomLeft > 0
            || cornerShape.bottomRight > 0

        switch overflow {
        case "visible":
            // Overflow visible: never clip, content is allowed to extend beyond bounds.
            // Still apply the corner shape to the background via cornerRadius if needed,
            // but do NOT clip child content.
            self
        case "hidden":
            // Overflow hidden: always clip content to the element bounds.
            if hasCornerRadius {
                self.clipShape(cornerShape)
            } else {
                self.clipped()
            }
        default:
            // Default behaviour (overflow not specified): clip only when corner radius > 0.
            if hasCornerRadius {
                self.clipShape(cornerShape)
            } else {
                self
            }
        }
    }
}

// MARK: - Box Shadow (Outer / Inner)

extension View {
    /// Conditionally applies either an outer shadow or an inner (inset) shadow overlay.
    ///
    /// - When `isInner` is `false` (the default), the standard SwiftUI `.shadow()` modifier
    ///   is applied, producing an external drop shadow identical to CSS `box-shadow`.
    /// - When `isInner` is `true`, the external shadow is skipped and the provided
    ///   `innerOverlay` closure is rendered as an `.overlay()`, simulating CSS
    ///   `box-shadow: inset`.
    ///
    /// This method exists so both body branches of `UniversalStyleModifier` can share the
    /// same shadow-dispatch logic without duplicating the conditional.
    ///
    /// - Parameters:
    ///   - isInner: Whether the shadow should render inside the element.
    ///   - color: The resolved shadow color (including opacity).
    ///   - radius: The resolved shadow blur radius (adjusted for spread).
    ///   - x: The horizontal shadow offset in points.
    ///   - y: The vertical shadow offset in points.
    ///   - innerOverlay: A closure that produces the inner shadow overlay view.
    @ViewBuilder
    func applyBoxShadow<InnerOverlay: View>(
        isInner: Bool,
        color: Color,
        radius: CGFloat,
        x: Double,
        y: Double,
        @ViewBuilder innerOverlay: () -> InnerOverlay
    ) -> some View {
        if isInner {
            self.overlay(innerOverlay())
        } else {
            self.shadow(
                color: color,
                radius: radius,
                x: CGFloat(x),
                y: CGFloat(y)
            )
        }
    }
}

// MARK: - Position Offset Modifier

/// Applies CSS-like relative positioning and z-index to components.
///
/// Maps the editor's `positionType` property:
/// - `"relative"`: Offsets the element from its normal flow position using `top`/`left`/`bottom`/`right`.
///   CSS `top` moves DOWN and `left` moves RIGHT, which matches SwiftUI's `.offset()`.
///   When both `top` and `bottom` are set, `top` wins (CSS spec). Same for `left` over `right`.
/// - `"absolute"`: Handled by `StackView` which removes absolute children from the normal
///   flex flow and renders them as overlays positioned relative to the parent's bounds.
///   This modifier only applies zIndex for absolute children (offset is 0).
/// - `zIndex`: Applied regardless of position type, matching the editor behavior.
struct PositionOffsetModifier: ViewModifier {
    let props: ComponentProps?
    let variableStore: VariableStore

    func body(content: Content) -> some View {
        content
            .offset(x: resolvedXOffset, y: resolvedYOffset)
            .zIndex(resolvedZIndex)
    }

    /// X offset for relative positioning. Returns 0 for non-relative elements.
    /// CSS precedence: `left` wins over `right`.
    private var resolvedXOffset: CGFloat {
        guard isRelative else { return 0 }
        if let left = resolveOptionalDouble(props?.left) {
            return CGFloat(left)
        }
        if let right = resolveOptionalDouble(props?.right) {
            return CGFloat(-right)
        }
        return 0
    }

    /// Y offset for relative positioning. Returns 0 for non-relative elements.
    /// CSS precedence: `top` wins over `bottom`.
    private var resolvedYOffset: CGFloat {
        guard isRelative else { return 0 }
        if let top = resolveOptionalDouble(props?.top) {
            return CGFloat(top)
        }
        if let bottom = resolveOptionalDouble(props?.bottom) {
            return CGFloat(-bottom)
        }
        return 0
    }

    /// Resolved z-index. Applied regardless of position type (matches editor behavior).
    private var resolvedZIndex: Double {
        PropertyResolver.resolve(props?.zIndex, store: variableStore, default: 0.0)
    }

    /// Whether the element has `positionType: "relative"`.
    private var isRelative: Bool {
        PropertyResolver.resolve(props?.positionType, store: variableStore, default: "normal") == "relative"
    }

    /// Resolves an optional Double property, returning nil when the property is not set.
    private func resolveOptionalDouble(_ property: PropertyValue<Double>?) -> Double? {
        guard let prop = property else { return nil }
        return PropertyResolver.resolve(prop, store: variableStore, default: 0.0)
    }
}

// MARK: - Interaction Modifier

/// Handles component interactions
struct InteractionModifier: ViewModifier {
    let node: ComponentNode
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    var isDisabled: Bool = false

    /// Guards onAppear actions to a single firing. SwiftUI may call `.onAppear`
    /// more than once for the same view identity (e.g. when re-inserted into a
    /// stack); without this an `onAppear` chain would re-run and, for a stepped
    /// ring, restart the sequence mid-flight.
    @State private var firedOnAppear = false

    func body(content: Content) -> some View {
        // onAppear is a lifecycle event, not a user interaction, so it fires
        // regardless of `isDisabled` (which only gates tap handling). onPress
        // is skipped when disabled. Both surfaces share the same scheduler, so
        // a delayed onAppear chain (the stepped-ring authoring pattern) walks
        // its bound variable over time.
        if !isDisabled, let onPress = findInteraction(event: .onPress) {
            content
                .simultaneousGesture(
                    TapGesture().onEnded {
                        executeActions(onPress.actions, interactionType: "tap")
                    }
                )
                .onAppear { fireOnAppear() }
                .onDisappear { handleDisappear() }
        } else {
            content
                .onAppear { fireOnAppear() }
                .onDisappear { handleDisappear() }
        }
    }

    private func findInteraction(event: ComponentEventType) -> ComponentInteraction? {
        node.interactions?.first { $0.event == event }
    }

    /// Fire every onAppear interaction's action chain once, when the component
    /// first appears. `interactionType` is nil because appearance isn't a
    /// classifiable analytics interaction (matches Expo's `useOnAppear`).
    private func fireOnAppear() {
        guard !firedOnAppear else { return }
        let onAppearInteractions = node.interactions?.filter { $0.event == .onAppear } ?? []
        guard !onAppearInteractions.isEmpty else { return }
        firedOnAppear = true
        for interaction in onAppearInteractions {
            executeActions(interaction.actions, interactionType: nil)
        }
    }

    /// On disappear, cancel any delayed onAppear hops this element scheduled and
    /// arm it to replay on the next appearance. Together these stop a stepped
    /// sequence from overlapping itself when the user navigates away and back
    /// (each visit would otherwise add another concurrent run, jittering the
    /// bound value). Cancelling by `node.id` leaves other elements' schedules
    /// untouched.
    private func handleDisappear() {
        firedOnAppear = false
        guard node.interactions?.contains(where: { $0.event == .onAppear }) == true else { return }
        actionExecutor.cancelScheduledActions(for: node.id)
    }

    private func executeActions(_ actions: [ScheduledAction], interactionType: String?) {
        Task {
            await actionExecutor.execute(
                actions: actions,
                context: actionContext,
                elementId: node.id,
                elementType: node.type.rawValue,
                interactionType: interactionType
            )
        }
    }
}

// MARK: - Color Extension

extension Color {
    /// Creates a `Color` from a CSS color string.
    ///
    /// Supported formats:
    /// - Hex: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`
    /// - CSS `rgb()` / `rgba()` with comma syntax: `rgb(255, 0, 0)`, `rgba(255, 0, 0, 0.5)`
    /// - CSS `rgb()` / `rgba()` with modern space + slash syntax: `rgb(255 0 0)`, `rgb(255 0 0 / 0.5)`
    ///
    /// Returns `nil` if the string cannot be parsed as any recognised format.
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)

        // Theme token reference that escaped PropertyResolver (paths that
        // bypass prop resolution, e.g. raw model fields): resolve against the
        // fallback palette rather than failing to parse. Unknown tokens
        // resolve to themselves — bail to nil instead of recursing.
        if ThemeTokens.isRef(trimmed) {
            let resolved = ThemeTokens.resolve(trimmed, colors: nil)
            if resolved != trimmed, let color = Color(hex: resolved) {
                self = color
                return
            }
            return nil
        }

        // Check for rgb/rgba functional notation before hex parsing
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("rgba(") || lowered.hasPrefix("rgb(") {
            if let color = Color(cssRGB: trimmed) {
                self = color
            } else {
                return nil
            }
            return
        }

        // Hex parsing
        var hexSanitized = trimmed.replacingOccurrences(of: "#", with: "")

        // Expand 3-char (#RGB) shorthand to 6-char (#RRGGBB)
        if hexSanitized.count == 3 {
            let r = String(hexSanitized[hexSanitized.startIndex])
            let g = String(hexSanitized[hexSanitized.index(hexSanitized.startIndex, offsetBy: 1)])
            let b = String(hexSanitized[hexSanitized.index(hexSanitized.startIndex, offsetBy: 2)])
            hexSanitized = r + r + g + g + b + b
        }

        // Expand 4-char (#RGBA) shorthand to 8-char (#RRGGBBAA)
        if hexSanitized.count == 4 {
            let r = String(hexSanitized[hexSanitized.startIndex])
            let g = String(hexSanitized[hexSanitized.index(hexSanitized.startIndex, offsetBy: 1)])
            let b = String(hexSanitized[hexSanitized.index(hexSanitized.startIndex, offsetBy: 2)])
            let a = String(hexSanitized[hexSanitized.index(hexSanitized.startIndex, offsetBy: 3)])
            hexSanitized = r + r + g + g + b + b + a + a
        }

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let length = hexSanitized.count

        switch length {
        case 6:
            self.init(
                red: Double((rgb & 0xFF0000) >> 16) / 255,
                green: Double((rgb & 0x00FF00) >> 8) / 255,
                blue: Double(rgb & 0x0000FF) / 255
            )
        case 8:
            self.init(
                red: Double((rgb & 0xFF000000) >> 24) / 255,
                green: Double((rgb & 0x00FF0000) >> 16) / 255,
                blue: Double((rgb & 0x0000FF00) >> 8) / 255,
                opacity: Double(rgb & 0x000000FF) / 255
            )
        default:
            return nil
        }
    }

    // MARK: - CSS rgb() / rgba() Parsing

    /// Creates a `Color` from a CSS `rgb()` or `rgba()` function string.
    ///
    /// Handles two syntaxes defined by CSS Color Level 4:
    ///
    /// **Legacy comma syntax:**
    /// - `rgb(255, 0, 0)` -- opaque red
    /// - `rgba(255, 0, 0, 0.5)` -- 50 % transparent red
    ///
    /// **Modern space + slash syntax:**
    /// - `rgb(255 0 0)` -- opaque red
    /// - `rgb(255 0 0 / 0.5)` -- 50 % transparent red
    /// - `rgba(255 0 0 / 50%)` -- 50 % transparent red (percentage alpha)
    ///
    /// Red, green, and blue values are expected in the 0-255 range.
    /// Alpha is expected as a decimal in 0-1 or a percentage (e.g., `50%`).
    ///
    /// Returns `nil` if the string cannot be parsed.
    private init?(cssRGB colorStr: String) {
        // Strip the function name and closing parenthesis
        var inner = colorStr.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Remove "rgba(" or "rgb(" prefix
        if inner.hasPrefix("rgba(") {
            inner = String(inner.dropFirst(5))
        } else if inner.hasPrefix("rgb(") {
            inner = String(inner.dropFirst(4))
        } else {
            return nil
        }

        // Remove trailing ")"
        if inner.hasSuffix(")") {
            inner = String(inner.dropLast(1))
        } else {
            return nil
        }

        inner = inner.trimmingCharacters(in: .whitespaces)

        let r: Double
        let g: Double
        let b: Double
        var alpha: Double = 1.0

        if inner.contains(",") {
            // Legacy comma-separated syntax: rgb(R, G, B) or rgba(R, G, B, A)
            let components = inner.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            guard components.count >= 3,
                  let rVal = Double(components[0]),
                  let gVal = Double(components[1]),
                  let bVal = Double(components[2]) else {
                return nil
            }

            r = rVal
            g = gVal
            b = bVal

            if components.count >= 4 {
                alpha = Color.parseAlphaComponent(components[3])
            }
        } else {
            // Modern space-separated syntax: rgb(R G B) or rgb(R G B / A)
            // Split on "/" first to separate color channels from alpha
            let slashParts = inner.split(separator: "/", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            // Parse the R G B portion (space-separated)
            let channelTokens = slashParts[0]
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0) }

            guard channelTokens.count == 3,
                  let rVal = Double(channelTokens[0]),
                  let gVal = Double(channelTokens[1]),
                  let bVal = Double(channelTokens[2]) else {
                return nil
            }

            r = rVal
            g = gVal
            b = bVal

            // Parse optional alpha after the slash
            if slashParts.count >= 2 {
                alpha = Color.parseAlphaComponent(slashParts[1])
            }
        }

        self.init(
            red: r / 255.0,
            green: g / 255.0,
            blue: b / 255.0,
            opacity: alpha
        )
    }

    /// Parses an alpha component string that may be a decimal (0-1) or a percentage (e.g., `50%`).
    ///
    /// - Returns: A `Double` in the 0-1 range. Defaults to `1.0` if parsing fails.
    private static func parseAlphaComponent(_ value: String) -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") {
            // Percentage alpha: "50%" -> 0.5
            let numStr = String(trimmed.dropLast(1))
            guard let percent = Double(numStr) else { return 1.0 }
            return percent / 100.0
        } else {
            return Double(trimmed) ?? 1.0
        }
    }
}
