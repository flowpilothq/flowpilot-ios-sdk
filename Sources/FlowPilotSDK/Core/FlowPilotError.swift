import Foundation

// MARK: - Error Codes

/// Error codes for FlowPilot SDK errors
public enum FlowPilotErrorCode: String, Sendable {
    // Configuration errors
    case invalidApiKey = "invalid_api_key"
    case invalidAppId = "invalid_app_id"
    case sdkNotInitialized = "sdk_not_initialized"

    // Network errors
    case networkError = "network_error"
    case apiError = "api_error"
    case timeout = "timeout"
    case rateLimited = "rate_limited"

    // Resolution errors
    case placementNotFound = "placement_not_found"
    case flowNotFound = "flow_not_found"
    case targetingNotMet = "targeting_not_met"
    case frequencyLimitReached = "frequency_limit_reached"

    // Schema errors
    case unsupportedSchemaVersion = "unsupported_schema_version"
    case invalidFlowSchema = "invalid_flow_schema"

    // Rendering errors
    case componentRenderError = "component_render_error"
    case customComponentNotFound = "custom_component_not_found"
    case customScreenNotFound = "custom_screen_not_found"

    // Runtime errors
    case navigationError = "navigation_error"
    case variableError = "variable_error"
    case actionError = "action_error"
    case fatalActionError = "fatal_action_error"
    case actionChainTimeout = "action_chain_timeout"

    // Internal errors
    case internalError = "internal_error"
}

// MARK: - FlowPilot Error

/// Error type for FlowPilot SDK
public struct FlowPilotError: Error, Sendable, CustomStringConvertible {
    /// Error code
    public let code: FlowPilotErrorCode

    /// Human-readable error message
    public let message: String

    /// Underlying error if any
    public let underlyingError: Error?

    /// Additional context information
    public let context: [String: String]?

    public init(
        code: FlowPilotErrorCode,
        message: String,
        underlyingError: Error? = nil,
        context: [String: String]? = nil
    ) {
        self.code = code
        self.message = message
        self.underlyingError = underlyingError
        self.context = context
    }

    public var description: String {
        var desc = "FlowPilotError[\(code.rawValue)]: \(message)"
        if let underlying = underlyingError {
            desc += " (underlying: \(underlying.localizedDescription))"
        }
        if let ctx = context, !ctx.isEmpty {
            desc += " context: \(ctx)"
        }
        return desc
    }

    public var localizedDescription: String {
        return description
    }

    /// Returns true if this is a client error (4xx status code) that should not be retried
    public var isClientError: Bool {
        // Check if we have a status code in context
        guard let statusCodeStr = context?["status_code"],
              let statusCode = Int(statusCodeStr) else {
            return false
        }
        // 4xx errors are client errors - the request is malformed and retrying won't help
        return statusCode >= 400 && statusCode < 500
    }

    /// Returns true if this is a server error (5xx status code) that may be worth retrying
    public var isServerError: Bool {
        guard let statusCodeStr = context?["status_code"],
              let statusCode = Int(statusCodeStr) else {
            return false
        }
        return statusCode >= 500 && statusCode < 600
    }
}

// MARK: - Convenience Initializers

extension FlowPilotError {
    static func sdkNotInitialized() -> FlowPilotError {
        FlowPilotError(
            code: .sdkNotInitialized,
            message: "FlowPilot SDK has not been initialized. Call FlowPilot.configure() first."
        )
    }

    static func invalidApiKey(_ key: String) -> FlowPilotError {
        FlowPilotError(
            code: .invalidApiKey,
            message: "Invalid API key format. Expected format: fp_{environment}_{id}_{random}",
            context: ["key_prefix": String(key.prefix(10))]
        )
    }

    static func networkError(_ error: Error) -> FlowPilotError {
        FlowPilotError(
            code: .networkError,
            message: "Network request failed",
            underlyingError: error
        )
    }

    static func timeout() -> FlowPilotError {
        FlowPilotError(
            code: .timeout,
            message: "Request timed out"
        )
    }

    static func apiError(statusCode: Int, message: String) -> FlowPilotError {
        FlowPilotError(
            code: .apiError,
            message: message,
            context: ["status_code": "\(statusCode)"]
        )
    }

    static func rateLimited(retryAfter: TimeInterval?) -> FlowPilotError {
        var ctx: [String: String]? = nil
        if let retry = retryAfter {
            ctx = ["retry_after": "\(retry)"]
        }
        return FlowPilotError(
            code: .rateLimited,
            message: "Rate limit exceeded. Please retry later.",
            context: ctx
        )
    }

    static func unsupportedSchemaVersion(required: String, supported: String) -> FlowPilotError {
        FlowPilotError(
            code: .unsupportedSchemaVersion,
            message: "Flow requires schema \(required), but SDK only supports up to \(supported). Please update the app.",
            context: ["required": required, "supported": supported]
        )
    }

    static func invalidFlowSchema(_ reason: String) -> FlowPilotError {
        FlowPilotError(
            code: .invalidFlowSchema,
            message: "Invalid flow schema: \(reason)"
        )
    }

    static func customComponentNotFound(_ typeId: String) -> FlowPilotError {
        FlowPilotError(
            code: .customComponentNotFound,
            message: "Custom component '\(typeId)' not registered",
            context: ["component_type": typeId]
        )
    }

    static func customScreenNotFound(_ screenId: String) -> FlowPilotError {
        FlowPilotError(
            code: .customScreenNotFound,
            message: "Custom screen '\(screenId)' not registered",
            context: ["screen_id": screenId]
        )
    }

    static func navigationError(_ reason: String) -> FlowPilotError {
        FlowPilotError(
            code: .navigationError,
            message: "Navigation error: \(reason)"
        )
    }

    static func actionError(action: String, reason: String) -> FlowPilotError {
        FlowPilotError(
            code: .actionError,
            message: "Action '\(action)' failed: \(reason)",
            context: ["action": action]
        )
    }

    static func actionChainTimeout() -> FlowPilotError {
        FlowPilotError(
            code: .actionChainTimeout,
            message: "Action chain exceeded 5 second timeout limit"
        )
    }
}
