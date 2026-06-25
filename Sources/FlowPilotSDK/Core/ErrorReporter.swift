import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Error Report Payload

/// Wire payload for an internal SDK error report.
///
/// Property names are camelCase and rely on `JSONEncoder.keyEncodingStrategy =
/// .convertToSnakeCase` (the same encoder the rest of the SDK uses) to produce
/// the snake_case keys the backend expects (`sdkVersion` → `sdk_version`,
/// `errorCode` → `error_code`, etc.). Only `platform`, `sdkVersion`, and at
/// least one of `errorCode`/`message` are required; everything else is omitted
/// from the JSON when `nil`.
struct SDKErrorReport: Encodable, Sendable {
    let platform: String
    let sdkVersion: String
    let environment: String?
    let errorCode: String?
    let message: String
    let name: String?
    let level: String
    let appVersion: String?
    let osVersion: String?
    let deviceModel: String?
    let userId: String?
    let sessionId: String?
    let stack: String?
    let context: [String: String]?
    // breadcrumbs intentionally omitted for v1; the backend treats it as optional.
}

// MARK: - Error Reporter

/// Bounded, fire-and-forget reporter for the SDK's OWN internal failures.
///
/// This is **not** a crash reporter and installs no global signal/exception
/// handlers — it only forwards errors the SDK explicitly hands it, embedded in
/// a customer app, so it is deliberately unobtrusive:
///
/// - **Never throws / never blocks the caller.** `report(...)` returns
///   immediately; the POST runs on a detached, low-priority task and every
///   failure is swallowed (no rethrow, no propagation into the failing path).
/// - **Never retries.** A failed report is dropped — no retry storms.
/// - **Bounded.** Identical reports (same `error_code` + `message`) are deduped
///   within a 60s window, and the total number of reports is capped per
///   launch/session (default 25) to prevent floods.
/// - **Opt-out.** When `FlowPilotConfiguration.disableErrorReporting` is set the
///   reporter is constructed in a disabled state and `report(...)` is a no-op.
///
/// Internal diagnostics use `Logger.debug` only — never `Logger.error` — to
/// avoid any feedback loop back into the reporting path.
final class ErrorReporter: @unchecked Sendable {
    // MARK: Configuration

    private let enabled: Bool
    private let baseURL: String
    private let apiKey: String
    private let appId: String
    private let environmentName: String
    private let session: URLSession

    /// Window within which an identical (code + message) report is suppressed.
    private let dedupeWindow: TimeInterval
    /// Hard cap on the number of reports sent for the lifetime of this reporter
    /// (i.e. per SDK launch). Once reached, all further reports are dropped.
    private let maxReports: Int

    // MARK: Bounded-state (guarded by `stateLock`)

    private let stateLock = NSLock()
    /// Maps a report key (code|message) to the last time it was sent.
    private var lastSentByKey: [String: Date] = [:]
    /// Total reports actually dispatched so far.
    private var sentCount = 0

    // MARK: Init

    /// - Parameters:
    ///   - enabled: When `false` (the opt-out), every `report` is a no-op and no
    ///     network resources are used.
    ///   - baseURL: The same base URL the rest of the SDK uses (already ends in
    ///     `/v1`); the reporter appends `/apps/{appId}/sdk-errors`.
    ///   - apiKey: Workspace API key (sent as `Authorization: Bearer`).
    ///   - appId: App identifier — used in the path.
    ///   - environmentName: Human-readable environment name (e.g. "production").
    ///   - dedupeWindow: Seconds within which an identical report is suppressed.
    ///   - maxReports: Hard cap on reports per launch.
    /// Test seam: when set, an admitted report is handed to this sink **instead**
    /// of being POSTed. Lets unit tests exercise dedupe/cap/payload building with
    /// no network. Production code never sets it (the reporter hits the network).
    private let testSink: (@Sendable (SDKErrorReport) -> Void)?

    init(
        enabled: Bool,
        baseURL: String,
        apiKey: String,
        appId: String,
        environmentName: String,
        dedupeWindow: TimeInterval = 60,
        maxReports: Int = 25,
        testSink: (@Sendable (SDKErrorReport) -> Void)? = nil
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.appId = appId
        self.environmentName = environmentName
        self.dedupeWindow = dedupeWindow
        self.maxReports = maxReports
        self.testSink = testSink

        // A dedicated, short-fused session. Reporting must never hold the app's
        // network up: it doesn't wait for connectivity and times out quickly.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Build a report from a Swift `Error` and dispatch it fire-and-forget.
    ///
    /// Maps `FlowPilotError` → `error_code` (`code.rawValue`) + `context`; for a
    /// plain `Error` the code is left `nil` and the type name is used as `name`.
    /// `extraContext` is merged over (and wins against) the error's own context.
    func report(
        _ error: Error,
        code: String? = nil,
        level: String = "error",
        extraContext: [String: String]? = nil
    ) {
        guard enabled else { return }

        let resolvedCode: String?
        var mergedContext: [String: String] = [:]
        let name: String
        var message: String

        if let fpError = error as? FlowPilotError {
            resolvedCode = code ?? fpError.code.rawValue
            message = fpError.message
            name = "FlowPilotError"
            if let ctx = fpError.context {
                for (k, v) in ctx { mergedContext[k] = v }
            }
            // Carry the underlying error's type name into the message tail so the
            // backend/Sentry sees the real root cause (e.g. DecodingError).
            if let underlying = fpError.underlyingError {
                message += " (underlying: \(type(of: underlying)))"
            }
        } else {
            resolvedCode = code
            message = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            name = String(describing: type(of: error))
        }

        if let extra = extraContext {
            for (k, v) in extra { mergedContext[k] = v }
        }

        report(
            code: resolvedCode,
            message: message,
            name: name,
            level: level,
            context: mergedContext.isEmpty ? nil : mergedContext
        )
    }

    /// Build a report from primitive fields and dispatch it fire-and-forget.
    func report(
        code: String?,
        message: String,
        name: String? = nil,
        level: String = "error",
        context: [String: String]? = nil
    ) {
        guard enabled else { return }

        // Bounded gate: dedupe + cap. Done synchronously under the lock so two
        // concurrent reports can't both slip past the cap.
        guard admit(code: code, message: message) else { return }

        let report = buildReport(code: code, message: message, name: name, level: level, context: context)

        // Test seam: short-circuit the network in unit tests.
        if let testSink = testSink {
            testSink(report)
            return
        }

        // Fire-and-forget: detached so it never inherits or blocks the caller's
        // context, low priority so it never contends with the app's work.
        Task.detached(priority: .utility) { [weak self] in
            await self?.send(report)
        }
    }

    /// Assemble a wire payload from the given fields + ambient device/session
    /// metadata. Pure (modulo `SessionManager.shared`), so tests can assert on it.
    func buildReport(
        code: String?,
        message: String,
        name: String?,
        level: String,
        context: [String: String]?
    ) -> SDKErrorReport {
        SDKErrorReport(
            platform: "ios",
            sdkVersion: FlowPilotSDK.version,
            environment: environmentName,
            errorCode: code,
            message: message,
            name: name,
            level: (level == "warning") ? "warning" : "error",
            appVersion: Self.appVersion,
            osVersion: Self.osVersion,
            deviceModel: Self.deviceModel,
            userId: SessionManager.shared.userId,
            sessionId: SessionManager.shared.sessionId,
            stack: Thread.callStackSymbols.joined(separator: "\n"),
            context: context
        )
    }

    // MARK: - Bounding (dedupe + cap)

    /// Returns `true` if a report with this key may be sent right now, recording
    /// the send. Returns `false` when the per-launch cap is hit or an identical
    /// report was sent within the dedupe window.
    private func admit(code: String?, message: String) -> Bool {
        let key = (code ?? "") + "|" + message
        let now = Date()

        stateLock.lock()
        defer { stateLock.unlock() }

        if sentCount >= maxReports {
            Logger.shared.debug("ErrorReporter: per-launch report cap (\(maxReports)) reached; dropping report.")
            return false
        }

        if let last = lastSentByKey[key], now.timeIntervalSince(last) < dedupeWindow {
            Logger.shared.debug("ErrorReporter: duplicate report within \(Int(dedupeWindow))s window; dropping.")
            return false
        }

        lastSentByKey[key] = now
        sentCount += 1

        // Keep the dedupe map from growing unbounded across a long session: once
        // it exceeds 2x the cap, drop entries older than the dedupe window.
        if lastSentByKey.count > maxReports * 2 {
            lastSentByKey = lastSentByKey.filter { now.timeIntervalSince($0.value) < dedupeWindow }
        }

        return true
    }

    // MARK: - Network (fire-and-forget, no retry, swallow everything)

    private func send(_ report: SDKErrorReport) async {
        guard let url = URL(string: "\(baseURL)/apps/\(appId)/sdk-errors") else {
            Logger.shared.debug("ErrorReporter: invalid URL; skipping report.")
            return
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = HTTPMethod.POST.rawValue
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("FlowPilotSDK/\(FlowPilotSDK.version) iOS", forHTTPHeaderField: "User-Agent")

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(report)

            // Backend returns 202 Accepted with NO body — we ignore the response
            // bytes entirely and never decode anything. No retry on any outcome.
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                Logger.shared.debug("ErrorReporter: sent report, status \(http.statusCode).")
            }
        } catch {
            // Swallow: reporting must never surface to the host app.
            Logger.shared.debug("ErrorReporter: report send failed (swallowed): \(error.localizedDescription)")
        }
    }

    // MARK: - Device / app metadata

    private static let appVersion: String? =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    private static let osVersion: String? = {
        #if canImport(UIKit)
        return "iOS " + UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }()

    /// The hardware identifier (e.g. "iPhone16,2") via `uname`. Falls back to the
    /// human-readable `UIDevice.model` ("iPhone") on simulators where the
    /// identifier is the host arch.
    private static let deviceModel: String? = {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        if identifier.isEmpty || identifier == "x86_64" || identifier == "arm64" {
            #if canImport(UIKit)
            return UIDevice.current.model
            #else
            return identifier.isEmpty ? nil : identifier
            #endif
        }
        return identifier
    }()
}
