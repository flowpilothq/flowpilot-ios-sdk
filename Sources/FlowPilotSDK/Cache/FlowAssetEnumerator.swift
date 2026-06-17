import Foundation

// MARK: - Icon URL Resolver

/// Single source of truth for turning a Lucide icon name (+ the flow's
/// `iconBaseUrl`) into the SVG URL. Mirrors `LucideIcon.iconURL` exactly so the
/// offline seeder/exporter target the same URL the renderer fetches.
enum IconURLResolver {
    static func resolve(name: String?, iconBaseUrl: String?) -> URL? {
        guard let base = iconBaseUrl, !base.isEmpty,
              let name = name, !name.isEmpty else { return nil }
        let urlString = base.hasSuffix("/") ? "\(base)\(name).svg" : "\(base)/\(name).svg"
        return URL(string: urlString)
    }
}

// MARK: - Flow Asset Enumerator

/// Pure (Foundation-only, no UIKit) enumeration of the remote assets a flow
/// references: image URLs, Lucide icon SVG URLs, and font files.
///
/// Shared by the runtime offline seeder (`BundledAssetSeeder`) and the build-time
/// exporter (`FlowPilotExporter`) so "what the app looks up" and "what the export
/// downloads" are computed the exact same way — they can't drift.
///
/// Resolution is best-effort/static: a `src`/`iconName` driven by a runtime
/// condition uses its default value (or is skipped), mirroring how the renderer
/// falls back when no variable store is available.
enum FlowAssetEnumerator {

    /// Fully-resolved image URLs referenced anywhere in the flow (deduped).
    static func imageURLs(in flow: ResolvedFlow) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        forEachComponent(in: flow) { node in
            guard node.type == .image else { return }
            guard let url = MediaURLResolver.resolve(
                src: staticString(node.props?.src),
                mediaBaseUrl: flow.mediaBaseUrl
            ) else { return }
            if seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        return urls
    }

    /// Fully-resolved Lucide icon SVG URLs referenced anywhere in the flow (deduped).
    ///
    /// Covers both `icon` components and buttons that render an icon (a button
    /// shows its glyph when an `iconSize` prop is present — see `ButtonView`).
    static func iconURLs(in flow: ResolvedFlow) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        forEachComponent(in: flow) { node in
            let name: String?
            switch node.type {
            case .icon:
                // IconView defaults to "Star" when no name is set.
                name = staticString(node.props?.iconName) ?? "Star"
            case .button:
                // ButtonView only renders an icon when iconSize is present;
                // it defaults the glyph to "ChevronLeft" (back-button preset).
                guard node.props?.iconSize != nil else { return }
                name = staticString(node.props?.iconName) ?? "ChevronLeft"
            default:
                return
            }
            guard let url = IconURLResolver.resolve(name: name, iconBaseUrl: flow.iconBaseUrl) else { return }
            if seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        return urls
    }

    /// Font files the flow declares (the resolve-response font manifest).
    static func fontFiles(in flow: ResolvedFlow) -> [FontFile] {
        flow.fonts ?? []
    }

    // MARK: - Traversal

    /// Visit every component in the flow: each screen's layout plus the
    /// persistent UI zones (navigation bar / footer / overlay).
    private static func forEachComponent(in flow: ResolvedFlow, _ visit: (ComponentNode) -> Void) {
        for node in flow.definition.nodes {
            if case .screen(let screen) = node, let layout = screen.layout {
                walk(layout, visit)
            }
        }
        if let pui = flow.definition.resolvedPersistentUI {
            if let nav = pui.navigationBar?.layout { walk(nav, visit) }
            if let footer = pui.footer?.layout { walk(footer, visit) }
            if let overlay = pui.overlay?.layout { walk(overlay, visit) }
        }
    }

    private static func walk(_ node: ComponentNode, _ visit: (ComponentNode) -> Void) {
        visit(node)
        for child in node.children ?? [] {
            walk(child, visit)
        }
    }

    /// Best-effort static value of a string property: the constant value, or a
    /// conditional's default. Runtime-only conditionals resolve to `nil`.
    private static func staticString(_ property: PropertyValue<String>?) -> String? {
        guard let property else { return nil }
        switch property {
        case .static(let value):
            return value
        case .conditional(_, let defaultValue):
            return defaultValue
        }
    }
}
