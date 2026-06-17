import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit

// MARK: - Lucide SVG Renderer

/// Pure-Swift renderer for Lucide-style SVG icons. Replaces the previous
/// implementation that called Apple's private `CGSVGDocument*` API via
/// `dlopen` / `dlsym` (App Store rejection risk).
///
/// Scope:
/// - Targets the Lucide icon set's conventions: `viewBox 0 0 24 24`,
///   `fill="none" stroke="currentColor" stroke-width="2"` defaults on the root
///   `<svg>` element, `stroke-linecap="round" stroke-linejoin="round"`, and
///   `<path>` / `<line>` / `<circle>` / `<rect>` / `<ellipse>` / `<polyline>` /
///   `<polygon>` children.
/// - Resolves `currentColor` to the runtime color at draw time. The
///   runtime-supplied stroke-width overrides the SVG's declared value.
/// - Honours per-shape `fill` / `stroke` / `stroke-width` overrides where
///   present, so non-Lucide SVGs hosted on the same icon CDN still render.
///
/// Public surface is a single static `render` function. Results are intended to
/// be cached by the caller (see `SVGIconLoader` in `ImageView.swift`).
enum LucideSVGRenderer {

    /// Renders an SVG icon to a `UIImage`.
    ///
    /// - Parameters:
    ///   - svgData: Raw bytes of an SVG document.
    ///   - targetSize: Output bitmap size in points. Screen-scale aware.
    ///   - colorHex: The colour to substitute for `currentColor` and to apply
    ///     to any shape whose `fill` / `stroke` resolves to it. CSS hex strings
    ///     (`#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`) are supported. Defaults to
    ///     opaque black on parse failure.
    ///   - strokeWidth: The stroke width to apply, in viewBox units. Overrides
    ///     any `stroke-width` declared on the root `<svg>` element. Per-shape
    ///     overrides still win when present (they describe geometry, not theme).
    /// - Returns: A rendered `UIImage`, or `nil` if the SVG could not be parsed.
    static func render(svgData: Data, targetSize: CGSize, colorHex: String, strokeWidth: CGFloat) -> UIImage? {
        guard let document = SVGDocumentParser.parse(data: svgData) else { return nil }
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }

        let runtimeColor = LucideSVGRenderer.color(fromHex: colorHex) ?? UIColor.black

        let viewBox = document.viewBox
        let viewBoxWidth = max(viewBox.width, 1)
        let viewBoxHeight = max(viewBox.height, 1)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        return renderer.image { context in
            let cg = context.cgContext

            // Letterbox the viewBox into the target rect, preserving aspect ratio.
            let scale = min(targetSize.width / viewBoxWidth, targetSize.height / viewBoxHeight)
            let xOffset = (targetSize.width - viewBoxWidth * scale) / 2
            let yOffset = (targetSize.height - viewBoxHeight * scale) / 2

            cg.translateBy(x: xOffset, y: yOffset)
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -viewBox.origin.x, y: -viewBox.origin.y)

            for shape in document.shapes {
                LucideSVGRenderer.draw(shape, in: cg, runtimeColor: runtimeColor,
                                       runtimeStrokeWidth: strokeWidth,
                                       svgDefaults: document.defaults)
            }
        }
    }

    private static func draw(_ shape: SVGShape, in context: CGContext,
                             runtimeColor: UIColor, runtimeStrokeWidth: CGFloat,
                             svgDefaults: SVGShapeAttributes) {
        // For fill/stroke/lineCap/lineJoin/fillRule we want full inheritance:
        // attributes declared on the root <svg> element (e.g.
        // `stroke="currentColor"`, `stroke-linecap="round"`) apply to children
        // that don't override them. `shape.attributes` is already merged with
        // any enclosing <g> group's attributes (at parse time); merging once
        // more with `svgDefaults` here closes the inheritance chain.
        let merged = shape.attributes.merged(over: svgDefaults)

        let fillColor = merged.fill.resolve(runtimeColor: runtimeColor)
        let strokeColor = merged.stroke.resolve(runtimeColor: runtimeColor)

        // Stroke-width is different: the root <svg>'s `stroke-width` is a
        // *theme default* the runtime caller wants to override. Only an
        // explicit override on this shape (or an enclosing <g>) is geometric
        // and survives runtime override. `shape.attributes.strokeWidth` is
        // already merged with group ancestors but NOT with `svgDefaults` (see
        // SVGDocumentParser.appendShape), so a nil here means "no geometric
        // declaration anywhere in this shape's ancestry, fall through to the
        // caller's runtime value."
        let strokeWidth: CGFloat = shape.attributes.strokeWidth ?? runtimeStrokeWidth

        let lineCap = merged.lineCap ?? .round
        let lineJoin = merged.lineJoin ?? .round
        let fillRule: CGPathFillRule = (merged.fillRule == .evenOdd) ? .evenOdd : .winding

        let hasFill = (fillColor != nil)
        let hasStroke = (strokeColor != nil) && strokeWidth > 0

        guard hasFill || hasStroke else { return }

        context.saveGState()
        defer { context.restoreGState() }

        if let strokeColor {
            context.setStrokeColor(strokeColor.cgColor)
            context.setLineWidth(strokeWidth)
            context.setLineCap(lineCap)
            context.setLineJoin(lineJoin)
        }
        if let fillColor {
            context.setFillColor(fillColor.cgColor)
        }

        context.addPath(shape.path)

        if hasFill && hasStroke {
            // Drawing modes that combine fill + stroke do not support the
            // even-odd rule directly; manually fill first, then stroke.
            context.saveGState()
            context.addPath(shape.path)
            context.fillPath(using: fillRule)
            context.restoreGState()

            context.addPath(shape.path)
            context.strokePath()
        } else if hasFill {
            context.fillPath(using: fillRule)
        } else {
            context.strokePath()
        }
    }

    // MARK: - Hex Colour Parsing (UIKit-only)

    /// Parses CSS-style hex colour strings the SDK's flow JSON commonly emits.
    /// Mirrors the SwiftUI `Color(hex:)` extension in `StyleModifiers.swift`
    /// but returns `UIColor` so `CGContext` calls don't need a SwiftUI
    /// environment to resolve.
    static func color(fromHex hex: String) -> UIColor? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var sanitized = trimmed
        if sanitized.hasPrefix("#") { sanitized.removeFirst() }

        // Expand shorthand: #RGB -> #RRGGBB, #RGBA -> #RRGGBBAA.
        if sanitized.count == 3 || sanitized.count == 4 {
            sanitized = sanitized.map { "\($0)\($0)" }.joined()
        }

        guard sanitized.count == 6 || sanitized.count == 8 else { return nil }

        var rgb: UInt64 = 0
        guard Scanner(string: sanitized).scanHexInt64(&rgb) else { return nil }

        let r, g, b: CGFloat
        var a: CGFloat = 1.0
        if sanitized.count == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
        } else {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        }
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}

#endif // canImport(UIKit)

// MARK: - SVG Document Model

struct SVGDocument {
    let viewBox: CGRect
    let defaults: SVGShapeAttributes
    let shapes: [SVGShape]
}

struct SVGShape {
    let path: CGPath
    let attributes: SVGShapeAttributes
}

/// Per-shape (and SVG-root-element-level) drawing attributes. `nil` fields
/// mean "inherit from parent / SVG defaults / spec defaults."
struct SVGShapeAttributes {
    var fill: SVGPaint = .inherit
    var stroke: SVGPaint = .inherit
    var strokeWidth: CGFloat? = nil
    var lineCap: CGLineCap? = nil
    var lineJoin: CGLineJoin? = nil
    var fillRule: CGPathFillRule? = nil

    /// Returns a new `SVGShapeAttributes` where any field that is `inherit` /
    /// `nil` on `self` takes its value from `parent`. Use to merge an SVG-root
    /// default set under a per-shape override set.
    func merged(over parent: SVGShapeAttributes) -> SVGShapeAttributes {
        var out = self
        if case .inherit = out.fill { out.fill = parent.fill }
        if case .inherit = out.stroke { out.stroke = parent.stroke }
        if out.strokeWidth == nil { out.strokeWidth = parent.strokeWidth }
        if out.lineCap == nil { out.lineCap = parent.lineCap }
        if out.lineJoin == nil { out.lineJoin = parent.lineJoin }
        if out.fillRule == nil { out.fillRule = parent.fillRule }
        return out
    }
}

/// Encodes the SVG paint-resolution states this renderer needs:
/// - `none`: explicit no paint
/// - `currentColor`: resolve to the runtime colour at draw time
/// - `explicitHex`: a specific colour string parsed at draw time
/// - `inherit`: not specified on this shape; defer to the SVG-root default
enum SVGPaint {
    case none
    case currentColor
    case explicitHex(String)
    case inherit

    static func parse(_ value: String) -> SVGPaint {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "none": return .none
        case "currentcolor": return .currentColor
        default: return .explicitHex(trimmed)
        }
    }

    #if canImport(UIKit)
    /// Resolves this paint to a concrete `UIColor`, or `nil` if the paint is
    /// `none` (no draw). An `inherit` that wasn't merged away resolves to
    /// `nil` defensively — caller should never see one after `merged(over:)`.
    func resolve(runtimeColor: UIColor) -> UIColor? {
        switch self {
        case .none, .inherit:
            return nil
        case .currentColor:
            return runtimeColor
        case .explicitHex(let hex):
            return LucideSVGRenderer.color(fromHex: hex)
        }
    }
    #endif
}

// MARK: - SVG XML Parser

/// `XMLParser`-based delegate that builds an `SVGDocument` from raw bytes.
///
/// Only the elements + attributes relevant to flat icon SVGs are handled:
/// `<svg>` (root), `<path d>`, `<line>`, `<circle>`, `<rect>`, `<ellipse>`,
/// `<polyline>`, `<polygon>`, and `<g>` (for inheritance — but no transform
/// support, since Lucide icons don't use one).
final class SVGDocumentParser: NSObject, XMLParserDelegate {

    private var viewBox: CGRect = CGRect(x: 0, y: 0, width: 24, height: 24)
    private var rootDefaults = SVGShapeAttributes()
    private var groupStack: [SVGShapeAttributes] = []
    private var shapes: [SVGShape] = []
    private var didEncounterRoot = false

    static func parse(data: Data) -> SVGDocument? {
        let parser = XMLParser(data: data)
        let delegate = SVGDocumentParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        guard delegate.didEncounterRoot else { return nil }
        return SVGDocument(viewBox: delegate.viewBox,
                           defaults: delegate.rootDefaults,
                           shapes: delegate.shapes)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()

        switch name {
        case "svg":
            didEncounterRoot = true
            viewBox = SVGDocumentParser.parseViewBox(attributeDict) ?? viewBox
            rootDefaults = SVGDocumentParser.parseAttributes(attributeDict)
            // Provide spec defaults that Lucide relies on but doesn't always
            // declare explicitly. These are overwritten if the SVG does set them.
            if case .inherit = rootDefaults.fill { rootDefaults.fill = .none }
            if case .inherit = rootDefaults.stroke { rootDefaults.stroke = .currentColor }
            if rootDefaults.lineCap == nil { rootDefaults.lineCap = .round }
            if rootDefaults.lineJoin == nil { rootDefaults.lineJoin = .round }

        case "g":
            // Inherit from the enclosing group (if any) but NOT from the SVG
            // root's defaults. Root defaults are applied at draw time so the
            // renderer can distinguish "root theme default" (runtime-
            // overridable) from "explicitly declared on shape or group"
            // (geometric, runtime-immutable).
            let parsed = SVGDocumentParser.parseAttributes(attributeDict)
            let groupAttrs: SVGShapeAttributes
            if let parentGroup = groupStack.last {
                groupAttrs = parsed.merged(over: parentGroup)
            } else {
                groupAttrs = parsed
            }
            groupStack.append(groupAttrs)

        case "path":
            guard let d = attributeDict["d"], !d.isEmpty else { return }
            let path = SVGPathDataParser.parse(d)
            appendShape(path: path, rawAttributes: attributeDict)

        case "line":
            guard
                let x1 = attributeDict["x1"].flatMap(Double.init),
                let y1 = attributeDict["y1"].flatMap(Double.init),
                let x2 = attributeDict["x2"].flatMap(Double.init),
                let y2 = attributeDict["y2"].flatMap(Double.init)
            else { return }
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x2, y: y2))
            appendShape(path: p, rawAttributes: attributeDict)

        case "circle":
            guard
                let cx = attributeDict["cx"].flatMap(Double.init),
                let cy = attributeDict["cy"].flatMap(Double.init),
                let r = attributeDict["r"].flatMap(Double.init), r > 0
            else { return }
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            appendShape(path: p, rawAttributes: attributeDict)

        case "ellipse":
            guard
                let cx = attributeDict["cx"].flatMap(Double.init),
                let cy = attributeDict["cy"].flatMap(Double.init),
                let rx = attributeDict["rx"].flatMap(Double.init), rx > 0,
                let ry = attributeDict["ry"].flatMap(Double.init), ry > 0
            else { return }
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
            appendShape(path: p, rawAttributes: attributeDict)

        case "rect":
            let x = attributeDict["x"].flatMap(Double.init) ?? 0
            let y = attributeDict["y"].flatMap(Double.init) ?? 0
            guard
                let w = attributeDict["width"].flatMap(Double.init), w > 0,
                let h = attributeDict["height"].flatMap(Double.init), h > 0
            else { return }
            let rx = attributeDict["rx"].flatMap(Double.init) ?? 0
            let ry = attributeDict["ry"].flatMap(Double.init) ?? rx
            let p = CGMutablePath()
            if rx > 0 || ry > 0 {
                // Clamp per SVG spec: a corner radius greater than half the
                // side collapses to the side length itself.
                let effRx = min(rx, w / 2)
                let effRy = min(ry, h / 2)
                p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h),
                                 cornerWidth: effRx, cornerHeight: effRy)
            } else {
                p.addRect(CGRect(x: x, y: y, width: w, height: h))
            }
            appendShape(path: p, rawAttributes: attributeDict)

        case "polyline", "polygon":
            guard let points = attributeDict["points"] else { return }
            let p = CGMutablePath()
            var scanner = SVGNumberScanner(points)
            var first = true
            while let x = scanner.scanNumber(), let y = scanner.scanNumber() {
                let pt = CGPoint(x: x, y: y)
                if first {
                    p.move(to: pt)
                    first = false
                } else {
                    p.addLine(to: pt)
                }
            }
            if name == "polygon" { p.closeSubpath() }
            appendShape(path: p, rawAttributes: attributeDict)

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "g" && !groupStack.isEmpty {
            groupStack.removeLast()
        }
    }

    // MARK: - Helpers

    private func appendShape(path: CGPath, rawAttributes: [String: String]) {
        // Merge with the enclosing <g> group's attributes (if any), but NOT
        // with the root <svg> defaults. Root inheritance is the renderer's
        // responsibility — see `LucideSVGRenderer.draw` for the reasoning.
        let parsed = SVGDocumentParser.parseAttributes(rawAttributes)
        let attrs: SVGShapeAttributes
        if let parentGroup = groupStack.last {
            attrs = parsed.merged(over: parentGroup)
        } else {
            attrs = parsed
        }
        shapes.append(SVGShape(path: path, attributes: attrs))
    }

    /// Parses `viewBox="minX minY width height"` per SVG 1.1 §7.7.
    private static func parseViewBox(_ attributes: [String: String]) -> CGRect? {
        guard let raw = attributes["viewBox"] ?? attributes["viewbox"] else { return nil }
        var scanner = SVGNumberScanner(raw)
        guard let x = scanner.scanNumber(),
              let y = scanner.scanNumber(),
              let w = scanner.scanNumber(),
              let h = scanner.scanNumber(),
              w > 0, h > 0
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func parseAttributes(_ raw: [String: String]) -> SVGShapeAttributes {
        var attrs = SVGShapeAttributes()
        if let f = raw["fill"] { attrs.fill = SVGPaint.parse(f) }
        if let s = raw["stroke"] { attrs.stroke = SVGPaint.parse(s) }
        if let sw = raw["stroke-width"].flatMap(Double.init) { attrs.strokeWidth = CGFloat(sw) }
        if let lc = raw["stroke-linecap"] { attrs.lineCap = parseLineCap(lc) }
        if let lj = raw["stroke-linejoin"] { attrs.lineJoin = parseLineJoin(lj) }
        if let fr = raw["fill-rule"]?.lowercased() {
            attrs.fillRule = (fr == "evenodd") ? .evenOdd : .winding
        }
        return attrs
    }

    private static func parseLineCap(_ s: String) -> CGLineCap? {
        switch s.lowercased() {
        case "butt": return .butt
        case "round": return .round
        case "square": return .square
        default: return nil
        }
    }

    private static func parseLineJoin(_ s: String) -> CGLineJoin? {
        switch s.lowercased() {
        case "miter", "miter-clip": return .miter
        case "round", "arcs": return .round
        case "bevel": return .bevel
        default: return nil
        }
    }
}
