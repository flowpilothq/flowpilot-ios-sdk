import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Image View

/// Renders an image component with caching support
struct ImageView: View {
    let props: ComponentProps?
    let variableStore: VariableStore
    let mediaBaseUrl: String?

    /// Use cached images (preloaded content will show instantly)
    private let imageCache = ImageCache.shared

    /// Measured size of the nearest ancestor stack, injected via
    /// `injectParentSize()`. Used to resolve non-100% percentage width/height
    /// (e.g. `height: "58%"`) the same way `UniversalStyleModifier` does, so an
    /// image honours percentage sizing like the editor canvas + Expo SDK.
    /// Requires the image's parent to have a definite (non-auto) height.
    @Environment(\.parentSize) private var parentSize

    /// Unique identifier for this image based on resolved URL
    private var imageIdentifier: String {
        resolvedURL?.absoluteString ?? UUID().uuidString
    }

    /// Check if this is an SVG file
    private var isSVG: Bool {
        guard let url = resolvedURL else { return false }
        return url.pathExtension.lowercased() == "svg"
    }

    var body: some View {
        Group {
            if isSVG {
                // For SVG files, use AsyncImage which has better SVG support on iOS 16+
                // or show a placeholder for older iOS versions
                if #available(iOS 16.0, *) {
                    AsyncImage(url: resolvedURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .success(let image):
                            styledImage(image.renderingMode(.original))
                        case .failure:
                            Image(systemName: "photo")
                                .foregroundColor(.gray)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    // Fallback for older iOS - SVG not fully supported
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Standard image formats (PNG, JPEG, etc.)
                CachedAsyncImageWithPhase(url: resolvedURL, cache: imageCache) { phase in
                    switch phase {
                    case .empty:
                        // Only show loading if not cached
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                    case .success(let image):
                        styledImage(
                            // Use original rendering mode to preserve transparency and colors
                            image.renderingMode(.original)
                        )
                        .clipped()

                    case .failure:
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(width: resolvedWidth, height: resolvedHeight)
        .accessibilityLabel(resolvedAlt)
        // Use unique ID to prevent SwiftUI from reusing views with wrong images
        .id(imageIdentifier)
    }

    // MARK: - Image Styling

    /// Applies `.resizable()` to the image and conditionally applies `.aspectRatio(contentMode:)`.
    /// When the fit mode is `"fill"` (CSS `object-fit: fill`), the aspect ratio modifier is
    /// omitted so that the image stretches to the frame dimensions without preserving its
    /// natural aspect ratio.
    ///
    /// When `tintColor` is set in the component props, a color overlay with `.multiply` blend
    /// mode is applied on top of the image to replicate the editor's `mix-blend-mode: multiply`
    /// tint behaviour.
    @ViewBuilder
    private func styledImage(_ image: Image) -> some View {
        if let mode = resolvedContentMode {
            image
                .resizable()
                .aspectRatio(contentMode: mode)
                .tintOverlay(resolvedTintColor)
        } else {
            image
                .resizable()
                .tintOverlay(resolvedTintColor)
        }
    }

    // MARK: - Property Resolution

    private var resolvedURL: URL? {
        // Resolve through the shared resolver so the render-time cache key is
        // identical to the key the offline asset seeder writes (see
        // `MediaURLResolver` / `BundledAssetSeeder`).
        let src = PropertyResolver.resolveString(props?.src, store: variableStore)
        return MediaURLResolver.resolve(src: src, mediaBaseUrl: mediaBaseUrl)
    }

    /// Returns the SwiftUI `ContentMode` for the resolved fit mode, or `nil` when the image
    /// should stretch to fill the container without preserving its aspect ratio (CSS `object-fit: fill`).
    private var resolvedContentMode: ContentMode? {
        let fit = PropertyResolver.resolve(props?.fit, store: variableStore, default: "cover")
        switch fit {
        case "contain":   return .fit
        case "cover":     return .fill
        case "fill":      return nil   // stretch without preserving aspect ratio
        case "none":      return .fit
        case "scale-down": return .fit
        default:          return .fill
        }
    }

    private var resolvedAlt: String {
        PropertyResolver.resolveString(props?.alt, store: variableStore, default: "Image")
    }

    /// Resolves the optional tint color from component props.
    /// Returns a `Color` when a valid, non-empty tint color string is specified, or `nil` otherwise.
    private var resolvedTintColor: Color? {
        guard let tintColorStr = PropertyResolver.resolveString(props?.tintColor, store: variableStore),
              !tintColorStr.isEmpty else {
            return nil
        }
        return Color(hex: tintColorStr)
    }

    /// Base size for resolving non-100% percentages. Prefers the measured
    /// `parentSize` (so behaviour matches the editor/Expo "% of parent" when the
    /// parent has a definite size, preserving parity). When a dimension hasn't
    /// been measured (0 — e.g. the screen is in a ScrollView, which proposes
    /// unbounded height so the parent never resolves), it falls back to the
    /// device screen so a `%` image is sized sensibly instead of collapsing to 0
    /// or inflating to its intrinsic size.
    private var percentBaseSize: CGSize {
        #if canImport(UIKit)
        let screen = UIScreen.main.bounds.size
        #else
        let screen = CGSize.zero
        #endif
        return CGSize(
            width: parentSize.width > 0 ? parentSize.width : screen.width,
            height: parentSize.height > 0 ? parentSize.height : screen.height
        )
    }

    private var resolvedWidth: CGFloat? {
        guard let width = props?.width else { return nil }
        switch width {
        case .fixed(let value):
            return CGFloat(value)
        case .percent(100):
            return .infinity
        case .percent(let value):
            let base = percentBaseSize.width
            guard base > 0 else { return nil }
            return base * CGFloat(value) / 100
        case .auto:
            return nil
        }
    }

    private var resolvedHeight: CGFloat? {
        guard let height = props?.height else { return nil }
        switch height {
        case .fixed(let value):
            return CGFloat(value)
        case .percent(100):
            return .infinity
        case .percent(let value):
            let base = percentBaseSize.height
            guard base > 0 else { return nil }
            return base * CGFloat(value) / 100
        case .auto:
            return nil
        }
    }
}

// MARK: - Tint Overlay Modifier

private extension View {
    /// Applies a color overlay with `.multiply` blend mode when a tint color is provided.
    /// This replicates the editor's `mix-blend-mode: multiply` tint overlay behaviour.
    @ViewBuilder
    func tintOverlay(_ color: Color?) -> some View {
        if let color {
            self.overlay(color.blendMode(.multiply))
        } else {
            self
        }
    }
}

// MARK: - Icon View

/// Renders an icon component by loading Lucide SVG icons from the CDN.
///
/// The editor stores icon names as PascalCase Lucide names (e.g. "Star", "ChevronRight").
/// The CDN hosts matching SVGs at `{iconBaseUrl}/{IconName}.svg`.
///
/// When `iconBaseUrl` is nil (e.g. persistent zones or local preview), falls back to
/// a small SF Symbol mapping for the most common icons.
struct IconView: View {
    let props: ComponentProps?
    let variableStore: VariableStore
    let iconBaseUrl: String?
    var renderTrigger: Int = 0

    // MARK: - Resolved props

    private var resolvedIconName: String {
        PropertyResolver.resolve(props?.iconName, store: variableStore, default: "Star")
    }

    private var resolvedSize: CGFloat {
        // Mirror the editor canvas (`IconRenderer` in simple-renderers.tsx):
        // the displayed glyph size is derived from the Size-section width/height
        // (the smaller dimension, to stay proportional). Resizing an icon in the
        // editor writes `width`/`height`, NOT the `size` prop, so those must take
        // priority — otherwise a resized icon renders at the default `size` and
        // gets centered inside a larger style frame with whitespace around it.
        let fixedWidth = fixedDimension(props?.width)
        let fixedHeight = fixedDimension(props?.height)
        if let fixedWidth, let fixedHeight { return CGFloat(min(fixedWidth, fixedHeight)) }
        if let fixedWidth { return CGFloat(fixedWidth) }
        if let fixedHeight { return CGFloat(fixedHeight) }

        // No explicit dimensions: fall back to the `size` prop. Presets that set
        // `size` without width/height (e.g. checkbox glyphs, hero icons) rely on
        // this path.
        if let sizeVal = PropertyResolver.resolve(props?.iconComponentSize, store: variableStore) as Double?, sizeVal > 0 {
            return CGFloat(sizeVal)
        }
        return 24
    }

    /// Returns a positive fixed-point dimension value, or `nil` for `auto`,
    /// percentage, or non-positive values (which don't define a concrete glyph size).
    private func fixedDimension(_ dimension: DimensionValue?) -> Double? {
        guard let dimension, case .fixed(let value) = dimension, value > 0 else { return nil }
        return value
    }

    private var resolvedColorHex: String {
        let colorStr = PropertyResolver.resolve(props?.color, store: variableStore)
        if let colorStr = colorStr, colorStr != "currentColor", !colorStr.isEmpty {
            return colorStr
        }
        return "#000000"
    }

    private var resolvedStrokeWidth: Double {
        PropertyResolver.resolve(props?.strokeWidth, store: variableStore, default: 2.0)
    }

    // MARK: - Body

    var body: some View {
        // Force re-evaluation when renderTrigger changes (variable updates
        // re-resolve the conditional iconName, e.g. checkbox checked/unchecked).
        let _ = renderTrigger
        return LucideIcon(
            name: resolvedIconName,
            size: resolvedSize,
            colorHex: resolvedColorHex,
            strokeWidth: resolvedStrokeWidth,
            iconBaseUrl: iconBaseUrl
        )
        .frame(width: resolvedSize, height: resolvedSize)
    }
}

// MARK: - Lucide Icon (reusable)

/// Reusable Lucide-icon renderer that any component can embed (Icon, Button, etc.).
/// Resolves to a CDN-fetched SVG when an `iconBaseUrl` is provided, otherwise falls
/// back to a small SF Symbol mapping so previews and persistent zones still render.
struct LucideIcon: View {
    let name: String
    let size: CGFloat
    let colorHex: String
    let strokeWidth: Double
    let iconBaseUrl: String?

    private var iconURL: URL? {
        guard let base = iconBaseUrl else { return nil }
        let urlString = base.hasSuffix("/") ? "\(base)\(name).svg" : "\(base)/\(name).svg"
        return URL(string: urlString)
    }

    var body: some View {
        if let url = iconURL {
            SVGIconView(url: url, size: size, colorHex: colorHex, strokeWidth: strokeWidth)
        } else {
            sfSymbolFallback
        }
    }

    @ViewBuilder
    private var sfSymbolFallback: some View {
        let sfName = Self.sfSymbolMapping[name] ?? "star.fill"
        Image(systemName: sfName)
            .font(.system(size: size, weight: Self.mapStrokeWidthToFontWeight(strokeWidth)))
            .foregroundColor(Color(hex: colorHex) ?? .primary)
    }

    private static func mapStrokeWidthToFontWeight(_ strokeWidth: Double) -> Font.Weight {
        switch strokeWidth {
        case ...1.0:   return .ultraLight
        case ...1.25:  return .thin
        case ...1.5:   return .light
        case ...2.0:   return .regular
        case ...2.5:   return .medium
        case ...3.0:   return .semibold
        default:       return .bold
        }
    }

    // SF Symbol mapping kept tight: only Lucide names with an obvious SF analogue.
    // Anything outside this set falls through to `star.fill` when offline.
    private static let sfSymbolMapping: [String: String] = [
        "Star": "star.fill",
        "Heart": "heart.fill",
        "Check": "checkmark",
        "CheckCircle": "checkmark.circle.fill",
        "X": "xmark",
        "XCircle": "xmark.circle.fill",
        "ChevronLeft": "chevron.left",
        "ChevronRight": "chevron.right",
        "ChevronUp": "chevron.up",
        "ChevronDown": "chevron.down",
        "ArrowLeft": "arrow.left",
        "ArrowRight": "arrow.right",
        "Plus": "plus",
        "Minus": "minus",
        "Search": "magnifyingglass",
        "Settings": "gearshape.fill",
        "User": "person.fill",
        "Home": "house.fill",
        "Mail": "envelope.fill",
        "Phone": "phone.fill",
        "Bell": "bell.fill",
        "Lock": "lock.fill",
        "Eye": "eye.fill",
        "EyeOff": "eye.slash.fill",
        "Edit": "pencil",
        "Trash": "trash.fill",
        "Share": "square.and.arrow.up.fill",
        "Calendar": "calendar",
        "Clock": "clock.fill",
        "Globe": "globe",
        "Info": "info.circle.fill",
        "AlertCircle": "exclamationmark.circle.fill",
        "AlertTriangle": "exclamationmark.triangle.fill",
        "HelpCircle": "questionmark.circle.fill",
        "Menu": "line.horizontal.3",
        "MoreHorizontal": "ellipsis",
        "MoreVertical": "ellipsis.vertical",
        "Play": "play.fill",
        "Pause": "pause.fill",
        // Checkbox / selection glyphs — so a checkbox Block visibly toggles
        // even on the offline SF Symbol fallback (no iconBaseUrl configured).
        "Square": "square",
        "SquareCheck": "checkmark.square.fill",
        "SquareCheckBig": "checkmark.square.fill",
        "Circle": "circle",
        "CircleCheck": "checkmark.circle.fill",
        "CircleCheckBig": "checkmark.circle.fill",
    ]
}

// MARK: - SVG Icon View

/// Fetches an SVG from the CDN, replaces `currentColor` with the resolved color,
/// and renders it to a `UIImage` via a data URL. Results are cached in-memory.
private struct SVGIconView: View {
    let url: URL
    let size: CGFloat
    let colorHex: String
    let strokeWidth: Double

    @StateObject private var loader = SVGIconLoader()

    /// Cache key that includes color + strokeWidth so recolored icons are cached separately.
    private var cacheKey: String {
        "\(url.absoluteString)|\(colorHex)|\(strokeWidth)"
    }

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Transparent placeholder while loading or on failure.
                Color.clear
            }
            #else
            // The SDK is iOS-only at runtime; on macOS we expose a transparent
            // placeholder so `swift build` on the host compiles cleanly.
            Color.clear
            #endif
        }
        .task(id: cacheKey) {
            await loader.load(url: url, colorHex: colorHex, strokeWidth: strokeWidth, size: size, cacheKey: cacheKey)
        }
    }
}

#if canImport(UIKit)
import UIKit

/// Loads a Lucide-style SVG from the icon CDN and renders it via the
/// `LucideSVGRenderer` (a pure-Swift, public-API-only renderer).
///
/// Replaces the previous implementation that called Apple's private
/// `CGSVGDocument*` API via `dlopen` / `dlsym` — see Task 3.10 in the MVP
/// launch plan.
///
/// Results are cached in a static `NSCache` keyed by URL + colour +
/// stroke-width, so the same icon at the same theme parameters is parsed +
/// drawn once per process.
@MainActor
private final class SVGIconLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private static let cache = NSCache<NSString, UIImage>()

    func load(url: URL, colorHex: String, strokeWidth: Double, size: CGFloat, cacheKey: String) async {
        if let cached = Self.cache.object(forKey: cacheKey as NSString) {
            self.image = cached
            return
        }

        do {
            // Prefer cached SVG bytes (seeded offline assets, or a prior fetch)
            // so a bundled flow renders real icons with no network. Only hit the
            // network on a miss, and populate the cache for next time.
            let data: Data
            if let cached = IconCache.shared.data(for: url) {
                data = cached
            } else {
                let (fetched, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    self.failed = true
                    return
                }
                IconCache.shared.setData(fetched, for: url)
                data = fetched
            }

            // `data` is the raw SVG bytes. We pass them directly to the
            // renderer — `currentColor` and stroke-width are applied at draw
            // time so we never need to round-trip through a mutated string.
            let targetSize = CGSize(width: size, height: size)
            let rendered = await Task.detached(priority: .userInitiated) {
                LucideSVGRenderer.render(svgData: data, targetSize: targetSize,
                                         colorHex: colorHex,
                                         strokeWidth: CGFloat(strokeWidth))
            }.value

            if let rendered {
                Self.cache.setObject(rendered, forKey: cacheKey as NSString)
                self.image = rendered
            } else {
                self.failed = true
            }
        } catch {
            self.failed = true
        }
    }
}

#else

@MainActor
private final class SVGIconLoader: ObservableObject {
    @Published var image: AnyObject? // placeholder for non-UIKit
    @Published var failed = false

    func load(url: URL, colorHex: String, strokeWidth: Double, size: CGFloat, cacheKey: String) async {
        failed = true
    }
}

#endif
