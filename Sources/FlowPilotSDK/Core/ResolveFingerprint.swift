import Foundation
import CryptoKit

// MARK: - Resolve Fingerprint

/// A stable, identity-aware fingerprint of the inputs that affect *which* flow
/// the backend resolves for a placement. Used as part of the cache key so a
/// flow prefetched (or resolved) under one identity / attribute set is never
/// served to another.
///
/// The backend personalizes a resolve by `user_id` + `attributes` (targeting,
/// A/B bucketing, etc.). The on-disk cache, however, was historically keyed only
/// by placement, so a flow resolved while the user was anonymous could be served
/// verbatim to a later-identified user — the wrong targeting / wrong variant.
/// Mixing this fingerprint into the cache key closes that gap: a fresh (Tier 0)
/// hit only matches when identity + attributes are unchanged.
///
/// IMPORTANT: `sessionId` is deliberately **excluded**. It changes every launch,
/// so including it would make the on-disk cache unusable across launches (every
/// relaunch would miss). Only `userId` + targeting attributes participate.
///
/// `CryptoKit` ships from iOS 13 / macOS 10.15, comfortably within the SDK's
/// iOS 15 / macOS 12 floor, so this adds no third-party dependency.
enum ResolveFingerprint {
    /// Returns a short, deterministic hex digest of (`userId` + canonical attrs).
    ///
    /// The digest is stable for a given identity + attribute set: the same inputs
    /// always produce the same fingerprint, and any change to `userId` or any
    /// attribute value produces a different one. Attribute *ordering* never
    /// affects the result (keys are canonicalized below).
    static func make(userId: String, attributes: [String: Any]) -> String {
        let canonicalAttrs = canonicalJSON(attributes)
        // U+0001 is a control char that can't appear in a userId or JSON text,
        // so it's an unambiguous separator between the two fields.
        let material = "\(userId)\u{1}\(canonicalAttrs)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        // 16 hex chars (64 bits) is plenty to avoid collisions across the handful
        // of identities/attribute sets a single device sees, while keeping keys short.
        return String(hex.prefix(16))
    }

    /// Deterministic JSON for an arbitrary `[String: Any]` attribute bag.
    ///
    /// Uses sorted keys so attribute ordering never changes the digest. Bags that
    /// contain non-JSON scalar values (which `JSONSerialization` would reject) are
    /// coerced to a stable `key=String(describing:)` form as a last resort, so the
    /// fingerprint is always computable.
    private static func canonicalJSON(_ attributes: [String: Any]) -> String {
        if JSONSerialization.isValidJSONObject(attributes),
           let data = try? JSONSerialization.data(withJSONObject: attributes, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        // Fallback: stable string for bags containing non-JSON scalars.
        return attributes.keys.sorted()
            .map { "\($0)=\(String(describing: attributes[$0]!))" }
            .joined(separator: "&")
    }
}
