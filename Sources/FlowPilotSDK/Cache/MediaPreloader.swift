import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit

// MARK: - Media Preloader

/// Service to preload all media content from a flow in screen order priority
final class MediaPreloader: @unchecked Sendable {

    // MARK: - Types

    /// Represents a media item to be preloaded
    struct MediaItem: Sendable {
        let url: URL
        let screenIndex: Int
        let screenId: String
        let componentId: String
        let type: MediaType

        enum MediaType: String, Sendable {
            case image
        }
    }

    /// Preload progress information
    struct PreloadProgress: Sendable {
        let totalItems: Int
        let completedItems: Int
        let currentScreenIndex: Int
        let failedItems: Int

        var progress: Double {
            guard totalItems > 0 else { return 1.0 }
            return Double(completedItems) / Double(totalItems)
        }

        var isComplete: Bool {
            return completedItems + failedItems >= totalItems
        }
    }

    /// Preload result
    struct PreloadResult: Sendable {
        let totalItems: Int
        let successfulItems: Int
        let failedItems: Int
        let failedURLs: [URL]
        let durationMs: Int

        var allSuccessful: Bool {
            return failedItems == 0
        }
    }

    // MARK: - Properties

    private let imageCache: ImageCache
    private let urlSession: URLSession
    private let maxConcurrentDownloads: Int

    /// Progress callback - called on main thread
    var onProgress: ((PreloadProgress) -> Void)?

    // MARK: - Initialization

    init(
        imageCache: ImageCache = .shared,
        maxConcurrentDownloads: Int = 3
    ) {
        self.imageCache = imageCache
        self.maxConcurrentDownloads = maxConcurrentDownloads

        // Configure URL session for image downloads
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = maxConcurrentDownloads
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Extract all media URLs from a flow definition, ordered by screen sequence.
    ///
    /// - Parameter maxScreenIndex: When non-nil, only items at or before this
    ///   screen index are returned. Persistent zones (navigation bar / footer /
    ///   overlay) live at index `-1` and the first screen at index `0`, so passing
    ///   `0` yields "first screen + persistent zones" — the bounded set launch
    ///   prefetch warms by default. `nil` (the default) returns every screen's
    ///   media, preserving the full-flow behavior a live session relies on.
    func extractMediaItems(
        from flow: FlowDefinition,
        mediaBaseUrl: String?,
        variableStore: VariableStore? = nil,
        maxScreenIndex: Int? = nil
    ) -> [MediaItem] {
        var items: [MediaItem] = []
        var screenIndex = 0

        // Get screens in navigation order (following edges from entry node)
        let orderedScreens = getScreensInOrder(from: flow)

        for screenNode in orderedScreens {
            // Extract from screen layout
            if let layout = screenNode.layout {
                let screenItems = extractMediaFromComponent(
                    layout,
                    screenIndex: screenIndex,
                    screenId: screenNode.id,
                    mediaBaseUrl: mediaBaseUrl,
                    variableStore: variableStore
                )
                items.append(contentsOf: screenItems)
            }
            screenIndex += 1
        }

        // Also extract from persistent zones (navigationBar/footer/overlay) as they're shown on all screens
        if let pui = flow.resolvedPersistentUI {
            if let navBar = pui.navigationBar {
                let navBarItems = extractMediaFromComponent(
                    navBar.layout,
                    screenIndex: -1, // Zones have highest priority
                    screenId: "zone_navigationBar",
                    mediaBaseUrl: mediaBaseUrl,
                    variableStore: variableStore
                )
                items.insert(contentsOf: navBarItems, at: 0)
            }
            if let footer = pui.footer {
                let footerItems = extractMediaFromComponent(
                    footer.layout,
                    screenIndex: -1,
                    screenId: "zone_footer",
                    mediaBaseUrl: mediaBaseUrl,
                    variableStore: variableStore
                )
                items.insert(contentsOf: footerItems, at: 0)
            }
            if let overlay = pui.overlay {
                let overlayItems = extractMediaFromComponent(
                    overlay.layout,
                    screenIndex: -1,
                    screenId: "zone_overlay",
                    mediaBaseUrl: mediaBaseUrl,
                    variableStore: variableStore
                )
                items.insert(contentsOf: overlayItems, at: 0)
            }
        }

        // Sort by screen index to ensure priority loading
        items.sort { $0.screenIndex < $1.screenIndex }

        // Bound to the requested screen window (e.g. first screen + zones).
        if let maxScreenIndex = maxScreenIndex {
            items = items.filter { $0.screenIndex <= maxScreenIndex }
        }

        Logger.shared.debug("MediaPreloader: Extracted \(items.count) media items from \(orderedScreens.count) screens")
        return items
    }

    /// Preload all media items in order (screen 1 content first, then screen 2, etc.)
    func preloadMedia(
        items: [MediaItem],
        priority: Bool = true
    ) async -> PreloadResult {
        let startTime = Date()
        var completedCount = 0
        var failedCount = 0
        var failedURLs: [URL] = []
        let totalCount = items.count

        guard totalCount > 0 else {
            return PreloadResult(
                totalItems: 0,
                successfulItems: 0,
                failedItems: 0,
                failedURLs: [],
                durationMs: 0
            )
        }

        // Group items by screen index for ordered loading
        let groupedItems = Dictionary(grouping: items) { $0.screenIndex }
        let sortedScreenIndices = groupedItems.keys.sorted()

        for screenIndex in sortedScreenIndices {
            guard let screenItems = groupedItems[screenIndex] else { continue }

            // Load all items for this screen concurrently, but wait before moving to next screen
            await withTaskGroup(of: (URL, Bool).self) { group in
                for item in screenItems {
                    group.addTask { [weak self] in
                        guard let self = self else { return (item.url, false) }

                        // Skip if already cached
                        if self.imageCache.hasImage(for: item.url) {
                            Logger.shared.verbose("MediaPreloader: Already cached \(item.url.lastPathComponent)")
                            return (item.url, true)
                        }

                        // Download and cache
                        let success = await self.downloadAndCache(url: item.url, type: item.type)
                        return (item.url, success)
                    }
                }

                // Collect results for this screen
                for await (url, success) in group {
                    if success {
                        completedCount += 1
                    } else {
                        failedCount += 1
                        failedURLs.append(url)
                    }

                    // Report progress
                    let progress = PreloadProgress(
                        totalItems: totalCount,
                        completedItems: completedCount,
                        currentScreenIndex: screenIndex,
                        failedItems: failedCount
                    )
                    await MainActor.run {
                        self.onProgress?(progress)
                    }
                }
            }

            Logger.shared.debug("MediaPreloader: Completed screen \(screenIndex), \(completedCount)/\(totalCount) items loaded")
        }

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        Logger.shared.info("MediaPreloader: Preloading complete - \(completedCount) succeeded, \(failedCount) failed in \(duration)ms")

        return PreloadResult(
            totalItems: totalCount,
            successfulItems: completedCount,
            failedItems: failedCount,
            failedURLs: failedURLs,
            durationMs: duration
        )
    }

    /// Convenience method to preload media from a resolved flow.
    ///
    /// - Parameter firstScreenOnly: When `true`, only the first screen's images
    ///   and persistent-zone images are warmed (so launch prefetch doesn't pull
    ///   every screen's art). When `false` (the default), every screen's media is
    ///   preloaded, matching the behavior a live `FlowSession` relies on.
    func preloadFlow(
        _ flow: ResolvedFlow,
        variableStore: VariableStore? = nil,
        firstScreenOnly: Bool = false
    ) async -> PreloadResult {
        let items = extractMediaItems(
            from: flow.definition,
            mediaBaseUrl: flow.mediaBaseUrl,
            variableStore: variableStore,
            maxScreenIndex: firstScreenOnly ? 0 : nil
        )
        return await preloadMedia(items: items)
    }

    /// Enumerate the fully-resolved image URLs a flow references, in screen
    /// order. Pure (no network) — used by the offline asset seeder to know which
    /// image cache keys to populate, so seeding and rendering target the same URLs.
    func imageURLs(in flow: ResolvedFlow, variableStore: VariableStore? = nil) -> [URL] {
        extractMediaItems(
            from: flow.definition,
            mediaBaseUrl: flow.mediaBaseUrl,
            variableStore: variableStore
        ).map { $0.url }
    }

    // MARK: - Screen Ordering

    /// Get screens in navigation order by following edges from entry node
    private func getScreensInOrder(from flow: FlowDefinition) -> [ScreenNode] {
        var orderedScreens: [ScreenNode] = []
        var visitedNodeIds: Set<String> = []
        var nodeQueue: [String] = [flow.entryNodeId]

        // Build edge lookup
        let edgesByFromNode = Dictionary(grouping: flow.edges) { $0.fromNodeId }

        // BFS traversal to get screens in navigation order
        while !nodeQueue.isEmpty {
            let currentId = nodeQueue.removeFirst()

            // Skip if already visited
            guard !visitedNodeIds.contains(currentId) else { continue }
            visitedNodeIds.insert(currentId)

            // Find the node
            guard let node = flow.nodes.first(where: { $0.id == currentId }) else { continue }

            // If it's a screen, add it
            if case .screen(let screenNode) = node {
                orderedScreens.append(screenNode)
            }

            // Add connected nodes to queue (sorted by priority if available)
            if let edges = edgesByFromNode[currentId] {
                let sortedEdges = edges.sorted { ($0.priority ?? 0) < ($1.priority ?? 0) }
                for edge in sortedEdges {
                    if !visitedNodeIds.contains(edge.toNodeId) {
                        nodeQueue.append(edge.toNodeId)
                    }
                }
            }
        }

        return orderedScreens
    }

    // MARK: - Component Traversal

    /// Recursively extract media items from a component tree
    private func extractMediaFromComponent(
        _ component: ComponentNode,
        screenIndex: Int,
        screenId: String,
        mediaBaseUrl: String?,
        variableStore: VariableStore?
    ) -> [MediaItem] {
        var items: [MediaItem] = []

        // Check if this component has media
        if let mediaItem = extractMediaItem(
            from: component,
            screenIndex: screenIndex,
            screenId: screenId,
            mediaBaseUrl: mediaBaseUrl,
            variableStore: variableStore
        ) {
            items.append(mediaItem)
        }

        // Recursively process children
        if let children = component.children {
            for child in children {
                let childItems = extractMediaFromComponent(
                    child,
                    screenIndex: screenIndex,
                    screenId: screenId,
                    mediaBaseUrl: mediaBaseUrl,
                    variableStore: variableStore
                )
                items.append(contentsOf: childItems)
            }
        }

        return items
    }

    /// Extract a media item from a single component if applicable
    private func extractMediaItem(
        from component: ComponentNode,
        screenIndex: Int,
        screenId: String,
        mediaBaseUrl: String?,
        variableStore: VariableStore?
    ) -> MediaItem? {
        let type: MediaItem.MediaType

        switch component.type {
        case .image:
            type = .image
        default:
            return nil
        }

        // Get the source URL
        guard let srcProperty = component.props?.src else { return nil }

        // Resolve the source string (handles variable interpolation)
        let srcString: String?
        if let store = variableStore {
            srcString = PropertyResolver.resolveString(srcProperty, store: store)
        } else {
            // Try to get static value
            switch srcProperty {
            case .static(let value):
                srcString = value
            case .conditional:
                // Can't resolve conditional without variable store
                // Try to get default value or skip
                srcString = nil
            }
        }

        // Resolve through the shared resolver (handles data:/absolute/relative)
        // so preload, render, and offline seeding all agree on the URL.
        guard let url = MediaURLResolver.resolve(src: srcString, mediaBaseUrl: mediaBaseUrl) else { return nil }

        return MediaItem(
            url: url,
            screenIndex: screenIndex,
            screenId: screenId,
            componentId: component.id,
            type: type
        )
    }

    // MARK: - Download

    /// Download and cache a media item
    private func downloadAndCache(url: URL, type: MediaItem.MediaType) async -> Bool {
        do {
            let (data, response) = try await urlSession.data(from: url)

            // Check response
            if let httpResponse = response as? HTTPURLResponse {
                guard (200...299).contains(httpResponse.statusCode) else {
                    Logger.shared.warn("MediaPreloader: HTTP \(httpResponse.statusCode) for \(url.lastPathComponent)")
                    return false
                }
            }

            // Validate and cache image
            guard let image = UIImage(data: data) else {
                Logger.shared.warn("MediaPreloader: Invalid image data for \(url.lastPathComponent)")
                return false
            }

            imageCache.setImage(image, for: url)
            Logger.shared.verbose("MediaPreloader: Downloaded and cached \(url.lastPathComponent)")
            return true

        } catch {
            Logger.shared.warn("MediaPreloader: Download failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Convenience Extensions

extension ResolvedFlow {
    /// Preload all media content for this flow
    func preloadMedia(
        variableStore: VariableStore? = nil,
        onProgress: ((MediaPreloader.PreloadProgress) -> Void)? = nil
    ) async -> MediaPreloader.PreloadResult {
        let preloader = MediaPreloader()
        preloader.onProgress = onProgress
        return await preloader.preloadFlow(self, variableStore: variableStore)
    }
}

#else

// MARK: - Stub for non-UIKit platforms

/// Stub MediaPreloader for non-UIKit platforms
final class MediaPreloader: @unchecked Sendable {
    struct MediaItem: Sendable {
        let url: URL
        let screenIndex: Int
        let screenId: String
        let componentId: String
        let type: MediaType
        enum MediaType: String, Sendable { case image }
    }

    struct PreloadProgress: Sendable {
        let totalItems: Int
        let completedItems: Int
        let currentScreenIndex: Int
        let failedItems: Int
        var progress: Double { 1.0 }
        var isComplete: Bool { true }
    }

    struct PreloadResult: Sendable {
        let totalItems: Int
        let successfulItems: Int
        let failedItems: Int
        let failedURLs: [URL]
        let durationMs: Int
        var allSuccessful: Bool { true }
    }

    var onProgress: ((PreloadProgress) -> Void)?

    init(imageCache: ImageCache = .shared, maxConcurrentDownloads: Int = 3) {}

    func extractMediaItems(from flow: FlowDefinition, mediaBaseUrl: String?, variableStore: VariableStore? = nil, maxScreenIndex: Int? = nil) -> [MediaItem] { [] }

    func preloadMedia(items: [MediaItem], priority: Bool = true) async -> PreloadResult {
        PreloadResult(totalItems: 0, successfulItems: 0, failedItems: 0, failedURLs: [], durationMs: 0)
    }

    func preloadFlow(_ flow: ResolvedFlow, variableStore: VariableStore? = nil, firstScreenOnly: Bool = false) async -> PreloadResult {
        PreloadResult(totalItems: 0, successfulItems: 0, failedItems: 0, failedURLs: [], durationMs: 0)
    }

    func imageURLs(in flow: ResolvedFlow, variableStore: VariableStore? = nil) -> [URL] { [] }
}

extension ResolvedFlow {
    func preloadMedia(variableStore: VariableStore? = nil, onProgress: ((MediaPreloader.PreloadProgress) -> Void)? = nil) async -> MediaPreloader.PreloadResult {
        MediaPreloader.PreloadResult(totalItems: 0, successfulItems: 0, failedItems: 0, failedURLs: [], durationMs: 0)
    }
}

#endif
