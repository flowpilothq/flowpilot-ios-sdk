import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Text View

/// Renders a text component with variable interpolation
/// Uses platform-native label wrapper to support proper CSS-like lineHeight (including values < 1.2)
struct TextView: View {
    let props: ComponentProps?
    let variableStore: VariableStore
    var renderTrigger: Int = 0

    var body: some View {
        // Force re-evaluation when renderTrigger changes
        let _ = renderTrigger

        let _ = Logger.shared.debug("[TextView] text='\(resolvedText.prefix(20))' resolvedFrameMaxWidth=\(resolvedFrameMaxWidth.map{String(describing:$0)} ?? "nil")")

        textContent
            .border(FlowPilot.debugBordersEnabled ? Color.orange : Color.clear, width: FlowPilot.debugBordersEnabled ? 1 : 0) // DEBUG: text content actual frame
            .frame(maxWidth: resolvedFrameMaxWidth, alignment: resolvedFrameAlignment)
            .border(FlowPilot.debugBordersEnabled ? Color.cyan : Color.clear, width: FlowPilot.debugBordersEnabled ? 1 : 0) // DEBUG: after frame(maxWidth:)
    }

    // MARK: - Text Content Dispatch

    /// Selects the appropriate text rendering path based on textRotation and textEffect config.
    @ViewBuilder
    private var textContent: some View {
        if let segments = props?.richText, !segments.isEmpty {
            // Rich Text: render inline-styled runs as an AttributedString. Each
            // run carries its own font (size/family + per-run weight/italic),
            // underline/strikethrough, and optional colour; runs without a colour
            // inherit the node's base colour via `.foregroundColor` below. Rich
            // text is mutually exclusive with rotation / text effects.
            Text(richAttributedString(segments))
                .multilineTextAlignment(resolvedSwiftUITextAlignment)
                .lineSpacing(resolvedLineSpacing)
                .foregroundColor(resolvedSwiftUIColor)
        } else if let rotation = props?.textRotation, !rotation.values.isEmpty {
            // Text rotation: cycle through multiple values with transitions.
            // Build the full values array with the component's content as the first entry.
            let allValues = [resolvedText] + rotation.values
            TextRotationView(
                values: allValues,
                interval: rotation.interval,
                transition: rotation.transition,
                transitionDuration: rotation.transitionDuration,
                loop: rotation.loop,
                pauseOnLast: rotation.pauseOnLast
            )
            .applyTextEffectStyling(
                fontSize: resolvedFontSize,
                fontWeight: resolvedSwiftUIFontWeight,
                fontFamily: resolvedFontFamily,
                color: resolvedSwiftUIColor,
                alignment: resolvedSwiftUITextAlignment,
                lineSpacing: resolvedLineSpacing,
                letterSpacing: resolvedLetterSpacing,
                textCase: resolvedTextCaseTransform
            )
        } else if let effect = props?.textEffect {
            // Text effect: render the appropriate animated text view.
            textEffectContent(effect)
                .applyTextEffectStyling(
                    fontSize: resolvedFontSize,
                    fontWeight: resolvedSwiftUIFontWeight,
                    fontFamily: resolvedFontFamily,
                    color: resolvedSwiftUIColor,
                    alignment: resolvedSwiftUITextAlignment,
                    lineSpacing: resolvedLineSpacing,
                    letterSpacing: resolvedLetterSpacing,
                    textCase: resolvedTextCaseTransform
                )
        } else {
            // Default: platform-native LineHeightText for precise line-height control.
            LineHeightText(
                text: resolvedText,
                fontSize: resolvedFontSize,
                fontWeight: resolvedPlatformFontWeight,
                fontFamily: resolvedFontFamily,
                color: resolvedPlatformColor,
                alignment: resolvedPlatformTextAlignment,
                lineHeightMultiplier: resolvedLineHeightMultiplier,
                letterSpacing: resolvedLetterSpacing,
                maxLines: resolvedMaxLines ?? 0,
                textCase: resolvedTextCaseTransform
            )
            // Note: .fixedSize(horizontal: false, vertical: true) was removed here.
            // It was overriding LineHeightText.sizeThatFits content-hugging width,
            // because horizontal:false tells SwiftUI to accept full proposed width.
            // Vertical ideal sizing is now handled by sizeThatFits (iOS 16+) and
            // intrinsicContentSize (iOS 15).
        }
    }

    /// Returns the appropriate text effect view for the given config.
    @ViewBuilder
    private func textEffectContent(_ effect: TextEffectConfig) -> some View {
        switch effect.type {
        case "typewriter":
            TypewriterEffectView(
                fullText: resolvedText,
                speed: effect.speed,
                wordMode: false,
                cursor: effect.cursor,
                cursorChar: effect.cursorChar,
                haptic: effect.haptic,
                delay: effect.delay
            )

        case "typewriterWord":
            TypewriterEffectView(
                fullText: resolvedText,
                speed: effect.speed,
                wordMode: true,
                cursor: effect.cursor,
                cursorChar: effect.cursorChar,
                haptic: effect.haptic,
                delay: effect.delay
            )

        case "countUp":
            CountUpEffectView(
                targetText: resolvedText,
                speed: effect.speed,
                delay: effect.delay,
                duration: effect.duration
            )

        case "scramble":
            ScrambleEffectView(
                targetText: resolvedText,
                speed: effect.speed,
                delay: effect.delay
            )

        case "fadePerLine":
            FadePerLineEffectView(
                fullText: resolvedText,
                speed: effect.speed,
                delay: effect.delay,
                duration: effect.duration
            )

        default:
            // Unknown effect type -- fall back to plain text.
            Text(resolvedText)
        }
    }

    // MARK: - Rich Text

    /// Builds the styled `AttributedString` for a Rich Text node. Base typography
    /// (size / family / weight / case) comes from the node's resolved props; each
    /// run layers its own bold / italic / underline / strikethrough / colour on
    /// top. Matches the dashboard `<span>` runs and the Expo nested `<Text>`.
    private func richAttributedString(_ segments: [RichTextSegment]) -> AttributedString {
        var result = AttributedString()
        let baseWeight = resolvedSwiftUIFontWeight
        let baseSize = resolvedFontSize
        let baseFamily = resolvedFontFamily
        let textCase = resolvedTextCaseTransform

        for seg in segments {
            let displayText: String
            switch textCase {
            case .uppercase: displayText = seg.text.uppercased()
            case .lowercase: displayText = seg.text.lowercased()
            case .capitalize: displayText = seg.text.capitalized
            case .none: displayText = seg.text
            }

            var run = AttributedString(displayText)
            let weight: Font.Weight = seg.bold ? .bold : baseWeight
            var font = FontManager.resolveSwiftUIFont(family: baseFamily, weight: weight, size: baseSize)
            if seg.italic {
                font = font.italic()
            }
            run.font = font
            if seg.underline {
                run.underlineStyle = .single
            }
            if seg.strikethrough {
                run.strikethroughStyle = .single
            }
            if let colorStr = seg.color, let color = Color(hex: colorStr) {
                run.foregroundColor = color
            }
            result.append(run)
        }
        return result
    }

    // MARK: - Property Resolution

    private var resolvedText: String {
        PropertyResolver.resolveString(props?.text, store: variableStore, default: "")
    }

    private var resolvedFontSize: CGFloat {
        let size = PropertyResolver.resolve(props?.fontSize, store: variableStore, default: 16.0)
        return CGFloat(size)
    }

    private var resolvedFontFamily: String? {
        PropertyResolver.resolve(props?.fontFamily, store: variableStore)
    }

    #if canImport(UIKit)
    private var resolvedPlatformFontWeight: UIFont.Weight {
        let weight = PropertyResolver.resolve(props?.fontWeight, store: variableStore, default: "400")
        return FontManager.uiKitWeight(from: weight)
    }

    private var resolvedPlatformColor: UIColor {
        let colorStr = PropertyResolver.resolve(props?.color, store: variableStore, default: "#000000")
        return UIColor(Color(hex: colorStr) ?? .primary)
    }

    private var resolvedPlatformTextAlignment: NSTextAlignment {
        let align = PropertyResolver.resolve(props?.textAlign, store: variableStore, default: "left")
        switch align {
        case "center": return .center
        case "right": return .right
        case "justify": return .justified
        default: return .left
        }
    }
    #elseif canImport(AppKit)
    private var resolvedPlatformFontWeight: NSFont.Weight {
        let weight = PropertyResolver.resolve(props?.fontWeight, store: variableStore, default: "400")
        return FontManager.appKitWeight(from: weight)
    }

    private var resolvedPlatformColor: NSColor {
        let colorStr = PropertyResolver.resolve(props?.color, store: variableStore, default: "#000000")
        return NSColor(Color(hex: colorStr) ?? .primary)
    }

    private var resolvedPlatformTextAlignment: NSTextAlignment {
        let align = PropertyResolver.resolve(props?.textAlign, store: variableStore, default: "left")
        switch align {
        case "center": return .center
        case "right": return .right
        case "justify": return .justified
        default: return .left
        }
    }
    #endif

    private var resolvedMaxLines: Int? {
        if let maxLines: Int = PropertyResolver.resolve(props?.maxLines, store: variableStore) {
            return maxLines
        }
        return nil
    }

    private var resolvedLineHeightMultiplier: CGFloat {
        let lineHeight = PropertyResolver.resolve(props?.lineHeight, store: variableStore, default: 1.5)
        return CGFloat(lineHeight)
    }

    private var resolvedLetterSpacing: CGFloat {
        let letterSpacing = PropertyResolver.resolve(props?.letterSpacing, store: variableStore, default: 0.0)
        return CGFloat(letterSpacing)
    }

    // MARK: - SwiftUI Text Styling (for text effect / rotation paths)

    /// Resolved SwiftUI Font.Weight for use with text effect views.
    private var resolvedSwiftUIFontWeight: Font.Weight {
        let weight = PropertyResolver.resolve(props?.fontWeight, store: variableStore, default: "400")
        return FontManager.swiftUIWeight(from: weight)
    }

    /// Resolved SwiftUI Color for use with text effect views.
    private var resolvedSwiftUIColor: Color {
        let colorStr = PropertyResolver.resolve(props?.color, store: variableStore, default: "#000000")
        return Color(hex: colorStr) ?? .primary
    }

    /// Resolved SwiftUI TextAlignment for use with text effect views.
    private var resolvedSwiftUITextAlignment: TextAlignment {
        let align = PropertyResolver.resolve(props?.textAlign, store: variableStore, default: "left")
        switch align {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    /// Resolved line spacing for SwiftUI Text (converted from lineHeightMultiplier).
    /// SwiftUI `.lineSpacing` adds *extra* space between lines, so we derive it from
    /// the multiplier relative to a baseline of ~1.2 (the default SwiftUI Text spacing).
    private var resolvedLineSpacing: CGFloat {
        let multiplier = resolvedLineHeightMultiplier
        // SwiftUI default line spacing is roughly 1.2x the font size.
        // Extra line spacing = (multiplier - 1.2) * fontSize, clamped to >= 0.
        let extra = (multiplier - 1.2) * resolvedFontSize
        return max(extra, 0)
    }

    private var resolvedTextCaseTransform: TextCaseTransform {
        let textCase = PropertyResolver.resolve(props?.textCase, store: variableStore, default: "none")
        switch textCase {
        case "uppercase": return .uppercase
        case "lowercase": return .lowercase
        case "capitalize": return .capitalize
        default: return .none
        }
    }

    private var resolvedFrameAlignment: Alignment {
        let align = PropertyResolver.resolve(props?.textAlign, store: variableStore, default: "left")
        switch align {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private var resolvedFrameMaxWidth: CGFloat? {
        let align = PropertyResolver.resolve(props?.textAlign, store: variableStore, default: "left")

        if align == "center" || align == "right" {
            return .infinity
        }

        if let width = props?.width {
            switch width {
            case .fixed(_), .percent(_):
                return .infinity
            case .auto:
                break
            }
        }

        return nil
    }
}

// MARK: - Text Case Transform

enum TextCaseTransform {
    case none
    case uppercase
    case lowercase
    case capitalize
}

// MARK: - Text Effect Styling Modifier

/// Applies shared text styling (font, color, alignment, spacing, text case)
/// to any view produced by the text effect / text rotation paths.
///
/// This is necessary because text effect views output SwiftUI `Text` views
/// which need the same visual styling that `LineHeightText` provides via
/// UIKit attributed strings.
private struct TextEffectStylingModifier: ViewModifier {
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let fontFamily: String?
    let color: Color
    let alignment: TextAlignment
    let lineSpacing: CGFloat
    let letterSpacing: CGFloat
    let textCase: TextCaseTransform

    func body(content: Content) -> some View {
        content
            .font(resolvedFont)
            .foregroundColor(color)
            .multilineTextAlignment(alignment)
            .lineSpacing(lineSpacing)
            .applyLetterSpacing(letterSpacing)
            .textCaseModifier(textCase)
    }

    /// Resolves the SwiftUI font, preferring custom family when specified.
    /// Delegates to FontManager for centralized resolution of system and custom fonts.
    private var resolvedFont: Font {
        FontManager.resolveSwiftUIFont(family: fontFamily, weight: fontWeight, size: fontSize)
    }
}

/// Convenience extension to apply text case transformation as a SwiftUI modifier.
private extension View {
    @ViewBuilder
    func textCaseModifier(_ transform: TextCaseTransform) -> some View {
        switch transform {
        case .uppercase:
            self.textCase(.uppercase)
        case .lowercase:
            self.textCase(.lowercase)
        case .capitalize:
            // SwiftUI does not have a built-in capitalize text case;
            // capitalization is handled at the string level by the effect views.
            self
        case .none:
            self
        }
    }

    /// Applies letter spacing (kerning) with availability checks for macOS 12.
    @ViewBuilder
    func applyLetterSpacing(_ spacing: CGFloat) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.kerning(spacing)
        } else {
            // On older OS versions, kerning/tracking is not available as a
            // SwiftUI modifier. The letter spacing will be best-effort via
            // the font system. For most practical cases this is acceptable
            // since the primary rendering path uses NSAttributedString.
            self
        }
    }

    /// Applies text effect styling to the receiving view.
    func applyTextEffectStyling(
        fontSize: CGFloat,
        fontWeight: Font.Weight,
        fontFamily: String?,
        color: Color,
        alignment: TextAlignment,
        lineSpacing: CGFloat,
        letterSpacing: CGFloat,
        textCase: TextCaseTransform
    ) -> some View {
        self.modifier(TextEffectStylingModifier(
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontFamily: fontFamily,
            color: color,
            alignment: alignment,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing,
            textCase: textCase
        ))
    }
}

// MARK: - LineHeightText Platform Implementations

#if canImport(UIKit)
/// A UILabel wrapper that properly supports CSS-like lineHeight multiplier
/// This allows for line heights both above and below the default (including tight spacing with lineHeight: 1)
struct LineHeightText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let fontWeight: UIFont.Weight
    let fontFamily: String?
    let color: UIColor
    let alignment: NSTextAlignment
    let lineHeightMultiplier: CGFloat
    let letterSpacing: CGFloat
    let maxLines: Int
    let textCase: TextCaseTransform

    func makeUIView(context: Context) -> LineHeightLabel {
        let label = LineHeightLabel()
        label.numberOfLines = maxLines
        label.lineBreakMode = .byWordWrapping
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: LineHeightLabel, context: Context) {
        configureLabel(label)
    }

    /// Returns the content-hugging size for the text rather than accepting the
    /// full proposed width. This is critical for horizontal stacks with
    /// justify "right"/"center" — without this, the label greedily accepts all
    /// proposed horizontal space, making Spacer-free positioning impossible.
    ///
    /// The width returned is `min(textContentWidth, proposedWidth)`:
    /// - Short text ("Yes") returns ~30pt, not the full 271pt proposed.
    /// - Long text that needs wrapping returns the proposed width and the
    ///   correct wrapped height.
    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: LineHeightLabel, context: Context) -> CGSize {
        // Build the attributed string with current styling to measure
        configureLabel(label)

        guard let attrText = label.attributedText, attrText.length > 0 else {
            return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        }

        // Measure the single-line (unwrapped) text content width
        let singleLineRect = attrText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let contentWidth = ceil(singleLineRect.width)

        // Determine the width to measure against.
        // During live mirror updates (or any rapid layout invalidation), SwiftUI may
        // propose widths of 0 or nil during intermediate layout passes. If we naively
        // accept a tiny width, the text wraps character-by-character and produces the
        // wrong intrinsic height, which SwiftUI then commits to — causing severe
        // glitches (one char per line, one word per line).
        //
        // Strategy:
        // 1. If proposal.width is provided and reasonable, use it
        // 2. If proposal.width is nil or zero, prefer the label's last known layout
        //    width (from a previous successful layout pass)
        // 3. As a final fallback, use the full content width (no wrapping)
        let proposedWidth: CGFloat
        if let pw = proposal.width, pw > 0 {
            proposedWidth = pw
        } else if label.preferredMaxLayoutWidth > 0 {
            proposedWidth = label.preferredMaxLayoutWidth
        } else if label.bounds.width > 0 {
            proposedWidth = label.bounds.width
        } else {
            proposedWidth = contentWidth
        }

        // Use the smaller of content width and proposed width
        let resultWidth = min(contentWidth, proposedWidth)

        // Measure height at the result width (handles text wrapping)
        let wrappedRect = attrText.boundingRect(
            with: CGSize(width: resultWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        var resultHeight = ceil(wrappedRect.height)

        // For tight line heights, adjust height to match CSS line-height behavior
        if lineHeightMultiplier <= 1.0 {
            let font = Self.resolveFont(size: fontSize, weight: fontWeight, family: fontFamily)
            let lineCount = max(1, Int(ceil(wrappedRect.height / font.lineHeight)))
            let desiredHeight = font.pointSize * lineHeightMultiplier * CGFloat(lineCount)
            resultHeight = desiredHeight + (font.descender * -0.5)
        }

        // Cache the measured width so the label can use it as preferredMaxLayoutWidth
        // before layoutSubviews runs. This prevents the label from computing
        // intrinsicContentSize with a stale or zero preferredMaxLayoutWidth.
        if label.preferredMaxLayoutWidth != resultWidth && resultWidth > 0 {
            label.preferredMaxLayoutWidth = resultWidth
        }

        Logger.shared.debug("[LineHeightText] sizeThatFits: text='\(text.prefix(20))' proposedW=\(proposal.width.map{String(describing:$0)} ?? "nil") contentW=\(contentWidth) resultW=\(resultWidth) resultH=\(resultHeight)")

        return CGSize(width: resultWidth, height: resultHeight)
    }

    /// Configures the label with the current text, font, and paragraph style.
    /// Shared between `updateUIView` and `sizeThatFits` to ensure consistent measurement.
    private func configureLabel(_ label: LineHeightLabel) {
        let font = Self.resolveFont(size: fontSize, weight: fontWeight, family: fontFamily)

        // Apply text case transformation
        let displayText: String
        switch textCase {
        case .uppercase:
            displayText = text.uppercased()
        case .lowercase:
            displayText = text.lowercased()
        case .capitalize:
            displayText = text.capitalized
        case .none:
            displayText = text
        }

        // Calculate the desired line height
        // lineHeightMultiplier of 1.0 means line height equals font size (tight)
        // lineHeightMultiplier of 1.5 means line height is 1.5x the font size (loose)
        let desiredLineHeight = fontSize * lineHeightMultiplier

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byWordWrapping

        // Use lineSpacing to adjust the space between lines
        // For tight line heights (multiplier <= 1), we need negative spacing
        // to pull lines closer together
        let defaultLineHeight = font.lineHeight
        let lineSpacingAdjustment = desiredLineHeight - defaultLineHeight
        paragraphStyle.lineSpacing = max(lineSpacingAdjustment, -defaultLineHeight * 0.3)

        // For tight line heights, also set min/max to constrain the line box
        if lineHeightMultiplier < 1.2 {
            paragraphStyle.minimumLineHeight = desiredLineHeight
            paragraphStyle.maximumLineHeight = desiredLineHeight
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]

        // Apply letter spacing (kern) when non-zero
        if letterSpacing != 0 {
            attributes[.kern] = letterSpacing
        }

        let newAttributedString = NSAttributedString(string: displayText, attributes: attributes)

        // Skip redundant updates to avoid triggering unnecessary layout passes.
        // During live mirror, replaceFlow fires rapidly and causes the entire view
        // tree to re-evaluate. If the text, styling, and line count haven't changed,
        // setting attributedText again would cause the label to re-layout and
        // temporarily rewrap text at the wrong width.
        if let existing = label.lastConfiguredAttributedString,
           existing.isEqual(to: newAttributedString),
           label.numberOfLines == maxLines,
           label.lineHeightMultiplier == lineHeightMultiplier {
            return
        }

        label.attributedText = newAttributedString
        label.lastConfiguredAttributedString = newAttributedString
        label.numberOfLines = maxLines
        label.lineHeightMultiplier = lineHeightMultiplier
    }

    // MARK: - Font Resolution

    /// Resolves a UIFont from the given size, weight, and optional font family name.
    /// Delegates to FontManager for centralized resolution of system and custom fonts.
    private static func resolveFont(size: CGFloat, weight: UIFont.Weight, family: String?) -> UIFont {
        FontManager.resolveUIFont(family: family, weight: weight, size: size)
    }
}

/// Custom UILabel subclass that properly handles preferredMaxLayoutWidth for text wrapping
/// and adjusts intrinsic height based on lineHeightMultiplier
class LineHeightLabel: UILabel {
    var lineHeightMultiplier: CGFloat = 1.2

    /// Tracks the last configured attributed string to skip redundant updates
    /// during rapid live-mirror refreshes where the text hasn't actually changed.
    var lastConfiguredAttributedString: NSAttributedString?

    override func layoutSubviews() {
        super.layoutSubviews()
        // Set preferredMaxLayoutWidth to the actual width so text wraps correctly
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            setNeedsUpdateConstraints()
        }
    }

    override var intrinsicContentSize: CGSize {
        // Height: use the wrapped height at preferredMaxLayoutWidth when available.
        var size: CGSize
        if preferredMaxLayoutWidth > 0 {
            size = sizeThatFits(CGSize(width: preferredMaxLayoutWidth, height: .greatestFiniteMagnitude))
        } else {
            size = super.intrinsicContentSize
        }

        let superIntrinsic = super.intrinsicContentSize

        // For tight line heights, reduce the intrinsic height to remove extra padding
        // The label's natural size includes padding based on font metrics,
        // but we want to constrain it to match the CSS line-height behavior
        if lineHeightMultiplier <= 1.0, let font = self.font {
            let lineCount = max(1, Int(ceil(size.height / font.lineHeight)))
            let desiredHeight = font.pointSize * lineHeightMultiplier * CGFloat(lineCount)
            // Add a small buffer for descenders
            size.height = desiredHeight + (font.descender * -0.5)
        }

        // Width: compute the actual text content width rather than returning
        // UIView.noIntrinsicMetric or the constraint width from sizeThatFits.
        //
        // sizeThatFits returns the constraint width (not content width), so we
        // cannot use size.width directly. Instead, measure the attributed text's
        // bounding rect to get the true content width.
        //
        // This is critical for HStack justify "right"/"center" layouts: without a
        // proper intrinsic width, the label greedily accepts all proposed horizontal
        // space, preventing Spacers from pushing content to the right/center.
        //
        // When preferredMaxLayoutWidth is set and text wraps, cap the width at
        // preferredMaxLayoutWidth so the label doesn't report a wider-than-available
        // intrinsic size. Parent containers that need the label to fill available
        // width (e.g., cross-axis stretch, center/right text alignment) apply
        // .frame(maxWidth: .infinity) which overrides this intrinsic size.
        let contentWidth: CGFloat
        if let attrText = attributedText, attrText.length > 0 {
            let maxLayoutWidth = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : CGFloat.greatestFiniteMagnitude
            let boundingRect = attrText.boundingRect(
                with: CGSize(width: maxLayoutWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            contentWidth = ceil(boundingRect.width)
        } else {
            contentWidth = UIView.noIntrinsicMetric
        }

        let textPreview = (attributedText?.string ?? text ?? "").prefix(20)
        Logger.shared.debug("[LineHeightLabel] intrinsicContentSize: text='\(textPreview)' preferredMaxLayoutWidth=\(preferredMaxLayoutWidth) bounds=\(bounds.width)x\(bounds.height) sizeThatFitsW=\(size.width) superIntrinsicW=\(superIntrinsic.width) boundingRectW=\(contentWidth) resultW=\(contentWidth) resultH=\(size.height)")

        return CGSize(width: contentWidth, height: size.height)
    }
}

#elseif canImport(AppKit)
/// An NSTextField wrapper that properly supports CSS-like lineHeight multiplier for macOS
struct LineHeightText: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let fontWeight: NSFont.Weight
    let fontFamily: String?
    let color: NSColor
    let alignment: NSTextAlignment
    let lineHeightMultiplier: CGFloat
    let letterSpacing: CGFloat
    let maxLines: Int
    let textCase: TextCaseTransform

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(labelWithString: "")
        textField.isEditable = false
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.lineBreakMode = maxLines == 1 ? .byTruncatingTail : .byWordWrapping
        textField.maximumNumberOfLines = maxLines
        textField.setContentHuggingPriority(.required, for: .vertical)
        textField.setContentCompressionResistancePriority(.required, for: .vertical)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        let font = Self.resolveFont(size: fontSize, weight: fontWeight, family: fontFamily)

        // Apply text case transformation
        let displayText: String
        switch textCase {
        case .uppercase:
            displayText = text.uppercased()
        case .lowercase:
            displayText = text.lowercased()
        case .capitalize:
            displayText = text.capitalized
        case .none:
            displayText = text
        }

        // Calculate the line height based on multiplier
        let lineHeight = fontSize * lineHeightMultiplier

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight

        // Center the text vertically within the line height
        let baselineOffset = (lineHeight - font.ascender + font.descender) / 4

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
            .baselineOffset: baselineOffset
        ]

        // Apply letter spacing (kern) when non-zero
        if letterSpacing != 0 {
            attributes[.kern] = letterSpacing
        }

        textField.attributedStringValue = NSAttributedString(string: displayText, attributes: attributes)
        textField.maximumNumberOfLines = maxLines
    }

    // MARK: - Font Resolution

    /// Resolves an NSFont from the given size, weight, and optional font family name.
    /// Delegates to FontManager for centralized resolution of system and custom fonts.
    private static func resolveFont(size: CGFloat, weight: NSFont.Weight, family: String?) -> NSFont {
        FontManager.resolveNSFont(family: family, weight: weight, size: size)
    }
}
#endif

// MARK: - Button View

/// Renders a button component
struct ButtonView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let mediaBaseUrl: String?
    let iconBaseUrl: String?
    var renderTrigger: Int = 0

    @Environment(\.flowGlobalStyles) private var flowGlobalStyles

    private var props: ComponentProps? { node.props }

    // Button shares stack's style surface (overhaul §2.2): the box-model
    // (padding / background / border / cornerRadius / width / opacity) is owned
    // by `UniversalStyleModifier`, with variant background/border injected into
    // its props by `ComponentRenderer.universalStyleProps`. This view renders
    // only the content (children, text, or icon) and resolves the variant text
    // color.
    var body: some View {
        // Force re-evaluation when renderTrigger changes
        let _ = renderTrigger
        let variantColors = resolveButtonVariant(resolvedVariant, globalStyles: flowGlobalStyles)
        let textHex = resolvedTextColorHex(variantColors: variantColors)

        HStack(spacing: resolvedSpacing) {
            if let children = node.children, !children.isEmpty {
                // Button-as-container: when an icon + label are present they live
                // as `icon`/`text` children (the `text`/`iconSize` props are
                // ignored), so render them via ComponentRenderer like a stack.
                // Mirrors the dashboard + Expo button renderers so the icon
                // shows on every layer.
                ForEach(children.indices, id: \.self) { index in
                    ComponentRenderer(
                        node: children[index],
                        variableStore: variableStore,
                        actionExecutor: actionExecutor,
                        actionContext: actionContext,
                        mediaBaseUrl: mediaBaseUrl,
                        iconBaseUrl: iconBaseUrl,
                        renderTrigger: renderTrigger
                    )
                }
            } else if let iconSize = PropertyResolver.resolve(props?.iconSize, store: variableStore) {
                // Check for back/close button (render icon only).
                // Default to ChevronLeft so the back-button preset (which sets
                // iconSize but no iconName) keeps rendering a chevron. Buttons
                // that set iconName get whatever Lucide glyph they asked for.
                LucideIcon(
                    name: resolvedIconName,
                    size: CGFloat(iconSize),
                    colorHex: textHex,
                    strokeWidth: 2.0,
                    iconBaseUrl: iconBaseUrl
                )
                .frame(width: CGFloat(iconSize), height: CGFloat(iconSize))
            } else {
                // Regular text button
                Text(resolvedText)
                    .font(resolvedFont)
                    .foregroundColor(Color(hex: textHex) ?? .primary)
            }
        }
        // No width frame here: the universal style pass owns sizing. A
        // width: 100% button gets `.frame(width: .infinity)` upstream and
        // centers this content; an auto-width button hugs its content.
    }

    // MARK: - Property Resolution

    private var resolvedText: String {
        PropertyResolver.resolveString(props?.text, store: variableStore, default: "Button")
    }

    private var resolvedIconName: String {
        PropertyResolver.resolve(props?.iconName, store: variableStore, default: "ChevronLeft")
    }

    private var resolvedSpacing: CGFloat {
        CGFloat(PropertyResolver.resolve(props?.spacing, store: variableStore, default: 8.0))
    }

    private var resolvedFont: Font {
        let size = PropertyResolver.resolve(props?.fontSize, store: variableStore, default: 16.0)
        let weight = PropertyResolver.resolve(props?.fontWeight, store: variableStore, default: "600")
        let family: String? = PropertyResolver.resolve(props?.fontFamily, store: variableStore)
        let fontWeight = FontManager.swiftUIWeight(from: weight)
        return FontManager.resolveSwiftUIFont(family: family, weight: fontWeight, size: CGFloat(size))
    }

    private var resolvedVariant: ButtonVariant {
        ButtonVariant.from(PropertyResolver.resolve(props?.variant, store: variableStore))
    }

    private func resolvedTextColorHex(variantColors: ResolvedButtonVariant) -> String {
        PropertyResolver.resolve(props?.color, store: variableStore) ?? variantColors.textHex
    }

}
