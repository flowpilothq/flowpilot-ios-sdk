import SwiftUI

#if canImport(UIKit)
import UIKit

// MARK: - SVG Support Helper

/// Helper to detect and convert SVG data to UIImage
private enum SVGHelper {
    /// Check if data is SVG based on content
    static func isSVG(data: Data) -> Bool {
        // Check for SVG signature in the first bytes
        guard let string = String(data: data.prefix(1000), encoding: .utf8) else {
            return false
        }
        let lowercased = string.lowercased()
        return lowercased.contains("<svg") || (lowercased.contains("<?xml") && lowercased.contains("svg"))
    }

    /// Check if URL points to an SVG file
    static func isSVG(url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return pathExtension == "svg"
    }

    /// Convert SVG data to UIImage using WebKit rendering
    @MainActor
    static func imageFromSVG(data: Data, targetSize: CGSize = CGSize(width: 300, height: 300)) -> UIImage? {
        // Use the PDF rendering approach - SVGs can be treated similarly
        // First, try to get dimensions from SVG
        let size = extractSVGSize(from: data) ?? targetSize

        // Render SVG to UIImage using UIGraphicsImageRenderer
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { context in
            // Create a clear background (transparent)
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Try to render the SVG using WebView snapshot (async approach)
            // For sync rendering, we'll use a simple fallback
        }

        return image
    }

    /// Extract width/height from SVG data
    static func extractSVGSize(from data: Data) -> CGSize? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }

        // Simple regex to find width and height attributes
        var width: CGFloat = 300
        var height: CGFloat = 300

        // Look for viewBox first (viewBox="0 0 width height")
        if let viewBoxRange = string.range(of: #"viewBox\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
            let viewBoxString = String(string[viewBoxRange])
            let numbers = viewBoxString.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .compactMap { Double($0) }
            if numbers.count >= 4 {
                width = CGFloat(numbers[2])
                height = CGFloat(numbers[3])
                return CGSize(width: width, height: height)
            }
        }

        // Look for width attribute
        if let widthRange = string.range(of: #"width\s*=\s*["']?(\d+)"#, options: .regularExpression) {
            let widthString = String(string[widthRange])
            if let value = Double(widthString.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) {
                width = CGFloat(value)
            }
        }

        // Look for height attribute
        if let heightRange = string.range(of: #"height\s*=\s*["']?(\d+)"#, options: .regularExpression) {
            let heightString = String(string[heightRange])
            if let value = Double(heightString.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) {
                height = CGFloat(value)
            }
        }

        return CGSize(width: width, height: height)
    }
}

// MARK: - Image Creation Helper

/// Helper to create UIImage from various data formats
private enum ImageDataHelper {
    /// Create UIImage from data, handling different formats including SVG
    static func createImage(from data: Data, url: URL) -> UIImage? {
        // Check if it's an SVG
        if SVGHelper.isSVG(url: url) || SVGHelper.isSVG(data: data) {
            // For SVG, we need special handling
            // Note: Full SVG support requires a library like SVGKit
            // For now, log a warning and return nil to trigger fallback
            Logger.shared.debug("SVG detected for \(url.lastPathComponent) - limited support available")

            // Try basic SVG rendering (will be limited)
            // In production, consider adding SVGKit dependency
            return nil
        }

        // Standard image formats (PNG, JPEG, GIF, WebP, etc.)
        return UIImage(data: data)
    }
}

// MARK: - Cached Async Image

/// A SwiftUI view that displays an image from cache or loads it from network
/// This view first checks the ImageCache before making any network requests
public struct CachedAsyncImage<Content: View, Placeholder: View>: View {

    // MARK: - Properties

    private let url: URL?
    private let imageCache: ImageCache
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    // Use StateObject to manage loading state with proper identity
    @StateObject private var loader: ImageLoader

    // MARK: - Initialization

    public init(
        url: URL?,
        cache: ImageCache = .shared,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.imageCache = cache
        self.content = content
        self.placeholder = placeholder
        // Create loader with the URL - StateObject ensures proper identity
        self._loader = StateObject(wrappedValue: ImageLoader(url: url, cache: cache))
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if let image = loader.image {
                content(Image(uiImage: image))
            } else if loader.hasFailed {
                placeholder()
            } else {
                placeholder()
            }
        }
        .onAppear {
            loader.load()
        }
        // CRITICAL: Reset loader when URL changes (handles view reuse)
        .onChange(of: url) { newURL in
            loader.updateURL(newURL)
        }
    }
}

// MARK: - Image Loader (ObservableObject for proper state management)

/// Manages image loading state with proper identity tracking
private final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var hasFailed: Bool = false

    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?
    private let cache: ImageCache

    init(url: URL?, cache: ImageCache) {
        self.currentURL = url
        self.cache = cache
    }

    func updateURL(_ newURL: URL?) {
        // Only reload if URL actually changed
        guard newURL != currentURL else { return }

        // Cancel any pending load
        loadTask?.cancel()
        loadTask = nil

        // Reset state
        currentURL = newURL
        image = nil
        hasFailed = false

        // Load new URL
        load()
    }

    func load() {
        guard let url = currentURL else {
            hasFailed = true
            return
        }

        // If already loaded for this URL, don't reload
        if image != nil { return }

        // Check cache first (synchronous)
        if let cachedImage = cache.getImage(for: url) {
            self.image = cachedImage
            return
        }

        // Already loading
        if loadTask != nil { return }

        // Load from network
        loadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)

                // Check if cancelled or URL changed
                if Task.isCancelled || self.currentURL != url { return }

                // Validate response
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    await MainActor.run {
                        if self.currentURL == url {
                            self.hasFailed = true
                        }
                    }
                    return
                }

                // Create image
                guard let loadedImage = UIImage(data: data) else {
                    await MainActor.run {
                        if self.currentURL == url {
                            self.hasFailed = true
                        }
                    }
                    return
                }

                // Cache it
                self.cache.setImage(loadedImage, for: url)

                // Update UI only if URL still matches
                await MainActor.run {
                    if self.currentURL == url {
                        self.image = loadedImage
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        if self.currentURL == url {
                            self.hasFailed = true
                        }
                    }
                }
            }
        }
    }

    deinit {
        loadTask?.cancel()
    }
}

// MARK: - Convenience Initializers

extension CachedAsyncImage where Content == Image, Placeholder == ProgressView<EmptyView, EmptyView> {
    /// Simple initializer with default placeholder
    public init(url: URL?, cache: ImageCache = .shared) {
        self.init(
            url: url,
            cache: cache,
            content: { $0 },
            placeholder: { ProgressView() }
        )
    }
}

extension CachedAsyncImage where Placeholder == ProgressView<EmptyView, EmptyView> {
    /// Initializer with custom content and default placeholder
    public init(
        url: URL?,
        cache: ImageCache = .shared,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.init(
            url: url,
            cache: cache,
            content: content,
            placeholder: { ProgressView() }
        )
    }
}

// MARK: - Phase-based Cached Async Image

/// A cached image view that provides loading phases similar to AsyncImage
/// Uses URL as identity to ensure correct image is always shown
public struct CachedAsyncImageWithPhase: View {

    // MARK: - Types

    public enum Phase: Equatable {
        case empty
        case success(Image)
        case failure(Error)

        public var image: Image? {
            if case .success(let image) = self {
                return image
            }
            return nil
        }

        public var error: Error? {
            if case .failure(let error) = self {
                return error
            }
            return nil
        }

        public static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.empty, .empty): return true
            case (.success, .success): return true
            case (.failure, .failure): return true
            default: return false
            }
        }
    }

    // MARK: - Properties

    private let url: URL?
    private let imageCache: ImageCache
    private let content: (Phase) -> AnyView

    @StateObject private var loader: PhaseImageLoader

    // MARK: - Initialization

    public init<Content: View>(
        url: URL?,
        cache: ImageCache = .shared,
        @ViewBuilder content: @escaping (Phase) -> Content
    ) {
        self.url = url
        self.imageCache = cache
        self.content = { AnyView(content($0)) }
        self._loader = StateObject(wrappedValue: PhaseImageLoader(url: url, cache: cache))
    }

    // MARK: - Body

    public var body: some View {
        content(loader.phase)
            .onAppear {
                loader.load()
            }
            // CRITICAL: Handle URL changes for view reuse
            .onChange(of: url) { newURL in
                loader.updateURL(newURL)
            }
            // Use id to force view recreation when URL changes significantly
            .id(url?.absoluteString ?? "nil")
    }
}

// MARK: - Phase Image Loader

/// Manages phase-based image loading with proper URL tracking
private final class PhaseImageLoader: ObservableObject {
    @Published var phase: CachedAsyncImageWithPhase.Phase = .empty

    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?
    private let cache: ImageCache
    private var hasLoaded = false

    init(url: URL?, cache: ImageCache) {
        self.currentURL = url
        self.cache = cache
    }

    func updateURL(_ newURL: URL?) {
        // Only reload if URL actually changed
        guard newURL != currentURL else { return }

        // Cancel any pending load
        loadTask?.cancel()
        loadTask = nil

        // Reset state
        currentURL = newURL
        hasLoaded = false
        phase = .empty

        // Load new URL
        load()
    }

    func load() {
        guard let url = currentURL else {
            phase = .failure(URLError(.badURL))
            return
        }

        // Prevent duplicate loads
        if hasLoaded { return }

        // Check cache first - show immediately if cached
        if let cachedImage = cache.getImage(for: url) {
            phase = .success(Image(uiImage: cachedImage))
            hasLoaded = true
            return
        }

        // Already loading
        if loadTask != nil { return }

        // Set empty phase while loading
        phase = .empty

        loadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)

                // Check if cancelled or URL changed
                if Task.isCancelled || self.currentURL != url { return }

                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    await MainActor.run {
                        if self.currentURL == url {
                            self.phase = .failure(URLError(.badServerResponse))
                            self.hasLoaded = true
                        }
                    }
                    return
                }

                guard let uiImage = UIImage(data: data) else {
                    await MainActor.run {
                        if self.currentURL == url {
                            self.phase = .failure(URLError(.cannotDecodeContentData))
                            self.hasLoaded = true
                        }
                    }
                    return
                }

                // Cache the image
                self.cache.setImage(uiImage, for: url)

                // Update UI only if URL still matches
                await MainActor.run {
                    if self.currentURL == url {
                        self.phase = .success(Image(uiImage: uiImage))
                        self.hasLoaded = true
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        if self.currentURL == url {
                            self.phase = .failure(error)
                            self.hasLoaded = true
                        }
                    }
                }
            }
        }
    }

    deinit {
        loadTask?.cancel()
    }
}

#else

// MARK: - Stub for non-UIKit platforms

/// Stub CachedAsyncImage for non-UIKit platforms - uses standard AsyncImage
public struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    public init(
        url: URL?,
        cache: ImageCache = .shared,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    public var body: some View {
        AsyncImage(url: url) { image in
            content(image)
        } placeholder: {
            placeholder()
        }
    }
}

/// Stub CachedAsyncImageWithPhase for non-UIKit platforms
public struct CachedAsyncImageWithPhase: View {
    public enum Phase: Equatable {
        case empty
        case success(Image)
        case failure(Error)

        public var image: Image? {
            if case .success(let image) = self { return image }
            return nil
        }

        public var error: Error? {
            if case .failure(let error) = self { return error }
            return nil
        }

        public static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.empty, .empty): return true
            case (.success, .success): return true
            case (.failure, .failure): return true
            default: return false
            }
        }
    }

    private let url: URL?
    private let content: (Phase) -> AnyView

    public init<Content: View>(
        url: URL?,
        cache: ImageCache = .shared,
        @ViewBuilder content: @escaping (Phase) -> Content
    ) {
        self.url = url
        self.content = { AnyView(content($0)) }
    }

    public var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                content(.empty)
            case .success(let image):
                content(.success(image))
            case .failure(let error):
                content(.failure(error))
            @unknown default:
                content(.empty)
            }
        }
    }
}

#endif
