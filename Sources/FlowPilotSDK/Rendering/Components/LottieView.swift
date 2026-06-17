import SwiftUI
import Lottie

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Lottie View

/// Renders a `lottie` primitive (overhaul §3.2): a vector animation loaded from
/// a JSON (`.json`) or dotLottie (`.lottie`) URL. `src` resolves exactly like the
/// image primitive (full URL, relative path joined to the media base) via
/// `MediaURLResolver`; the format is chosen from the URL extension. Wraps
/// Lottie's `LottieAnimationView` via `UIViewRepresentable` (iOS) /
/// `NSViewRepresentable` (macOS).
///
/// Sizing mirrors `ImageView`: the view applies its own `.frame` from the
/// component's `width`/`height` props (falling back to a 160×160 square to match
/// the editor canvas in `lottie-renderer.tsx`). The animation then scales to fit
/// that frame (`scaleAspectFit`). The wrapped `LottieAnimationView` has its
/// content-hugging *and* compression-resistance priorities lowered so SwiftUI's
/// frame fully controls the size — without that, the view keeps its intrinsic
/// (natural animation) size and `width`/`height` appear to do nothing.
struct LottieView: View {
    let props: ComponentProps?
    let variableStore: VariableStore
    let mediaBaseUrl: String?

    /// Default square size when the component declares no explicit width/height,
    /// matching the editor canvas fallback (`lottie-renderer.tsx`).
    private static let defaultSize: CGFloat = 160

    private var autoplay: Bool {
        PropertyResolver.resolve(props?.autoplay, store: variableStore, default: true)
    }

    private var loop: Bool {
        PropertyResolver.resolve(props?.loop, store: variableStore, default: true)
    }

    private var speed: Double {
        PropertyResolver.resolve(props?.speed, store: variableStore, default: 1.0)
    }

    private var resolvedURL: URL? {
        // Resolve through the shared resolver so the lottie `src` (full URL,
        // `data:`, or relative path) is handled identically to images.
        let src = PropertyResolver.resolveString(props?.src, store: variableStore)
        return MediaURLResolver.resolve(src: src, mediaBaseUrl: mediaBaseUrl)
    }

    /// Resolved frame width. `.fixed` → the value, `100%` → fill, anything else
    /// (auto / unset / non-100% percent) → the 160 default square.
    private var resolvedWidth: CGFloat {
        switch props?.width {
        case .fixed(let value)?: return CGFloat(value)
        case .percent(100)?: return .infinity
        default: return Self.defaultSize
        }
    }

    private var resolvedHeight: CGFloat {
        switch props?.height {
        case .fixed(let value)?: return CGFloat(value)
        case .percent(100)?: return .infinity
        default: return Self.defaultSize
        }
    }

    var body: some View {
        LottieAnimationRepresentable(
            url: resolvedURL,
            autoplay: autoplay,
            loop: loop,
            speed: speed
        )
        .frame(width: resolvedWidth, height: resolvedHeight)
        .id(resolvedURL?.absoluteString ?? "lottie-empty")
    }
}

// MARK: - Platform Representable

/// Configures a `LottieAnimationView` from resolved props and loads the
/// animation from a remote URL. Handles both plain Lottie JSON (`.json`) and
/// dotLottie (`.lottie`), choosing the loader from the URL extension. Shared
/// logic between the UIKit and AppKit representable wrappers.
private func configureLottie(
    _ view: LottieAnimationView,
    url: URL?,
    autoplay: Bool,
    loop: Bool,
    speed: Double
) {
    // Fit the animation inside the SwiftUI-controlled frame, centered, without
    // cropping — the equivalent of lottie-web's `xMidYMid meet`.
    view.contentMode = .scaleAspectFit
    view.loopMode = loop ? .loop : .playOnce
    view.animationSpeed = CGFloat(speed)

    guard let url = url else {
        view.stop()
        view.animation = nil
        return
    }

    if url.pathExtension.lowercased() == "lottie" {
        // dotLottie is a ZIP container; load it via `DotLottieFile`.
        DotLottieFile.loadedFrom(url: url) { result in
            guard case .success(let dotLottieFile) = result else { return }
            view.loadAnimation(from: dotLottieFile)
            // `loadAnimation(from:)` resets loopMode/animationSpeed from the
            // file's manifest, so re-apply the component's props afterwards.
            view.loopMode = loop ? .loop : .playOnce
            view.animationSpeed = CGFloat(speed)
            if autoplay {
                view.play()
            }
        }
    } else {
        LottieAnimation.loadedFrom(url: url, closure: { animation in
            view.animation = animation
            if autoplay {
                view.play()
            }
        }, animationCache: DefaultAnimationCache.sharedCache)
    }
}

#if canImport(UIKit)
private struct LottieAnimationRepresentable: UIViewRepresentable {
    let url: URL?
    let autoplay: Bool
    let loop: Bool
    let speed: Double

    func makeUIView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        // Let the SwiftUI `.frame` drive the size entirely: low hugging lets the
        // view grow to fill the frame, low compression resistance lets it shrink
        // below the animation's intrinsic size. Without the latter the view
        // refuses to shrink and `width`/`height` appear to have no effect.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        configureLottie(view, url: url, autoplay: autoplay, loop: loop, speed: speed)
        return view
    }

    func updateUIView(_ view: LottieAnimationView, context: Context) {
        configureLottie(view, url: url, autoplay: autoplay, loop: loop, speed: speed)
    }
}
#elseif canImport(AppKit)
private struct LottieAnimationRepresentable: NSViewRepresentable {
    let url: URL?
    let autoplay: Bool
    let loop: Bool
    let speed: Double

    func makeNSView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        configureLottie(view, url: url, autoplay: autoplay, loop: loop, speed: speed)
        return view
    }

    func updateNSView(_ view: LottieAnimationView, context: Context) {
        configureLottie(view, url: url, autoplay: autoplay, loop: loop, speed: speed)
    }
}
#endif
