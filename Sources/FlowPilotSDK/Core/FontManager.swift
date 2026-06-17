import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(CoreText)
import CoreText
#endif

// MARK: - Font Manager

/// Manages downloading, caching, and registering custom fonts delivered by the backend.
///
/// Font files (.ttf) are downloaded from CDN URLs, cached to disk, and registered
/// with `CTFontManagerRegisterFontsForURL` for process-wide availability.
/// No Info.plist changes are needed.
///
/// Thread-safe and idempotent — safe to call from multiple tasks concurrently.
final class FontManager: @unchecked Sendable {
    static let shared = FontManager()

    /// Protects `registeredKeys` and `familyNameMap`
    private let lock = NSLock()

    /// Set of font cache keys that have been registered in this process
    private var registeredKeys = Set<String>()

    /// Maps schema family name → actual iOS-registered family name.
    /// Populated at registration time by reading the font file's internal metadata.
    /// e.g., "Proxima Nova Reg" → "Proxima Nova"
    private var familyNameMap = [String: String]()

    /// Disk cache directory for font files
    private let cacheDirectory: URL

    /// URL session for downloading font files
    private let urlSession: URLSession

    private init() {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        self.cacheDirectory = paths[0]
            .appendingPathComponent("FlowPilot", isDirectory: true)
            .appendingPathComponent("fonts", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        // Use a dedicated session with reasonable timeouts
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Ensures all fonts in the manifest are downloaded and registered.
    /// Call BEFORE presenting the flow. Returns when all fonts are ready.
    /// Fails silently for individual fonts — the flow will render with system font fallback.
    func loadFonts(_ fonts: [FontFile]) async {
        Logger.shared.info("[FONT DEBUG] FontManager.loadFonts called with \(fonts.count) fonts")
        for font in fonts {
            Logger.shared.info("[FONT DEBUG] FontManager.loadFonts: font entry — family=\(font.family) weight=\(font.weight) style=\(font.style) url=\(font.url) cacheKey=\(font.cacheKey)")
        }

        let needed = fonts.filter { !isRegistered(key: $0.cacheKey) }
        if needed.isEmpty {
            Logger.shared.info("[FONT DEBUG] FontManager.loadFonts: all \(fonts.count) fonts already registered, nothing to do")
            return
        }

        Logger.shared.info("[FONT DEBUG] FontManager.loadFonts: \(needed.count) fonts need download/registration")

        await withTaskGroup(of: Void.self) { group in
            for font in needed {
                group.addTask {
                    await self.downloadAndRegister(font)
                }
            }
        }

        Logger.shared.info("[FONT DEBUG] FontManager.loadFonts: loading complete — registeredKeys=\(self.registeredKeys)")
    }

    /// Registers a font directly from a local file (e.g. a `.ttf` shipped in the
    /// app bundle alongside an offline default flow) — no download, no disk copy.
    ///
    /// `CTFontManagerRegisterFontsForURL` accepts any readable URL, including a
    /// bundle resource, so this seeds the same registration the CDN download path
    /// would have produced. Idempotent and non-fatal: a missing/corrupt file is
    /// logged and skipped, and the flow renders with system-font fallback.
    func registerLocalFont(_ font: FontFile, fileURL: URL) {
        let key = font.cacheKey

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Logger.shared.warn("[FONT DEBUG] FontManager.registerLocalFont: file not found at \(fileURL.path) for \(key)")
            return
        }

        if isRegistered(key: key) {
            Logger.shared.info("[FONT DEBUG] FontManager.registerLocalFont: already registered \(key)")
            return
        }

        Logger.shared.info("[FONT DEBUG] FontManager.registerLocalFont: registering \(key) from bundle file \(fileURL.path)")
        registerFont(at: fileURL, key: key, schemaFamily: font.family)
    }

    /// Clears all cached font files from disk and deregisters them.
    func clearCache() {
        lock.lock()
        let keys = registeredKeys
        registeredKeys.removeAll()
        familyNameMap.removeAll()
        lock.unlock()

        // Deregister all fonts
        for key in keys {
            let localURL = cacheDirectory.appendingPathComponent("\(key).ttf")
            if FileManager.default.fileExists(atPath: localURL.path) {
                var error: Unmanaged<CFError>?
                CTFontManagerUnregisterFontsForURL(localURL as CFURL, .process, &error)
            }
        }

        // Remove cached files
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) {
            for fileURL in contents {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        Logger.shared.debug("FontManager: Cache cleared")
    }

    // MARK: - Private

    private func downloadAndRegister(_ font: FontFile) async {
        let key = font.cacheKey
        let localURL = cacheDirectory.appendingPathComponent("\(key).ttf")

        // Check disk cache first
        if FileManager.default.fileExists(atPath: localURL.path) {
            Logger.shared.info("[FONT DEBUG] FontManager.downloadAndRegister: disk cache hit for \(key) at \(localURL.path)")
            registerFont(at: localURL, key: key, schemaFamily: font.family)
            return
        }

        // Download from CDN
        guard let url = URL(string: font.url) else {
            Logger.shared.warn("[FONT DEBUG] FontManager.downloadAndRegister: invalid URL for font \(key): \(font.url)")
            return
        }

        Logger.shared.info("[FONT DEBUG] FontManager.downloadAndRegister: downloading \(key) from \(url.absoluteString)")

        do {
            let (data, response) = try await urlSession.data(from: url)

            // Validate response
            if let httpResponse = response as? HTTPURLResponse {
                Logger.shared.info("[FONT DEBUG] FontManager.downloadAndRegister: HTTP \(httpResponse.statusCode) for \(key), size=\(data.count) bytes")
                if httpResponse.statusCode != 200 {
                    Logger.shared.warn("[FONT DEBUG] FontManager.downloadAndRegister: non-200 status \(httpResponse.statusCode) for \(key)")
                    return
                }
            }

            // Write to disk cache
            try data.write(to: localURL, options: .atomic)
            Logger.shared.info("[FONT DEBUG] FontManager.downloadAndRegister: written to disk at \(localURL.path)")

            // Register
            registerFont(at: localURL, key: key, schemaFamily: font.family)

        } catch {
            Logger.shared.warn("[FONT DEBUG] FontManager.downloadAndRegister: FAILED to download \(key): \(error.localizedDescription)")
        }
    }

    private func registerFont(at url: URL, key: String, schemaFamily: String? = nil) {
        // Check if already registered (race condition guard)
        if isRegistered(key: key) {
            Logger.shared.info("[FONT DEBUG] FontManager.registerFont: already registered \(key)")
            return
        }

        Logger.shared.info("[FONT DEBUG] FontManager.registerFont: registering \(key) from \(url.path)")

        var error: Unmanaged<CFError>?
        let success = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)

        if success {
            lock.lock()
            registeredKeys.insert(key)
            lock.unlock()
            Logger.shared.info("[FONT DEBUG] FontManager.registerFont: SUCCESS registered \(key)")
            recordFontFamilyName(at: url, schemaFamily: schemaFamily)
        } else if let cfError = error?.takeRetainedValue() {
            let nsError = cfError as Error as NSError
            // Error code 105 = font already registered (not a real error)
            if nsError.code == 105 {
                lock.lock()
                registeredKeys.insert(key)
                lock.unlock()
                Logger.shared.info("[FONT DEBUG] FontManager.registerFont: already registered (code 105) \(key)")
                recordFontFamilyName(at: url, schemaFamily: schemaFamily)
            } else {
                Logger.shared.warn("[FONT DEBUG] FontManager.registerFont: FAILED to register \(key): code=\(nsError.code) error=\(nsError.localizedDescription)")
            }
        } else {
            Logger.shared.warn("[FONT DEBUG] FontManager.registerFont: FAILED to register \(key) — no error returned")
        }
    }

    /// Reads the font file's actual family name and maps the schema family name to it.
    private func recordFontFamilyName(at url: URL, schemaFamily: String?) {
        guard let schemaFamily = schemaFamily, !schemaFamily.isEmpty else { return }
        guard let dataProvider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(dataProvider),
              let actualFamily = cgFont.fullName as String? else {
            return
        }

        // Get the family name via CTFont which gives us the proper family grouping
        let ctFont = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
        let registeredFamily = CTFontCopyFamilyName(ctFont) as String

        Logger.shared.info("[FONT DEBUG] FontManager.recordFontFamilyName: schema=\"\(schemaFamily)\" → registered=\"\(registeredFamily)\" fullName=\"\(actualFamily)\"")

        if schemaFamily.lowercased() != registeredFamily.lowercased() {
            lock.lock()
            familyNameMap[schemaFamily] = registeredFamily
            lock.unlock()
            Logger.shared.info("[FONT DEBUG] FontManager.recordFontFamilyName: added mapping \"\(schemaFamily)\" → \"\(registeredFamily)\"")
        }
    }

    private func isRegistered(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registeredKeys.contains(key)
    }
}

// MARK: - Font Resolution

/// Centralized font resolution for all components.
/// Handles system font aliases, registered custom fonts, and graceful fallback.
extension FontManager {

    /// System font aliases that map to the default system font (SF Pro on iOS).
    private static let defaultSystemAliases: Set<String> = [
        "system-ui", "-apple-system", "sf pro", "sf pro display",
        "sf pro text", "sans-serif"
    ]

    /// Maps CSS generic font families to their iOS equivalents.
    /// These need special handling — they're "system" fonts but NOT the default system font.
    private static let genericFamilyMap: [String: String] = [
        "serif": "New York",
        "monospace": "Menlo"
    ]

    /// Returns true if the family name is any system/generic alias (no CDN download needed).
    static func isSystemFont(_ family: String) -> Bool {
        let lower = family.lowercased()
        return defaultSystemAliases.contains(lower) || genericFamilyMap[lower] != nil
    }

    #if canImport(UIKit)
    /// Resolves a UIFont for the given family, weight, and size.
    /// Uses registered custom fonts via UIFontDescriptor for correct weight matching,
    /// falls back to system font for unresolvable families.
    static func resolveUIFont(family: String?, weight: UIFont.Weight, size: CGFloat) -> UIFont {
        guard let family = family, !family.isEmpty else {
            return UIFont.systemFont(ofSize: size, weight: weight)
        }

        // Check for generic CSS families that map to specific iOS fonts
        let lower = family.lowercased()
        if let mappedFamily = genericFamilyMap[lower] {
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: mappedFamily,
                .traits: [UIFontDescriptor.TraitKey.weight: weight]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }

        // Default system font aliases
        if defaultSystemAliases.contains(lower) {
            return UIFont.systemFont(ofSize: size, weight: weight)
        }

        // Log available registered font families for debugging
        Logger.shared.info("[FONT DEBUG] resolveUIFont: looking for family=\"\(family)\" weight=\(weight.rawValue) size=\(size)")
        Logger.shared.info("[FONT DEBUG] resolveUIFont: registeredKeys=\(FontManager.shared.registeredKeys)")

        // Try to load the named font directly (exact PostScript name)
        if let customFont = UIFont(name: family, size: size) {
            Logger.shared.info("[FONT DEBUG] resolveUIFont: UIFont(name:) SUCCESS for \"\(family)\" → \(customFont.fontName) familyName=\(customFont.familyName)")
            return customFont
        }
        Logger.shared.info("[FONT DEBUG] resolveUIFont: UIFont(name:) returned nil for \"\(family)\"")

        // Try resolving via font descriptor with the family name and weight trait
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        let resolvedFont = UIFont(descriptor: descriptor, size: size)
        Logger.shared.info("[FONT DEBUG] resolveUIFont: descriptor resolved to familyName=\"\(resolvedFont.familyName)\" fontName=\"\(resolvedFont.fontName)\"")

        if resolvedFont.familyName.lowercased() == family.lowercased() {
            Logger.shared.info("[FONT DEBUG] resolveUIFont: descriptor match SUCCESS for \"\(family)\"")
            return resolvedFont
        }

        // Check familyNameMap — the font file's internal family name may differ
        // from the schema name (e.g., "Proxima Nova Reg" → "Proxima Nova")
        FontManager.shared.lock.lock()
        let mappedFamily = FontManager.shared.familyNameMap[family]
        FontManager.shared.lock.unlock()

        if let mappedFamily = mappedFamily {
            Logger.shared.info("[FONT DEBUG] resolveUIFont: using mapped family \"\(family)\" → \"\(mappedFamily)\"")
            let mappedDescriptor = UIFontDescriptor(fontAttributes: [
                .family: mappedFamily,
                .traits: [UIFontDescriptor.TraitKey.weight: weight]
            ])
            return UIFont(descriptor: mappedDescriptor, size: size)
        }

        // Fall back to system font if the family could not be matched
        Logger.shared.warn("[FONT DEBUG] resolveUIFont: FALLBACK to system font for \"\(family)\" — font not found on device")

        return UIFont.systemFont(ofSize: size, weight: weight)
    }
    #endif

    #if canImport(AppKit)
    /// Resolves an NSFont for the given family, weight, and size.
    static func resolveNSFont(family: String?, weight: NSFont.Weight, size: CGFloat) -> NSFont {
        guard let family = family, !family.isEmpty else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }

        // Check for generic CSS families that map to specific macOS fonts
        let lower = family.lowercased()
        if let mappedFamily = genericFamilyMap[lower] {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: mappedFamily,
                .traits: [NSFontDescriptor.TraitKey.weight: weight]
            ])
            if let font = NSFont(descriptor: descriptor, size: size) {
                return font
            }
            return NSFont.systemFont(ofSize: size, weight: weight)
        }

        // Default system font aliases
        if defaultSystemAliases.contains(lower) {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }

        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        if let resolvedFont = NSFont(descriptor: descriptor, size: size),
           resolvedFont.familyName?.lowercased() == family.lowercased() {
            return resolvedFont
        }
        if let namedFont = NSFont(name: family, size: size) {
            return namedFont
        }

        // Check familyNameMap for schema→registered name mapping
        FontManager.shared.lock.lock()
        let mapped = FontManager.shared.familyNameMap[family]
        FontManager.shared.lock.unlock()

        if let mapped = mapped {
            let mappedDesc = NSFontDescriptor(fontAttributes: [
                .family: mapped,
                .traits: [NSFontDescriptor.TraitKey.weight: weight]
            ])
            if let mappedFont = NSFont(descriptor: mappedDesc, size: size) {
                return mappedFont
            }
        }

        return NSFont.systemFont(ofSize: size, weight: weight)
    }
    #endif

    /// Resolves a SwiftUI Font for the given family, weight, and size.
    /// For custom fonts, routes through UIFont/NSFont for reliable weight resolution,
    /// then bridges to SwiftUI via `Font(UIFont)` / `Font(NSFont)`.
    static func resolveSwiftUIFont(family: String?, weight: Font.Weight, size: CGFloat) -> Font {
        guard let family = family, !family.isEmpty else {
            return Font.system(size: size, weight: weight)
        }

        // Handle generic CSS families and default system aliases via platform font resolvers
        // (they handle the mapping internally)
        let lower = family.lowercased()
        if defaultSystemAliases.contains(lower) && genericFamilyMap[lower] == nil {
            return Font.system(size: size, weight: weight)
        }

        #if canImport(UIKit)
        let uiWeight = mapSwiftUIWeightToUIKit(weight)
        let uiFont = resolveUIFont(family: family, weight: uiWeight, size: size)
        // Font(UIFont) preserves all attributes including weight
        return Font(uiFont)
        #elseif canImport(AppKit)
        let nsWeight = mapSwiftUIWeightToAppKit(weight)
        let nsFont = resolveNSFont(family: family, weight: nsWeight, size: size)
        return Font(nsFont)
        #else
        return Font.custom(family, size: size).weight(weight)
        #endif
    }

    // MARK: - Weight Mapping Utilities

    /// Maps a CSS font weight string ("100"-"900") to a SwiftUI Font.Weight.
    static func swiftUIWeight(from cssWeight: String) -> Font.Weight {
        switch cssWeight {
        case "100": return .ultraLight
        case "200": return .thin
        case "300": return .light
        case "400": return .regular
        case "500": return .medium
        case "600": return .semibold
        case "700": return .bold
        case "800": return .heavy
        case "900": return .black
        default:    return .regular
        }
    }

    #if canImport(UIKit)
    /// Maps a CSS font weight string to UIFont.Weight.
    static func uiKitWeight(from cssWeight: String) -> UIFont.Weight {
        switch cssWeight {
        case "100": return .ultraLight
        case "200": return .thin
        case "300": return .light
        case "400": return .regular
        case "500": return .medium
        case "600": return .semibold
        case "700": return .bold
        case "800": return .heavy
        case "900": return .black
        default:    return .regular
        }
    }

    /// Maps SwiftUI Font.Weight to UIFont.Weight.
    private static func mapSwiftUIWeightToUIKit(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }
    #endif

    #if canImport(AppKit)
    /// Maps a CSS font weight string to NSFont.Weight.
    static func appKitWeight(from cssWeight: String) -> NSFont.Weight {
        switch cssWeight {
        case "100": return .ultraLight
        case "200": return .thin
        case "300": return .light
        case "400": return .regular
        case "500": return .medium
        case "600": return .semibold
        case "700": return .bold
        case "800": return .heavy
        case "900": return .black
        default:    return .regular
        }
    }

    /// Maps SwiftUI Font.Weight to NSFont.Weight.
    private static func mapSwiftUIWeightToAppKit(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }
    #endif
}
