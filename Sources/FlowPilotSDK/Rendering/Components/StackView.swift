import SwiftUI

// MARK: - Flow Layout (Flex-Wrap)

/// A custom layout that arranges subviews in a horizontal flow, wrapping to the
/// next line when the available width is exceeded. This replicates CSS
/// `flex-wrap: wrap` behavior for horizontal stacks.
///
/// Requires iOS 16+ / macOS 13+ because it relies on the `Layout` protocol.
@available(iOS 16.0, macOS 13.0, *)
struct FlowLayout: Layout {
    /// Horizontal spacing between items on the same row.
    var spacing: CGFloat
    /// Vertical alignment of items within each row.
    var alignment: VerticalAlignment

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentY += lineHeight + spacing
                currentX = 0
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return CGSize(width: totalWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentY += lineHeight + spacing
                currentX = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Justified Horizontal Layout

/// A custom layout that arranges subviews horizontally with CSS flexbox-like
/// justify-content behavior: start, center, or end.
///
/// Unlike `HStack`, this layout measures each child using a **width-constrained
/// proposal** to get wrapping-aware sizes, then positions them based on their
/// *actual returned widths* rather than distributing the full available width
/// among flexible children. This prevents greedy children (e.g., UILabel-backed
/// text views) from expanding to fill all proposed space, which is critical for
/// justify "right" and "center" to work correctly with Spacer-free positioning.
///
/// Requires iOS 16+ / macOS 13+ because it relies on the `Layout` protocol.
@available(iOS 16.0, macOS 13.0, *)
struct JustifiedHStack: Layout {
    /// Horizontal spacing between items.
    var spacing: CGFloat
    /// Vertical alignment of items within the row.
    var alignment: VerticalAlignment
    /// How to position items along the main (horizontal) axis.
    var justify: HJustify

    enum HJustify {
        case start, center, end
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = childSizes(subviews: subviews, proposalWidth: proposal.width, caller: "sizeThatFits")
        let totalChildWidth = sizes.reduce(0) { $0 + $1.width }
        let totalSpacing = max(0, CGFloat(sizes.count - 1)) * spacing
        let contentWidth = totalChildWidth + totalSpacing
        let maxHeight = sizes.reduce(0) { max($0, $1.height) }

        // Report the full proposed width (or content width if unconstrained) so
        // the layout fills its parent — matching how a CSS flex container is a
        // block-level element that takes 100% width.
        let width = proposal.width ?? contentWidth
        let result = CGSize(width: width, height: maxHeight)
        Logger.shared.debug("[JustifiedHStack] sizeThatFits: proposal=\(proposal.width.map{String(describing:$0)} ?? "nil")x\(proposal.height.map{String(describing:$0)} ?? "nil") justify=\(justify) childCount=\(subviews.count) childSizes=\(sizes.map{"(\($0.width),\($0.height))"}) contentWidth=\(contentWidth) result=\(result.width)x\(result.height)")
        return result
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = childSizes(subviews: subviews, proposalWidth: bounds.width, caller: "placeSubviews")
        let totalChildWidth = sizes.reduce(0) { $0 + $1.width }
        let totalSpacing = max(0, CGFloat(sizes.count - 1)) * spacing
        let contentWidth = totalChildWidth + totalSpacing

        Logger.shared.debug("[JustifiedHStack] placeSubviews: bounds=\(bounds) justify=\(justify) childSizes=\(sizes.map{"(\($0.width),\($0.height))"}) totalChildWidth=\(totalChildWidth) totalSpacing=\(totalSpacing) contentWidth=\(contentWidth) boundsWidth=\(bounds.width)")

        // Compute the starting X based on justify mode.
        let startX: CGFloat
        switch justify {
        case .start:
            startX = bounds.minX
        case .center:
            startX = bounds.minX + (bounds.width - contentWidth) / 2
        case .end:
            startX = bounds.maxX - contentWidth
        }

        Logger.shared.debug("[JustifiedHStack] placeSubviews: startX=\(startX) (boundsMinX=\(bounds.minX) boundsMaxX=\(bounds.maxX) contentWidth=\(contentWidth))")

        var currentX = startX
        for (index, subview) in subviews.enumerated() {
            let childSize = sizes[index]
            // Compute vertical position based on alignment.
            let y: CGFloat
            switch alignment {
            case .top:
                y = bounds.minY
            case .bottom:
                y = bounds.maxY - childSize.height
            case .center:
                y = bounds.minY + (bounds.height - childSize.height) / 2
            default:
                // .firstTextBaseline, etc. — fall back to top
                y = bounds.minY
            }
            Logger.shared.debug("[JustifiedHStack] place child[\(index)]: at=(\(currentX),\(y)) proposedSize=\(childSize.width)x\(childSize.height)")
            subview.place(
                at: CGPoint(x: currentX, y: y),
                proposal: ProposedViewSize(width: childSize.width, height: childSize.height)
            )
            currentX += childSize.width + spacing
        }
    }

    /// Measures each child to determine its layout size, distinguishing between
    /// content-hugging children (text, icons) and flexible children (progress bars,
    /// spacers) that should expand to fill available space.
    ///
    /// **Two-pass measurement**:
    ///
    /// 1. **Ideal pass**: Propose `nil` width (`.unspecified`) to get each child's
    ///    ideal/content-fitting size. Content-hugging views (text, icons) return
    ///    their natural width; flexible views (GeometryReader-based progress bars)
    ///    return a small default (~10pt).
    ///
    /// 2. **Constrained pass**: Propose the *remaining* available width to get the
    ///    correctly-wrapped height and to detect flexible children.
    ///
    /// **Flexible vs content-hugging heuristic**: If a child's constrained width is
    /// significantly larger than its ideal width, it is flexible (e.g., GeometryReader
    /// has ideal ~10pt but accepts the full proposed width). Flexible children use
    /// the constrained width; content-hugging children use their ideal width (capped
    /// at remaining space).
    private func childSizes(subviews: Subviews, proposalWidth: CGFloat?, caller: String) -> [CGSize] {
        let availableWidth = proposalWidth ?? .greatestFiniteMagnitude
        var sizes: [CGSize] = []
        var usedWidth: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let spacingBefore = index > 0 ? spacing : 0
            let remainingWidth = max(0, availableWidth - usedWidth - spacingBefore)

            // Pass 1: ideal size (nil width proposal → content-hugging width)
            let idealSize = subview.sizeThatFits(.unspecified)

            // Pass 2: constrained size (for correct wrapping height and flexible detection)
            let constrainedSize = subview.sizeThatFits(ProposedViewSize(width: remainingWidth, height: nil))

            // Determine if the child is flexible (wants to expand to fill space).
            // A flexible child's constrained width is much larger than its ideal width
            // (e.g., GeometryReader: ideal ~10pt, constrained ~300pt).
            // A content-hugging child returns similar widths for both passes
            // (e.g., text "Yes": ideal ~30pt, constrained ~30pt).
            let isFlexible = constrainedSize.width > idealSize.width * 1.5 && idealSize.width < remainingWidth * 0.5

            let resultWidth: CGFloat
            let resultHeight: CGFloat
            if isFlexible {
                // Flexible child: let it expand to fill available space
                resultWidth = constrainedSize.width
                resultHeight = constrainedSize.height
            } else {
                // Content-hugging child: use ideal width, capped at remaining space
                resultWidth = min(idealSize.width, remainingWidth)
                resultHeight = resultWidth < idealSize.width ? constrainedSize.height : idealSize.height
            }
            let size = CGSize(width: resultWidth, height: resultHeight)

            Logger.shared.debug("[JustifiedHStack] childSizes[\(caller)] child[\(index)]: idealW=\(idealSize.width) constrainedW=\(constrainedSize.width) remainingW=\(remainingWidth) isFlexible=\(isFlexible) resultW=\(resultWidth) resultH=\(resultHeight)")
            sizes.append(size)
            usedWidth += spacingBefore + size.width
        }
        return sizes
    }
}

// MARK: - Stack View

/// Renders a stack component (vertical, horizontal, or layered)
@MainActor
struct StackView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let mediaBaseUrl: String?
    let iconBaseUrl: String?
    var renderTrigger: Int = 0

    /// The measured size of the parent container, used to resolve percentage-based
    /// width/height on the stack's own inner frame constraint.
    @Environment(\.parentSize) private var parentSize

    /// Tracks whether stagger haptics have been scheduled for this stack instance.
    /// Prevents duplicate scheduling across SwiftUI re-renders.
    @State private var hasScheduledStaggerHaptics = false

    var body: some View {
        let axis = PropertyResolver.resolve(node.props?.axis, store: variableStore, default: "vertical")
        let spacing = PropertyResolver.resolve(node.props?.spacing, store: variableStore, default: 0.0)
        let wrapValue = PropertyResolver.resolve(node.props?.wrap, store: variableStore, default: "nowrap")

        // Partition children: normal-flow vs absolutely-positioned.
        // Absolute children are removed from the flex flow and rendered as overlays,
        // matching CSS `position: absolute` behavior in the web editor.
        let allChildren = node.children ?? []
        let absoluteChildren = allChildren.filter { isAbsolutelyPositioned($0) }
        let hasAbsoluteChildren = !absoluteChildren.isEmpty

        // Each stack variant is wrapped with `.injectParentSize()` so that
        // children with percentage-based dimensions (e.g., `width: "50%"`)
        // can resolve against the stack's actual rendered size.
        //
        // When absolute children exist, the normal-flow stack is wrapped in an
        // overlay that renders absolute children positioned relative to the
        // stack's bounds — replicating CSS absolute positioning.
        Group {
            switch axis {
            case "horizontal":
                if wrapValue == "wrap" {
                    wrapInScrollIfNeeded {
                        renderWrappedHorizontalStack(spacing: CGFloat(spacing))
                    }
                    .overlayAbsoluteChildren(absoluteChildren, enabled: hasAbsoluteChildren, stackView: self)
                    .injectParentSize()
                } else {
                    wrapInScrollIfNeeded {
                        renderHorizontalStack(spacing: CGFloat(spacing))
                    }
                    .overlayAbsoluteChildren(absoluteChildren, enabled: hasAbsoluteChildren, stackView: self)
                    .injectParentSize()
                    // CSS flex-shrink for direct children: injected here (below this
                    // stack's own UniversalStyleModifier, which reset the inherited
                    // factor to 1.0) so it reaches the row's children but not deeper.
                    .environment(\.horizontalShrinkScale, horizontalShrinkScale(spacing: CGFloat(spacing)))
                }

            case "layered":
                wrapInScrollIfNeeded {
                    ZStack(alignment: layeredAlignment) {
                        renderChildren(stretchAxis: nil)
                    }
                    .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight())
                }
                .overlayAbsoluteChildren(absoluteChildren, enabled: hasAbsoluteChildren, stackView: self)
                .injectParentSize()

            default: // vertical
                wrapInScrollIfNeeded {
                    renderVerticalStack(spacing: CGFloat(spacing))
                }
                .overlayAbsoluteChildren(absoluteChildren, enabled: hasAbsoluteChildren, stackView: self)
                .injectParentSize()
            }
        }
        .onAppear {
            scheduleStaggerHapticsOnce()
        }
    }

    // MARK: - Scroll Behavior

    /// Wraps content in a scrollable container when the stack has `scrollBehavior: "scroll"`.
    /// Matches the editor behavior (stack-renderer.tsx:91-100): "scroll" scrolls along
    /// the stack's axis direction — vertical stacks scroll vertically, horizontal scroll horizontally.
    ///
    /// Vertical: uses UIKit UIScrollView to avoid nested same-direction gesture conflicts
    /// with the root screen ScrollView in FlowPresenter.
    /// Horizontal: uses SwiftUI ScrollView (no conflict since root scrolls vertically).
    @ViewBuilder
    private func wrapInScrollIfNeeded<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let scroll = PropertyResolver.resolve(node.props?.scrollBehavior, store: variableStore, default: "no-scroll")
        let axis = PropertyResolver.resolve(node.props?.axis, store: variableStore, default: "vertical")

        if scroll == "scroll" {
            if axis == "horizontal" {
                // Horizontal scroll — no conflict with root vertical ScrollView
                ScrollView(.horizontal, showsIndicators: true) {
                    content()
                }
            } else {
                // Vertical scroll — use UIKit to avoid gesture conflict with root ScrollView
                #if canImport(UIKit)
                UIKitScrollView(axes: .vertical) {
                    content()
                }
                #else
                ScrollView(.vertical, showsIndicators: true) {
                    content()
                }
                #endif
            }
        } else {
            content()
        }
    }

    // MARK: - Stack Rendering

    @ViewBuilder
    private func renderHorizontalStack(spacing: CGFloat) -> some View {
        let justifyMode = resolveJustifyMode()
        let crossMode = resolveCrossAxisMode(for: "horizontal")
        let vAlign = crossMode.verticalAlignment
        let resolvedMaxW = resolveMaxWidth()
        let resolvedMaxH = resolveMaxHeight()

        let _ = Logger.shared.debug("[HStack] node=\(node.id) justify=\(justifyMode) crossMode=\(crossMode) maxW=\(resolvedMaxW.map { String(describing: $0) } ?? "nil") maxH=\(resolvedMaxH.map { String(describing: $0) } ?? "nil") width=\(descDimension(node.props?.width)) height=\(descDimension(node.props?.height)) fill=\(PropertyResolver.resolve(node.props?.fill, store: variableStore) ?? "nil") childCount=\(flowChildren.count)")

        // Resolve the per-child cross-axis alignment descriptor.
        // - Stretch: children expand vertically via maxHeight: .infinity.
        // - Non-stretch: children fill height via maxHeight: .infinity but position
        //   their content at the correct vertical edge (.top, .center, .bottom).
        //   This includes .top because relying solely on the HStack's alignment
        //   parameter is insufficient: child stacks expand to full height via
        //   their own resolveMaxHeight(), making the HStack alignment invisible.
        //   The explicit frame(alignment:) ensures content inside those children
        //   is positioned at the correct edge -- matching CSS align-items behavior.
        let childAlignment: CrossAxisChildAlignment = {
            if shouldApplyStretch(for: "horizontal", crossMode: crossMode) {
                return .stretch(parentAxis: "horizontal")
            }
            if case .align(let v, _) = crossMode {
                return .vertical(v)
            }
            return .none
        }()

        switch justifyMode {
        case .start:
            if #available(iOS 16.0, macOS 13.0, *) {
                // JustifiedHStack reports the *proposed* width (capped) rather than
                // its content width, so an over-wide row of rigid children does NOT
                // inflate its ancestors (a plain HStack reports content width, which
                // `.frame(maxWidth:.infinity)` cannot shrink below — the overflow
                // then drags every full-width sibling off the content box). With the
                // container width no longer inflated, `horizontalShrinkScale` can
                // resolve the true width and shrink the children to fit (flex-shrink).
                JustifiedHStack(spacing: spacing, alignment: vAlign, justify: .start) {
                    renderChildren(crossAxisAlignment: childAlignment)
                }
                .frame(maxWidth: resolvedMaxW, maxHeight: resolvedMaxH, alignment: Alignment(horizontal: .leading, vertical: vAlign))
            } else {
                HStack(alignment: vAlign, spacing: spacing) {
                    renderChildren(crossAxisAlignment: childAlignment)
                }
                .frame(maxWidth: resolvedMaxW, maxHeight: resolvedMaxH, alignment: Alignment(horizontal: .leading, vertical: vAlign))
            }

        case .center:
            if #available(iOS 16.0, macOS 13.0, *) {
                JustifiedHStack(spacing: spacing, alignment: vAlign, justify: .center) {
                    renderChildren(crossAxisAlignment: childAlignment)
                }
                .border(FlowPilot.debugBordersEnabled ? Color.green : Color.clear, width: FlowPilot.debugBordersEnabled ? 2 : 0) // DEBUG: JustifiedHStack bounds
                .frame(maxWidth: resolvedMaxW, maxHeight: resolvedMaxH, alignment: Alignment(horizontal: .center, vertical: vAlign))
                .border(FlowPilot.debugBordersEnabled ? Color.red : Color.clear, width: FlowPilot.debugBordersEnabled ? 1 : 0) // DEBUG: outer frame bounds
            } else {
                // iOS 15 fallback: Spacer-based centering (may not work with greedy text)
                HStack(alignment: vAlign, spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(alignment: vAlign, spacing: spacing) {
                        renderChildren(crossAxisAlignment: childAlignment)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: resolvedMaxW, maxHeight: resolvedMaxH, alignment: Alignment(horizontal: .center, vertical: vAlign))
            }

        case .end:
            if #available(iOS 16.0, macOS 13.0, *) {
                JustifiedHStack(spacing: spacing, alignment: vAlign, justify: .end) {
                    renderChildren(crossAxisAlignment: childAlignment)
                }
                .border(FlowPilot.debugBordersEnabled ? Color.green : Color.clear, width: FlowPilot.debugBordersEnabled ? 2 : 0) // DEBUG: JustifiedHStack bounds
                .frame(maxWidth: resolvedMaxW, maxHeight: resolvedMaxH, alignment: Alignment(horizontal: .trailing, vertical: vAlign))
                .border(FlowPilot.debugBordersEnabled ? Color.red : Color.clear, width: FlowPilot.debugBordersEnabled ? 1 : 0) // DEBUG: outer frame bounds
            } else {
                // iOS 15 fallback: Spacer-based alignment (may not work with greedy text)
                HStack(alignment: vAlign, spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(alignment: vAlign, spacing: spacing) {
                        renderChildren(crossAxisAlignment: childAlignment)
                    }
                    .layoutPriority(1)
                }
                .frame(maxWidth: resolvedMaxW, maxHeight: resolvedMaxH, alignment: Alignment(horizontal: .trailing, vertical: vAlign))
            }

        case .spaceBetween:
            HStack(alignment: vAlign, spacing: 0) {
                renderHChildrenWithSpacers(mode: .between, crossAxisAlignment: childAlignment)
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: Alignment(horizontal: .leading, vertical: vAlign))

        case .spaceAround:
            HStack(alignment: vAlign, spacing: 0) {
                renderHChildrenWithSpacers(mode: .around, crossAxisAlignment: childAlignment)
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: Alignment(horizontal: .leading, vertical: vAlign))

        case .spaceEvenly:
            HStack(alignment: vAlign, spacing: 0) {
                renderHChildrenWithSpacers(mode: .evenly, crossAxisAlignment: childAlignment)
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: Alignment(horizontal: .leading, vertical: vAlign))
        }
    }

    /// Renders a horizontal stack with flex-wrap support.
    ///
    /// On iOS 16+ this uses `FlowLayout`, a custom `Layout` that wraps children
    /// to the next line when they exceed the available width -- replicating CSS
    /// `flex-wrap: wrap`.  On iOS 15 the `Layout` protocol is unavailable, so
    /// the method falls back to a regular `HStack` (children will overflow,
    /// which matches the existing pre-wrap behavior).
    @ViewBuilder
    private func renderWrappedHorizontalStack(spacing: CGFloat) -> some View {
        let crossMode = resolveCrossAxisMode(for: "horizontal")
        let vAlign = crossMode.verticalAlignment

        if #available(iOS 16.0, macOS 13.0, *) {
            FlowLayout(spacing: spacing, alignment: vAlign) {
                renderChildren(stretchAxis: nil)
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: .topLeading)
        } else {
            // iOS 15 fallback: no Layout protocol available, use regular HStack.
            // Children will overflow rather than wrap, matching pre-existing behavior.
            HStack(alignment: vAlign, spacing: spacing) {
                renderChildren(stretchAxis: nil)
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: Alignment(horizontal: .leading, vertical: vAlign))
        }
    }

    /// Renders normal-flow children with spacers for HStack space-between/around/evenly.
    /// Absolutely-positioned children are excluded.
    @ViewBuilder
    private func renderHChildrenWithSpacers(mode: SpacerMode, crossAxisAlignment: CrossAxisChildAlignment) -> some View {
        let children = flowChildren
        if !children.isEmpty {
            let stagger = resolveStaggerConfig(totalChildren: children.count)

            switch mode {
            case .between:
                ForEach(children.indices, id: \.self) { index in
                    let context = stagger.contextForChild(at: index, childId: children[index].id)
                    renderChildView(node: children[index], crossAxisAlignment: crossAxisAlignment)
                        .environment(\.staggerContext, context)
                    if index < children.count - 1 {
                        Spacer(minLength: 0)
                    }
                }

            case .around:
                Spacer(minLength: 0).frame(maxWidth: .infinity)
                ForEach(children.indices, id: \.self) { index in
                    let context = stagger.contextForChild(at: index, childId: children[index].id)
                    renderChildView(node: children[index], crossAxisAlignment: crossAxisAlignment)
                        .environment(\.staggerContext, context)
                    Spacer(minLength: 0).frame(maxWidth: .infinity)
                    if index < children.count - 1 {
                        Spacer(minLength: 0).frame(maxWidth: .infinity)
                    }
                }

            case .evenly:
                Spacer(minLength: 0)
                ForEach(children.indices, id: \.self) { index in
                    let context = stagger.contextForChild(at: index, childId: children[index].id)
                    renderChildView(node: children[index], crossAxisAlignment: crossAxisAlignment)
                        .environment(\.staggerContext, context)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Legacy overload for callers using the old stretchAxis parameter.
    @ViewBuilder
    private func renderHChildrenWithSpacers(mode: SpacerMode, stretchAxis: String?) -> some View {
        renderHChildrenWithSpacers(mode: mode, crossAxisAlignment: crossAxisChildAlignment(from: stretchAxis))
    }

    @ViewBuilder
    private func renderVerticalStack(spacing: CGFloat) -> some View {
        let justifyMode = resolveJustifyMode()
        let crossMode = resolveCrossAxisMode(for: "vertical")
        let hAlign = crossMode.horizontalAlignment

        let _ = Logger.shared.debug("[VStack] node=\(node.id) justify=\(justifyMode) crossMode=\(crossMode) maxW=\(resolveMaxWidth().map { String(describing: $0) } ?? "nil") maxH=\(resolveMaxHeight().map { String(describing: $0) } ?? "nil") width=\(descDimension(node.props?.width)) height=\(descDimension(node.props?.height)) align=\(PropertyResolver.resolve(node.props?.align, store: variableStore) ?? "nil") childCount=\(flowChildren.count)")

        // Resolve the per-child cross-axis alignment descriptor.
        // - Stretch: children expand horizontally via maxWidth: .infinity.
        // - Non-stretch: children fill width via maxWidth: .infinity but position
        //   their content at the correct horizontal edge (.leading, .center,
        //   .trailing). This includes .leading because relying solely on the
        //   VStack's alignment parameter is insufficient: child stacks expand
        //   to full width via their own resolveMaxWidth() -> .infinity, making
        //   the VStack alignment invisible. The explicit frame(alignment:)
        //   ensures content inside those full-width children is positioned at
        //   the correct edge -- matching CSS align-items: flex-start behavior
        //   where child content is left-aligned within the cross-axis.
        let childAlignment: CrossAxisChildAlignment = {
            if shouldApplyStretch(for: "vertical", crossMode: crossMode) {
                return .stretch(parentAxis: "vertical")
            }
            if case .align(_, let h) = crossMode {
                return .horizontal(h)
            }
            return .none
        }()

        // In CSS flexbox, justify-content only distributes space when the
        // container has an explicit main-axis dimension larger than its content.
        // With height: auto (or unset), the container hugs its content, so
        // center/end/space-* are equivalent to start. In SwiftUI, the Spacer-based
        // layouts used for these modes make the stack greedy (it absorbs all
        // proposed height). To match CSS, fall back to .start when there is no
        // explicit height.
        let hasExplicitHeight = resolveMaxHeight() != nil
        let effectiveJustify = hasExplicitHeight ? justifyMode : .start

        switch effectiveJustify {
        case .start:
            VStack(alignment: hAlign, spacing: spacing) {
                renderChildren(crossAxisAlignment: childAlignment)
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: Alignment(horizontal: hAlign, vertical: .top))

        case .center:
            // Use spacing: 0 on the outer VStack to prevent SwiftUI from adding
            // the gap value between Spacers and content. The actual gap is applied
            // only between real children via a nested VStack.
            VStack(alignment: hAlign, spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: hAlign, spacing: spacing) {
                    renderChildren(crossAxisAlignment: childAlignment)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: Alignment(horizontal: hAlign, vertical: .center))

        case .end:
            // Use spacing: 0 on the outer VStack to prevent SwiftUI from adding
            // the gap value between the Spacer and content. The actual gap is applied
            // only between real children via a nested VStack.
            VStack(alignment: hAlign, spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: hAlign, spacing: spacing) {
                    renderChildren(crossAxisAlignment: childAlignment)
                }
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: Alignment(horizontal: hAlign, vertical: .bottom))

        case .spaceBetween:
            VStack(alignment: hAlign, spacing: 0) {
                renderChildrenWithSpacers(mode: .between, crossAxisAlignment: childAlignment)
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: Alignment(horizontal: hAlign, vertical: .top))

        case .spaceAround:
            VStack(alignment: hAlign, spacing: 0) {
                renderChildrenWithSpacers(mode: .around, crossAxisAlignment: childAlignment)
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: Alignment(horizontal: hAlign, vertical: .top))

        case .spaceEvenly:
            VStack(alignment: hAlign, spacing: 0) {
                renderChildrenWithSpacers(mode: .evenly, crossAxisAlignment: childAlignment)
            }
            .frame(maxWidth: resolveMaxWidth(), maxHeight: resolveMaxHeight(), alignment: Alignment(horizontal: hAlign, vertical: .top))
        }
    }

    /// Justify content modes
    private enum JustifyMode {
        case start, center, end
        case spaceBetween, spaceAround, spaceEvenly
    }

    /// Resolves justify mode from props
    /// Priority: justify (editor primary) → justifyContent (CSS fallback)
    private func resolveJustifyMode() -> JustifyMode {
        let rawJustify = PropertyResolver.resolve(node.props?.justify, store: variableStore)
        let rawJustifyContent = PropertyResolver.resolve(node.props?.justifyContent, store: variableStore)
        let justifyValue = rawJustify ?? rawJustifyContent

        guard let justify = justifyValue else {
            Logger.shared.debug("[Justify] node=\(node.id) type=\(node.type.rawValue) → no justify prop, defaulting to .start (rawJustify=nil, rawJustifyContent=nil)")
            return .start
        }

        let mode: JustifyMode
        switch justify {
        case "flex-start", "start", "top", "left":
            mode = .start
        case "flex-end", "end", "bottom", "right":
            mode = .end
        case "center":
            mode = .center
        case "space-between":
            mode = .spaceBetween
        case "space-around":
            mode = .spaceAround
        case "space-evenly", "fill-equally":
            mode = .spaceEvenly
        default:
            mode = .start
        }

        Logger.shared.debug("[Justify] node=\(node.id) type=\(node.type.rawValue) → justify='\(justify)' → mode=\(mode) (rawJustify=\(rawJustify ?? "nil"), rawJustifyContent=\(rawJustifyContent ?? "nil"))")
        return mode
    }

    /// Spacer distribution mode
    private enum SpacerMode {
        case between  // Spacers between items only
        case around   // Half spacer at edges, full spacer between
        case evenly   // Equal spacers everywhere
    }

    /// Renders normal-flow children with spacers for space-between/around/evenly (VStack variant).
    /// Absolutely-positioned children are excluded.
    @ViewBuilder
    private func renderChildrenWithSpacers(mode: SpacerMode, crossAxisAlignment: CrossAxisChildAlignment) -> some View {
        let children = flowChildren
        if !children.isEmpty {
            let stagger = resolveStaggerConfig(totalChildren: children.count)

            switch mode {
            case .between:
                ForEach(children.indices, id: \.self) { index in
                    let context = stagger.contextForChild(at: index, childId: children[index].id)
                    renderChildView(node: children[index], crossAxisAlignment: crossAxisAlignment)
                        .environment(\.staggerContext, context)
                    if index < children.count - 1 {
                        Spacer(minLength: 0)
                    }
                }

            case .around:
                Spacer(minLength: 0).frame(maxHeight: .infinity)
                ForEach(children.indices, id: \.self) { index in
                    let context = stagger.contextForChild(at: index, childId: children[index].id)
                    renderChildView(node: children[index], crossAxisAlignment: crossAxisAlignment)
                        .environment(\.staggerContext, context)
                    Spacer(minLength: 0).frame(maxHeight: .infinity)
                    if index < children.count - 1 {
                        Spacer(minLength: 0).frame(maxHeight: .infinity)
                    }
                }

            case .evenly:
                Spacer(minLength: 0)
                ForEach(children.indices, id: \.self) { index in
                    let context = stagger.contextForChild(at: index, childId: children[index].id)
                    renderChildView(node: children[index], crossAxisAlignment: crossAxisAlignment)
                        .environment(\.staggerContext, context)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Legacy overload for callers using the old stretchAxis parameter.
    @ViewBuilder
    private func renderChildrenWithSpacers(mode: SpacerMode, stretchAxis: String?) -> some View {
        renderChildrenWithSpacers(mode: mode, crossAxisAlignment: crossAxisChildAlignment(from: stretchAxis))
    }

    // MARK: - Cross-Axis Child Alignment

    /// Describes how a parent stack wants its children aligned on the cross-axis.
    ///
    /// This is passed from the stack render methods down to `renderChildView` so
    /// that each child can be wrapped in a `.frame(maxWidth/maxHeight: .infinity,
    /// alignment: ...)` modifier that ensures children fill the cross-axis dimension
    /// while positioning their content according to the resolved alignment.
    ///
    /// Without this, children that naturally fill the available width (e.g.,
    /// `UIViewRepresentable` text labels with no intrinsic width) would accept
    /// the full proposed width and render their content at the default edge,
    /// making the VStack/HStack alignment invisible.
    private enum CrossAxisChildAlignment {
        /// Cross-axis is stretch -- children expand with the start-edge alignment.
        /// The `parentAxis` indicates the stack direction ("vertical" or "horizontal").
        case stretch(parentAxis: String)
        /// Cross-axis has a specific alignment for a vertical stack (VStack).
        /// Children should fill width (`.infinity`) and align content horizontally.
        case horizontal(HorizontalAlignment)
        /// Cross-axis has a specific alignment for a horizontal stack (HStack).
        /// Children should fill height (`.infinity`) and align content vertically.
        case vertical(VerticalAlignment)
        /// No cross-axis frame should be applied (e.g., layered/wrapped stacks).
        case none
    }

    /// Converts an optional `stretchAxis` string to the corresponding
    /// `CrossAxisChildAlignment` value. Used by legacy overloads that bridge
    /// the old `stretchAxis: String?` API to the new enum-based API.
    ///
    /// This is a plain (non-`@ViewBuilder`) function so that it can perform
    /// imperative `if/else` logic without the SwiftUI result builder
    /// interpreting the branches as view expressions.
    private func crossAxisChildAlignment(from stretchAxis: String?) -> CrossAxisChildAlignment {
        if let axis = stretchAxis {
            return .stretch(parentAxis: axis)
        }
        return .none
    }

    // MARK: - Children Rendering

    /// Renders all normal-flow children of the stack, applying cross-axis alignment or stretch.
    /// Absolutely-positioned children are excluded (they are rendered as overlays instead).
    ///
    /// If the parent has `staggerChildren: true`, each child receives a `StaggerContext`
    /// via the environment with its resolved stagger index and interval. This also
    /// schedules stagger haptics if `staggerHaptic` is set.
    ///
    /// - Parameter crossAxisAlignment: Describes how children should be sized and
    ///   aligned on the parent stack's cross-axis.
    @ViewBuilder
    private func renderChildren(crossAxisAlignment: CrossAxisChildAlignment) -> some View {
        let children = flowChildren
        if !children.isEmpty {
            let stagger = resolveStaggerConfig(totalChildren: children.count)

            ForEach(children.indices, id: \.self) { index in
                let context = stagger.contextForChild(at: index, childId: children[index].id)
                renderChildView(node: children[index], crossAxisAlignment: crossAxisAlignment)
                    .environment(\.staggerContext, context)
            }
        }
    }

    /// Legacy overload that maps the old `stretchAxis` parameter to the new
    /// `CrossAxisChildAlignment` type. Used by callers that do not need
    /// non-stretch alignment (e.g., wrapped horizontal stacks, layered stacks).
    @ViewBuilder
    private func renderChildren(stretchAxis: String?) -> some View {
        renderChildren(crossAxisAlignment: crossAxisChildAlignment(from: stretchAxis))
    }

    /// Renders a single child, applying cross-axis sizing and alignment.
    ///
    /// This method handles two distinct scenarios:
    ///
    /// 1. **Stretch mode** (`.stretch`): Replicates CSS `align-items: stretch` by
    ///    expanding children to fill the parent's cross-axis dimension via
    ///    `.frame(maxWidth/maxHeight: .infinity)`.
    ///
    /// 2. **Alignment mode** (`.horizontal` / `.vertical`): When the parent stack
    ///    specifies a non-stretch cross-axis alignment (e.g., `align: "right"` on a
    ///    vertical stack), children are wrapped in `.frame(maxWidth: .infinity,
    ///    alignment: .trailing)`. This ensures that children which naturally fill
    ///    the available width (such as UILabel-backed text views with no intrinsic
    ///    width) position their content according to the parent's alignment, rather
    ///    than defaulting to the leading edge.
    ///
    /// In both cases, the modifier is skipped when the child already has an explicit
    /// dimension on the cross-axis, since overriding it with `.infinity` would
    /// discard the child's own sizing intent.
    ///
    /// - Parameters:
    ///   - node: The child component node to render.
    ///   - crossAxisAlignment: The parent stack's cross-axis alignment descriptor.
    @ViewBuilder
    private func renderChildView(node childNode: ComponentNode, crossAxisAlignment: CrossAxisChildAlignment) -> some View {
        let child = ComponentRenderer(
            node: childNode,
            variableStore: variableStore,
            actionExecutor: actionExecutor,
            actionContext: actionContext,
            mediaBaseUrl: mediaBaseUrl,
            iconBaseUrl: iconBaseUrl,
            renderTrigger: renderTrigger
        )
        // DEBUG: blue border on every child to visualize its actual frame
        .border(FlowPilot.debugBordersEnabled ? Color.blue.opacity(0.5) : Color.clear, width: FlowPilot.debugBordersEnabled ? 1 : 0)

        let _ = {
            let crossDesc: String
            switch crossAxisAlignment {
            case .stretch(let pa): crossDesc = "stretch(\(pa))"
            case .horizontal: crossDesc = "horizontal"
            case .vertical: crossDesc = "vertical"
            case .none: crossDesc = "none"
            }
            Logger.shared.debug("[ChildView] parent=\(node.id) child=\(childNode.id) type=\(childNode.type.rawValue) crossAxis=\(crossDesc) childWidth=\(descDimension(childNode.props?.width)) childHeight=\(descDimension(childNode.props?.height))")
        }()

        switch crossAxisAlignment {
        case .stretch(let parentAxis):
            if parentAxis == "vertical" {
                // VStack parent: children stretch horizontally, aligned to leading edge.
                // Skip if the child already has an explicit width set.
                if childHasExplicitCrossAxisDimension(childNode, parentAxis: "vertical") {
                    child
                } else {
                    child.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // HStack parent: children stretch vertically, aligned to top edge.
                // Skip if the child already has an explicit height set.
                if childHasExplicitCrossAxisDimension(childNode, parentAxis: "horizontal") {
                    child
                } else {
                    child.frame(maxHeight: .infinity, alignment: .top)
                }
            }

        case .horizontal(let hAlign):
            // VStack parent with non-stretch cross-axis alignment.
            // Expand children to fill width so the alignment is visible, but
            // position their content at the correct horizontal edge.
            if childHasExplicitCrossAxisDimension(childNode, parentAxis: "vertical") {
                child
            } else {
                child.frame(maxWidth: .infinity, alignment: Alignment(horizontal: hAlign, vertical: .center))
            }

        case .vertical:
            // HStack parent with non-stretch cross-axis alignment (center, top, bottom).
            // Do NOT expand children to maxHeight: .infinity — that makes children
            // greedily consume all proposed height, which is wrong for CSS align-items.
            // The HStack's own `alignment` parameter already positions children on the
            // cross-axis. Children should keep their natural (intrinsic) height.
            child

        case .none:
            child
        }
    }

    /// Legacy overload that maps the old `stretchAxis` parameter to the new
    /// `CrossAxisChildAlignment` type.
    @ViewBuilder
    private func renderChildView(node childNode: ComponentNode, stretchAxis: String?) -> some View {
        renderChildView(node: childNode, crossAxisAlignment: crossAxisChildAlignment(from: stretchAxis))
    }

    /// Checks whether a child node has an explicit dimension on the cross-axis
    /// (i.e., a fixed or percentage value, not `auto` or absent).
    ///
    /// For a vertical parent stack, the cross-axis is width.
    /// For a horizontal parent stack, the cross-axis is height.
    ///
    /// - Parameters:
    ///   - childNode: The child component node to inspect.
    ///   - parentAxis: The parent stack's main axis ("vertical" or "horizontal").
    /// - Returns: `true` if the child has an explicit cross-axis dimension that should
    ///   not be overridden by stretch.
    private func childHasExplicitCrossAxisDimension(_ childNode: ComponentNode, parentAxis: String) -> Bool {
        let dimension: DimensionValue?
        if parentAxis == "vertical" {
            // VStack: cross-axis is width
            dimension = childNode.props?.width
        } else {
            // HStack: cross-axis is height
            dimension = childNode.props?.height
        }

        guard let dim = dimension else { return false }

        switch dim {
        case .fixed:
            return true
        case .percent:
            // A percentage dimension is explicit sizing intent
            return true
        case .auto:
            return false
        }
    }

    // MARK: - Cross-Axis Alignment Resolution

    /// Represents the resolved cross-axis mode for a stack.
    ///
    /// In CSS flexbox, `align-items` controls how children are positioned along the
    /// cross-axis. The default value is "stretch", which makes children fill the
    /// parent's cross-axis dimension. Other values (start, center, end, baseline)
    /// only affect positioning without changing the child's size.
    private enum CrossAxisMode {
        /// Children should stretch to fill the cross-axis dimension.
        /// The container alignment uses the start edge (.top for HStack, .leading for VStack).
        /// - `explicit`: true when the user explicitly set `alignItems: "stretch"` (or equiv.),
        ///   false when stretch is the implicit default because no alignment was specified.
        case stretch(explicit: Bool)
        /// Children use their intrinsic size and are positioned according to the alignment.
        case align(vertical: VerticalAlignment, horizontal: HorizontalAlignment)

        /// Whether this mode is stretch (regardless of explicit/implicit)
        var isStretch: Bool {
            if case .stretch = self { return true }
            return false
        }

        /// Whether the user explicitly set stretch alignment.
        /// Returns false for implicit default stretch and non-stretch modes.
        var isExplicitStretch: Bool {
            if case .stretch(let explicit) = self { return explicit }
            return false
        }

        /// The vertical alignment to use for HStack container.
        /// For stretch: .top (children fill from the top edge).
        /// For align: the resolved vertical alignment value.
        var verticalAlignment: VerticalAlignment {
            switch self {
            case .stretch:
                return .top
            case .align(let v, _):
                return v
            }
        }

        /// The horizontal alignment to use for VStack container.
        /// For stretch: .leading (children fill from the leading edge).
        /// For align: the resolved horizontal alignment value.
        var horizontalAlignment: HorizontalAlignment {
            switch self {
            case .stretch:
                return .leading
            case .align(_, let h):
                return h
            }
        }
    }

    /// Resolves the cross-axis alignment mode for the given stack axis.
    ///
    /// Checks properties in priority order: `align` -> `alignItems` -> axis-specific
    /// (`verticalAlign` for horizontal, `horizontalAlign` for vertical).
    /// Defaults to `.stretch(explicit: false)` when no alignment property is set,
    /// matching the web editor's behavior where `align ?? "stretch"` is the default.
    /// The `explicit` flag distinguishes user-specified stretch from the implicit default,
    /// allowing the rendering logic to decide whether stretch should actually be applied
    /// based on whether the parent has explicit cross-axis dimensions.
    ///
    /// - Parameter axis: The stack's main axis ("horizontal" or "vertical").
    /// - Returns: The resolved cross-axis mode.
    private func resolveCrossAxisMode(for axis: String) -> CrossAxisMode {
        // Gather the resolved alignment string from the property priority chain.
        // Priority: align (editor-primary) -> alignItems (CSS fallback) -> axis-specific property
        // The web editor writes `align` as the primary cross-axis property; `alignItems`
        // may co-exist in the JSON as a legacy/default value. Matching the web editor's
        // resolution order ensures parity when both are present with conflicting values.
        let alignValue: String? = {
            if let align = PropertyResolver.resolve(node.props?.align, store: variableStore) {
                return align
            }
            if let alignItems = PropertyResolver.resolve(node.props?.alignItems, store: variableStore) {
                return alignItems
            }
            if axis == "horizontal" {
                if let vAlign = PropertyResolver.resolve(node.props?.verticalAlign, store: variableStore) {
                    return vAlign
                }
            } else {
                if let hAlign = PropertyResolver.resolve(node.props?.horizontalAlign, store: variableStore) {
                    return hAlign
                }
            }
            return nil
        }()

        // Track whether the user explicitly set the alignment or we're using the default
        let isExplicit = alignValue != nil
        let effectiveValue = alignValue ?? "stretch"

        // "stretch" means children fill the cross-axis
        if effectiveValue == "stretch" {
            return .stretch(explicit: isExplicit)
        }

        // Non-stretch: parse into concrete alignment values
        if axis == "horizontal" {
            let vAlign = parseVerticalAlignment(effectiveValue) ?? .top
            return .align(vertical: vAlign, horizontal: .leading)
        } else {
            let hAlign = parseHorizontalAlignment(effectiveValue) ?? .leading
            return .align(vertical: .top, horizontal: hAlign)
        }
    }

    /// Parse vertical alignment value for HStack cross-axis.
    ///
    /// Handles: top, center, bottom, left, right, baseline.
    /// Note: left/right map to top/bottom for HStack cross-axis (left=top, right=bottom).
    private func parseVerticalAlignment(_ value: String) -> VerticalAlignment? {
        switch value {
        case "flex-start", "start", "top", "left": return .top
        case "flex-end", "end", "bottom", "right": return .bottom
        case "center": return .center
        case "baseline": return .firstTextBaseline
        default: return nil
        }
    }

    /// Parse horizontal alignment value for VStack cross-axis.
    ///
    /// Handles: left, center, right, top, bottom.
    /// Note: top/bottom map to leading/trailing for VStack cross-axis.
    private func parseHorizontalAlignment(_ value: String) -> HorizontalAlignment? {
        switch value {
        case "flex-start", "start", "left", "top": return .leading
        case "flex-end", "end", "right", "bottom": return .trailing
        case "center": return .center
        default: return nil
        }
    }

    /// Resolves the alignment for a layered (ZStack) container from props.
    ///
    /// For a ZStack, both axes are "cross-axes" since children overlay each other:
    /// - Horizontal alignment comes from `align` / `alignItems` (same source as VStack cross-axis).
    /// - Vertical alignment comes from `justify` / `justifyContent`.
    ///
    /// Defaults to `.topLeading` when no alignment properties are set,
    /// preserving the existing behavior and matching the web editor's default.
    private var layeredAlignment: Alignment {
        // Resolve horizontal alignment from align (editor-primary) / alignItems (CSS fallback)
        let alignValue = PropertyResolver.resolve(node.props?.align, store: variableStore)
            ?? PropertyResolver.resolve(node.props?.alignItems, store: variableStore)
        let horizontal = alignValue.flatMap { parseHorizontalAlignment($0) } ?? .leading

        // Resolve vertical alignment from justify/justifyContent props
        let justifyValue = PropertyResolver.resolve(node.props?.justify, store: variableStore)
            ?? PropertyResolver.resolve(node.props?.justifyContent, store: variableStore)
        let vertical = justifyValue.flatMap { parseVerticalAlignment($0) } ?? .top

        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    // MARK: - Stretch Eligibility

    /// Determines whether cross-axis stretch should actually be applied for a given
    /// stack axis and cross-axis mode.
    ///
    /// Stretch (`maxWidth/maxHeight: .infinity` on children) is only meaningful when the
    /// parent stack has a defined cross-axis dimension for children to stretch into.
    /// Without a defined dimension, applying `.infinity` causes children to expand
    /// unboundedly, creating visual issues like extra vertical space in headers/footers
    /// and background bleed-through.
    ///
    /// - When the user **explicitly** set `alignItems: "stretch"`, we apply stretch
    ///   only if the parent has an explicit cross-axis dimension (fixed, percentage, or
    ///   `.infinity` from 100% width/height).
    /// - When stretch is the **implicit default** (no alignment property set), we apply
    ///   stretch only if the parent has an explicit cross-axis dimension. If the parent
    ///   is content-sized, the default is effectively no-stretch because there is no
    ///   defined space for children to stretch into.
    ///
    /// - Parameters:
    ///   - axis: The parent stack's main axis ("horizontal" or "vertical").
    ///   - crossMode: The resolved cross-axis mode from `resolveCrossAxisMode()`.
    /// - Returns: `true` if stretch frames should be applied to children.
    private func shouldApplyStretch(for axis: String, crossMode: CrossAxisMode) -> Bool {
        guard crossMode.isStretch else { return false }

        if axis == "horizontal" {
            // HStack: cross-axis is vertical (height).
            // Children stretch means maxHeight: .infinity, which only makes sense
            // if the parent has an explicit height.
            return resolveMaxHeight() != nil
        } else {
            // VStack: cross-axis is horizontal (width).
            // Children stretch means maxWidth: .infinity, which only makes sense
            // if the parent has an explicit width.
            return resolveMaxWidth() != nil
        }
    }

    // MARK: - Size Resolution

    private func resolveMaxWidth() -> CGFloat? {
        // Check for explicit fixed width - this takes precedence over all other sizing
        if let width = node.props?.width {
            switch width {
            case .fixed(let value):
                // Explicit fixed width always wins
                return CGFloat(value)
            case .percent(let value) where value == 100:
                return .infinity
            case .percent(let value):
                // Non-100% percentage: resolve against the parent container's measured width.
                // This ensures the inner HStack/VStack expands to match the percentage width
                // so that `.injectParentSize()` captures the correct size for children.
                if parentSize.width > 0 {
                    return parentSize.width * CGFloat(value) / 100
                }
                // Fall through to check align when parent size is not yet available
                break
            case .auto:
                // auto falls through to check align
                break
            }
        }

        // Note: The `fill` property controls background fill type (solid/none),
        // NOT width sizing. Width comes from the `width` property or the default
        // block-level expansion below. See web editor's style-helpers.ts.

        // Check horizontalAlign - only expand if explicitly set to stretch
        if let hAlign = PropertyResolver.resolve(node.props?.horizontalAlign, store: variableStore) {
            if hAlign == "stretch" {
                return .infinity
            }
        }

        // CSS flexbox containers are block-level elements by default, meaning they
        // take 100% of their parent's width. The web editor's stack-renderer also
        // explicitly defaults stack width to "100%" via calculateWidthWithMargins().
        // Therefore stacks should expand to fill available width unless they have
        // an explicit auto/fixed width that prevents it (handled above).
        //
        // Note: The previous code here checked `alignItems == "stretch"` and returned
        // .infinity, but that was incorrect. In CSS, `align-items` affects CHILDREN
        // layout (how children are sized on the cross-axis), not the container's own
        // width. The container width comes from being a block-level element (100% by
        // default) or from an explicit width property.
        return .infinity
    }

    private func resolveMaxHeight() -> CGFloat? {
        if let height = node.props?.height {
            switch height {
            case .auto:
                return nil
            case .fixed(let value):
                return CGFloat(value)
            case .percent(let value) where value == 100:
                return .infinity
            case .percent(let value):
                // Non-100% percentage: resolve against the parent container's measured height.
                if parentSize.height > 0 {
                    return parentSize.height * CGFloat(value) / 100
                }
                return nil
            }
        }
        return nil
    }

    // MARK: - Flex-Shrink (CSS flex-shrink: 1)

    /// CSS flex-shrink factor for this horizontal stack's **direct** children.
    ///
    /// SwiftUI `HStack` has no flex-shrink: fixed-width children stay rigid and
    /// overflow, and an over-wide row then drags full-width siblings off the
    /// content box. The editor (and Expo/Yoga) shrink children proportionally to
    /// fit (default `flex-shrink: 1`). When every child has a resolvable width
    /// (fixed or percent) and their natural widths + gaps exceed the stack's
    /// available content width, this returns the factor (< 1.0) that shrinks them
    /// to fit; the children's `UniversalStyleModifier` multiplies their width by it.
    ///
    /// Scoped narrow on purpose:
    /// - if ANY child is auto/intrinsic (e.g. text) we bail to 1.0 — its natural
    ///   width is unknown here and we must not mis-shrink ordinary rows;
    /// - scrollable rows overflow at natural size (editor sets `flex-shrink: 0`),
    ///   so they are excluded.
    /// It therefore only fires for over-allocated rows of explicitly-sized boxes.
    private func horizontalShrinkScale(spacing: CGFloat) -> CGFloat {
        let children = flowChildren
        guard !children.isEmpty else { return 1.0 }

        // Scrollable rows are meant to overflow (flex-shrink:0), not shrink.
        let scroll = PropertyResolver.resolve(node.props?.scrollBehavior, store: variableStore, default: "no-scroll")
        if scroll == "scroll" { return 1.0 }

        let available = ownContentWidthForChildren()
        guard available > 0 else { return 1.0 }

        var naturalSum: CGFloat = 0
        for child in children {
            guard let w = resolvableChildWidth(child, containerWidth: available), w > 0 else {
                return 1.0  // unresolvable (auto/intrinsic) child → do not shrink
            }
            naturalSum += w
        }
        let gaps = CGFloat(max(0, children.count - 1)) * spacing
        guard naturalSum + gaps > available else { return 1.0 }

        // Shrink only the items; the gaps do not shrink (CSS).
        let scale = (available - gaps) / naturalSum
        let result = (scale > 0 && scale < 1) ? scale : 1.0
        Logger.shared.debug("[Shrink] node=\(node.id) available=\(available) naturalSum=\(naturalSum) gaps=\(gaps) -> scale=\(result) (parentSize.w=\(parentSize.width))")
        return result
    }

    /// Width available to this stack's children = its own resolved width minus
    /// its own horizontal padding.
    private func ownContentWidthForChildren() -> CGFloat {
        let ownWidth: CGFloat
        switch node.props?.width {
        case .fixed(let v):
            ownWidth = CGFloat(v)
        case .percent(let v) where v != 100:
            ownWidth = parentSize.width > 0 ? parentSize.width * CGFloat(v) / 100 : 0
        default:
            // 100% / auto / unset: block-level, fills the parent's content width.
            ownWidth = parentSize.width
        }
        return ownWidth - ownHorizontalPadding()
    }

    /// This stack's own left+right padding (mirrors `UniversalStyleModifier`).
    private func ownHorizontalPadding() -> CGFloat {
        func d(_ p: PropertyValue<Double>?) -> CGFloat {
            guard let p = p else { return 0 }
            return CGFloat(PropertyResolver.resolve(p, store: variableStore, default: 0.0))
        }
        if node.props?.paddingAdvanced == true {
            return d(node.props?.paddingLeft) + d(node.props?.paddingRight)
        }
        let h = d(node.props?.paddingHorizontal)
        return h + h
    }

    /// A child's natural (pre-shrink) width, or `nil` when it can't be resolved
    /// here (auto / intrinsic — e.g. text), signalling the caller not to shrink.
    private func resolvableChildWidth(_ child: ComponentNode, containerWidth: CGFloat) -> CGFloat? {
        switch child.props?.width {
        case .fixed(let v): return CGFloat(v)
        case .percent(let v) where v == 100: return containerWidth
        case .percent(let v): return containerWidth * CGFloat(v) / 100
        case .auto, .none: return nil
        }
    }

    // MARK: - Absolute Positioning

    /// Children that participate in normal flex flow (i.e., NOT absolutely positioned).
    /// Used by all rendering methods so that absolute children are excluded from
    /// VStack/HStack layout and spacer calculations.
    private var flowChildren: [ComponentNode] {
        (node.children ?? []).filter { !isAbsolutelyPositioned($0) }
    }

    /// Whether a child node is taken out of normal flex flow and rendered as an
    /// overlay anchored to this stack's bounds.
    ///
    /// `absolute`, `fixed`, and `sticky` all resolve here. The editor canvas and
    /// the Expo SDK collapse `fixed`/`sticky` to the same parent-relative
    /// absolute behavior (there is no scrollable viewport to pin to in a flow
    /// screen), so we match them — otherwise a "fixed + bottom: 0" footer
    /// designed on the dashboard would silently fall back to normal flow on iOS.
    private func isAbsolutelyPositioned(_ childNode: ComponentNode) -> Bool {
        let pos = PropertyResolver.resolve(childNode.props?.positionType, store: variableStore, default: "normal")
        return pos == "absolute" || pos == "fixed" || pos == "sticky"
    }

    /// Renders a single absolutely-positioned child within the parent's coordinate space.
    /// Uses `top/right/bottom/left` insets to position the child relative to the parent's edges.
    @ViewBuilder
    func renderAbsoluteChild(_ childNode: ComponentNode, in parentSize: CGSize) -> some View {
        // Resolve inset values. nil means "not set" (different from 0).
        let topVal = resolveOptionalInset(childNode.props?.top)
        let bottomVal = resolveOptionalInset(childNode.props?.bottom)
        let leftVal = resolveOptionalInset(childNode.props?.left)
        let rightVal = resolveOptionalInset(childNode.props?.right)

        // Single-edge anchoring hugs content on that axis: a fill size (e.g.
        // height `100%`) would make the box span the whole parent so the inset no
        // longer pins it (the box fills and its content sits at the opposite
        // edge). Collapsing the fill size to `auto` lets the box size to its
        // content. Mirrors the editor canvas (`isFillSize`) + Expo SDK. Fixed
        // lengths are left untouched.
        let effectiveNode = collapseFillForSingleEdgeAnchor(
            childNode,
            hasTop: topVal != nil, hasBottom: bottomVal != nil,
            hasLeft: leftVal != nil, hasRight: rightVal != nil
        )

        let child = ComponentRenderer(
            node: effectiveNode,
            variableStore: variableStore,
            actionExecutor: actionExecutor,
            actionContext: actionContext,
            mediaBaseUrl: mediaBaseUrl,
            iconBaseUrl: iconBaseUrl,
            renderTrigger: renderTrigger
        )

        // Determine the alignment within the parent based on which insets are set.
        // CSS absolute positioning anchors:
        //   top+left (default) → topLeading
        //   top+right → topTrailing
        //   bottom+left → bottomLeading
        //   bottom+right → bottomTrailing
        //   Only top → top edge, horizontally at left (default)
        //   Only bottom → bottom edge, horizontally at left
        //   Only left → left edge, vertically at top (default)
        //   Only right → right edge, vertically at top
        //   None set → topLeading (CSS default for absolute with no insets)
        let vAlignment: VerticalAlignment = (bottomVal != nil && topVal == nil) ? .bottom : .top
        let hAlignment: HorizontalAlignment = (rightVal != nil && leftVal == nil) ? .trailing : .leading

        // Calculate the offset from the anchor edge.
        // When both top and bottom are set, top wins for positioning (CSS spec).
        // When both left and right are set, left wins for positioning.
        let yOffset: CGFloat = {
            if let top = topVal { return CGFloat(top) }
            if let bottom = bottomVal { return CGFloat(-bottom) }
            return 0
        }()

        let xOffset: CGFloat = {
            if let left = leftVal { return CGFloat(left) }
            if let right = rightVal { return CGFloat(-right) }
            return 0
        }()

        child
            .frame(
                maxWidth: parentSize.width > 0 ? parentSize.width : nil,
                maxHeight: parentSize.height > 0 ? parentSize.height : nil,
                alignment: Alignment(horizontal: hAlignment, vertical: vAlignment)
            )
            .offset(x: xOffset, y: yOffset)
    }

    /// Resolves an optional inset property (top/right/bottom/left).
    /// Returns `nil` when the property is not set, distinguishing "not set" from "set to 0".
    private func resolveOptionalInset(_ property: PropertyValue<Double>?) -> Double? {
        guard let prop = property else { return nil }
        return PropertyResolver.resolve(prop, store: variableStore, default: 0.0)
    }

    /// Whether a dimension means "fill the parent" (any percentage). Matches the
    /// editor's `isFillSize` and Expo's `isFillDimension`.
    private func isFillDimension(_ dim: DimensionValue?) -> Bool {
        if case .percent = dim { return true }
        return false
    }

    /// Collapses a fill width/height to `auto` when the child is anchored by a
    /// single edge on that axis, so the inset can actually pin it. Returns the
    /// node unchanged when neither axis needs collapsing.
    private func collapseFillForSingleEdgeAnchor(
        _ childNode: ComponentNode,
        hasTop: Bool, hasBottom: Bool, hasLeft: Bool, hasRight: Bool
    ) -> ComponentNode {
        guard let props = childNode.props else { return childNode }
        var keysToCollapse: [String] = []
        if hasTop != hasBottom && isFillDimension(props.height) {
            keysToCollapse.append("height")
        }
        if hasLeft != hasRight && isFillDimension(props.width) {
            keysToCollapse.append("width")
        }
        guard !keysToCollapse.isEmpty else { return childNode }
        return childNode.replacingProps(props.collapsingDimensionsToAuto(keysToCollapse))
    }

    // MARK: - Stagger Resolution

    /// Resolved stagger configuration for this stack's children.
    ///
    /// Encapsulates whether stagger is active, the interval, order, and haptic
    /// pattern so that each child rendering site can obtain its `StaggerContext`
    /// without re-resolving the parent props.
    private struct ResolvedStagger {
        let isEnabled: Bool
        let interval: TimeInterval
        let order: String
        let hapticPattern: String
        let totalChildren: Int
        let chainDelays: [String: TimeInterval]
        let priorDelays: [String: TimeInterval]

        /// Returns the `StaggerContext` for a child at the given natural index and ID.
        func contextForChild(at index: Int, childId: String) -> StaggerContext {
            let chainDelay = chainDelays[childId] ?? 0
            guard isEnabled else {
                return StaggerContext(index: 0, interval: 0, chainDelay: chainDelay, priorDelay: 0)
            }
            let resolved = StaggerCoordinator.resolvedIndex(index, order: order, total: totalChildren)
            return StaggerContext(index: resolved, interval: interval, chainDelay: chainDelay, priorDelay: priorDelays[childId] ?? 0)
        }
    }

    /// Resolves stagger configuration from this stack's props.
    ///
    /// This is a pure function with no side effects. It reads the stagger
    /// properties from the node's props and returns a `ResolvedStagger` value
    /// that can compute per-child stagger contexts.
    ///
    /// **Important**: Haptic scheduling is NOT done here because this function
    /// is called during view body evaluation, which SwiftUI may call multiple
    /// times. Haptics are instead scheduled via `onAppear` in the animation
    /// modifier for each child.
    ///
    /// - Parameter totalChildren: The number of normal-flow children in the stack.
    /// - Returns: A `ResolvedStagger` that can compute per-child stagger contexts.
    private func resolveStaggerConfig(totalChildren: Int) -> ResolvedStagger {
        let staggerConfig = StaggerConfig.resolve(from: node.props, variableStore: variableStore)
        let isEnabled = staggerConfig?.enabled ?? false
        let chainDelays = ChainResolver.resolveChainDelays(children: flowChildren, variableStore: variableStore)

        guard isEnabled, totalChildren > 0 else {
            return ResolvedStagger(
                isEnabled: false,
                interval: 0,
                order: "natural",
                hapticPattern: "none",
                totalChildren: totalChildren,
                chainDelays: chainDelays,
                priorDelays: [:]
            )
        }

        let interval = staggerConfig?.interval ?? 0
        let order = staggerConfig?.order ?? "natural"
        let hapticPattern = staggerConfig?.haptic ?? "none"
        // Cascade offsets so a delayed child pushes later siblings instead of
        // being overtaken (matches the dashboard + Expo cascade behavior).
        let priorDelays = StaggerCoordinator.priorDelays(children: flowChildren, order: order, variableStore: variableStore)

        Logger.shared.debug("[StackView] Stagger resolved: node=\(node.id) enabled=true interval=\(interval * 1000)ms order=\(order) haptic=\(hapticPattern) children=\(totalChildren)")

        return ResolvedStagger(
            isEnabled: true,
            interval: interval,
            order: order,
            hapticPattern: hapticPattern,
            totalChildren: totalChildren,
            chainDelays: chainDelays,
            priorDelays: priorDelays
        )
    }

    /// Schedules stagger haptic ticks exactly once per stack instance.
    ///
    /// Called from `onAppear` to avoid scheduling side effects during body
    /// evaluation (which SwiftUI may call multiple times). Uses the
    /// `hasScheduledStaggerHaptics` state flag to ensure haptics are only
    /// scheduled once per appearance.
    private func scheduleStaggerHapticsOnce() {
        guard !hasScheduledStaggerHaptics else { return }

        let children = flowChildren
        let stagger = resolveStaggerConfig(totalChildren: children.count)

        guard stagger.isEnabled, stagger.hapticPattern != "none" else { return }

        hasScheduledStaggerHaptics = true

        // Fire each child's tick at the moment it actually appears, matching the
        // animation timing: stagger offset (resolvedIndex * interval) + the
        // cascade of earlier siblings' enter delays (priorDelay) + the child's
        // own enter delay. A uniform `index * interval` cadence would fire the
        // first tick on screen load and drop the last child's tick whenever any
        // child carries an enter delay. Sorted ascending so `ramp` escalates in
        // appearance order.
        let total = children.count
        let times = children.enumerated()
            .map { (index, child) -> TimeInterval in
                let resolved = StaggerCoordinator.resolvedIndex(index, order: stagger.order, total: total)
                let prior = stagger.priorDelays[child.id] ?? 0
                let own = StaggerCoordinator.enterDelay(for: child, variableStore: variableStore)
                return Double(resolved) * stagger.interval + prior + own
            }
            .sorted()

        Logger.shared.debug("[StackView] Scheduling stagger haptics: node=\(node.id) pattern=\(stagger.hapticPattern) times=\(times)")

        HapticManager.shared.prepare()
        HapticManager.shared.scheduleStaggerTicks(pattern: stagger.hapticPattern, times: times)
    }

    // MARK: - Debug Helpers

    /// Human-readable description of a DimensionValue for debug logging.
    private func descDimension(_ dim: DimensionValue?) -> String {
        guard let dim = dim else { return "nil" }
        switch dim {
        case .auto: return "auto"
        case .fixed(let v): return "fixed(\(v))"
        case .percent(let v): return "percent(\(v))"
        }
    }
}

// MARK: - Absolute Children Overlay

/// View extension that overlays absolutely-positioned children on top of the normal-flow
/// stack content. Uses a `GeometryReader` to measure the parent's size and passes it to
/// each absolute child for inset-based positioning.
///
/// When `enabled` is `false` (no absolute children), this modifier is a no-op — no
/// GeometryReader or ZStack is introduced, preserving exact existing rendering behavior.
extension View {
    @MainActor
    @ViewBuilder
    func overlayAbsoluteChildren(
        _ absoluteChildren: [ComponentNode],
        enabled: Bool,
        stackView: StackView
    ) -> some View {
        if enabled {
            self.overlay(
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        // Transparent spacer to fill the geometry without affecting layout
                        Color.clear

                        ForEach(absoluteChildren.indices, id: \.self) { index in
                            stackView.renderAbsoluteChild(
                                absoluteChildren[index],
                                in: geometry.size
                            )
                        }
                    }
                }
            )
        } else {
            self
        }
    }
}

// MARK: - Screen Root View

/// Renders the root container of a screen
/// Now delegates to StackView to ensure full alignment/spacing parity with regular stacks
struct ScreenRootView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let mediaBaseUrl: String?
    let iconBaseUrl: String?
    var renderTrigger: Int = 0

    var body: some View {
        let _ = Logger.shared.debug("ScreenRootView.body - delegating to StackView for full alignment support, children count: \(node.children?.count ?? 0)")
        // Delegate to StackView so that align, justify, gap/spacing, and axis/direction
        // are all respected — achieving parity with the web editor rendering.
        // Note: StackView internally applies `.injectParentSize()` to its stack containers,
        // so children with percentage dimensions resolve relative to the stack's rendered size.
        //
        // The `.topLeading` alignment matches CSS document flow direction (top-left origin).
        // Without it, the default `.center` alignment could visually center content when
        // the inner StackView's rendered size doesn't perfectly fill the frame — e.g.,
        // during SwiftUI layout passes or when content is smaller than the screen.
        StackView(
            node: node,
            variableStore: variableStore,
            actionExecutor: actionExecutor,
            actionContext: actionContext,
            mediaBaseUrl: mediaBaseUrl,
            iconBaseUrl: iconBaseUrl,
            renderTrigger: renderTrigger
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
