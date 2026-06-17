import SwiftUI

// MARK: - Custom Component Definition

/// Definition for a custom component
public struct CustomComponentDefinition: Sendable {
    /// Declared input types (for editor validation)
    /// Keys are input names, values are the expected types
    public let inputs: [String: VariableType]?

    /// Declared output schemas - defines what events this component can emit
    /// The editor uses this to show available events for binding actions
    public let outputs: [String: OutputSchema]?

    /// Factory to create the view
    /// Receives resolved inputs and a context for emitting events
    public let factory: @Sendable @MainActor (CustomComponentProps, CustomComponentContext) -> AnyView

    public init(
        inputs: [String: VariableType]? = nil,
        outputs: [String: OutputSchema]? = nil,
        factory: @escaping @Sendable @MainActor (CustomComponentProps, CustomComponentContext) -> AnyView
    ) {
        self.inputs = inputs
        self.outputs = outputs
        self.factory = factory
    }
}

// MARK: - Output Schema

/// Output schema for custom components
/// Defines what events a custom component can emit and their payload structure
public struct OutputSchema: Sendable {
    /// Human-readable description of when this event fires
    public let description: String?

    /// Expected payload structure - keys are field names, values are types
    /// Used for validation when component emits this event
    public let payload: [String: VariableType]?

    public init(description: String? = nil, payload: [String: VariableType]? = nil) {
        self.description = description
        self.payload = payload
    }
}

// MARK: - Input Value (Unified Input Model)

/// Represents a single input to a custom component
/// Can be either a bound variable or a constant value
public enum ComponentInputValue: Codable, Sendable {
    /// Bound to a variable path (reactive)
    case bind(String)

    /// Constant value (static)
    case value(VariableValue)

    enum CodingKeys: String, CodingKey {
        case bind, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Check for "bind" key first
        if let bindPath = try container.decodeIfPresent(String.self, forKey: .bind) {
            self = .bind(bindPath)
            return
        }

        // Check for "value" key
        if container.contains(.value) {
            // Try to decode as various types
            if let stringVal = try? container.decode(String.self, forKey: .value) {
                self = .value(.string(stringVal))
                return
            }
            if let boolVal = try? container.decode(Bool.self, forKey: .value) {
                self = .value(.boolean(boolVal))
                return
            }
            if let numVal = try? container.decode(Double.self, forKey: .value) {
                self = .value(.number(numVal))
                return
            }
            if let intVal = try? container.decode(Int.self, forKey: .value) {
                self = .value(.number(Double(intVal)))
                return
            }
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "ComponentInputValue must have either 'bind' or 'value' key"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bind(let path):
            try container.encode(path, forKey: .bind)
        case .value(let val):
            try container.encode(val, forKey: .value)
        }
    }
}

// MARK: - Custom Component Props

/// Props passed to custom component factory
/// All inputs are unified - both bound variables and constants
///
/// **Important**: These accessors are read-only views over validated inputs.
/// They will warn in debug builds when falling back to defaults due to:
/// - Missing keys
/// - Type mismatches
public struct CustomComponentProps: Sendable {
    /// All resolved inputs (unified model)
    /// Includes both variable-bound inputs and constant values
    public let inputs: [String: VariableValue]

    public init(inputs: [String: VariableValue]) {
        self.inputs = inputs
    }

    // MARK: - Convenience Accessors (Read-Only, Validated)

    /// Get a string input value
    public func string(_ key: String) -> String? {
        guard let value = inputs[key] else { return nil }
        guard let result = value.stringValue else {
            Logger.shared.warn("CustomComponentProps: Key '\(key)' exists but is not a string (actual type: \(value.typeName))")
            return nil
        }
        return result
    }

    /// Get a string input value with default
    /// Warns if key exists but has wrong type (schema mismatch)
    public func string(_ key: String, default defaultValue: String) -> String {
        guard let value = inputs[key] else {
            Logger.shared.debug("CustomComponentProps: Key '\(key)' not found, using default")
            return defaultValue
        }
        guard let result = value.stringValue else {
            Logger.shared.warn("CustomComponentProps: Key '\(key)' type mismatch - expected string, got \(value.typeName). Using default.")
            return defaultValue
        }
        return result
    }

    /// Get a number input value
    public func number(_ key: String) -> Double? {
        guard let value = inputs[key] else { return nil }
        guard let result = value.numberValue else {
            Logger.shared.warn("CustomComponentProps: Key '\(key)' exists but is not a number (actual type: \(value.typeName))")
            return nil
        }
        return result
    }

    /// Get a number input value with default
    /// Warns if key exists but has wrong type (schema mismatch)
    public func number(_ key: String, default defaultValue: Double) -> Double {
        guard let value = inputs[key] else {
            Logger.shared.debug("CustomComponentProps: Key '\(key)' not found, using default")
            return defaultValue
        }
        guard let result = value.numberValue else {
            Logger.shared.warn("CustomComponentProps: Key '\(key)' type mismatch - expected number, got \(value.typeName). Using default.")
            return defaultValue
        }
        return result
    }

    /// Get a boolean input value
    public func bool(_ key: String) -> Bool? {
        guard let value = inputs[key] else { return nil }
        guard let result = value.boolValue else {
            Logger.shared.warn("CustomComponentProps: Key '\(key)' exists but is not a boolean (actual type: \(value.typeName))")
            return nil
        }
        return result
    }

    /// Get a boolean input value with default
    /// Warns if key exists but has wrong type (schema mismatch)
    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = inputs[key] else {
            Logger.shared.debug("CustomComponentProps: Key '\(key)' not found, using default")
            return defaultValue
        }
        guard let result = value.boolValue else {
            Logger.shared.warn("CustomComponentProps: Key '\(key)' type mismatch - expected boolean, got \(value.typeName). Using default.")
            return defaultValue
        }
        return result
    }

    /// Get an integer input value
    public func int(_ key: String) -> Int? {
        guard let value = inputs[key] else { return nil }
        guard let result = value.intValue else {
            Logger.shared.warn("CustomComponentProps: Key '\(key)' exists but is not a number (actual type: \(value.typeName))")
            return nil
        }
        return result
    }

    /// Get an integer input value with default
    /// Warns if key exists but has wrong type (schema mismatch)
    public func int(_ key: String, default defaultValue: Int) -> Int {
        guard let value = inputs[key] else {
            Logger.shared.debug("CustomComponentProps: Key '\(key)' not found, using default")
            return defaultValue
        }
        guard let result = value.intValue else {
            Logger.shared.warn("CustomComponentProps: Key '\(key)' type mismatch - expected number, got \(value.typeName). Using default.")
            return defaultValue
        }
        return result
    }
}

// MARK: - Custom Component Context

/// Restricted context for custom components
/// Custom components are "dumb renderers" that only emit intent - FlowPilot decides what to do
public final class CustomComponentContext: @unchecked Sendable {
    private let emitHandler: @Sendable (String, [String: Any]?) -> Void
    private let outputSchemas: [String: OutputSchema]?
    private let componentType: String

    /// Container size available to the component
    public let containerSize: CGSize

    /// Container constraints
    public let containerConstraints: ContainerConstraints

    public struct ContainerConstraints: Sendable {
        public let minWidth: Double?
        public let maxWidth: Double?
        public let minHeight: Double?
        public let maxHeight: Double?
        public let supportsIntrinsicSize: Bool

        public init(
            minWidth: Double? = nil,
            maxWidth: Double? = nil,
            minHeight: Double? = nil,
            maxHeight: Double? = nil,
            supportsIntrinsicSize: Bool = true
        ) {
            self.minWidth = minWidth
            self.maxWidth = maxWidth
            self.minHeight = minHeight
            self.maxHeight = maxHeight
            self.supportsIntrinsicSize = supportsIntrinsicSize
        }
    }

    public init(
        componentType: String,
        containerSize: CGSize,
        containerConstraints: ContainerConstraints,
        outputSchemas: [String: OutputSchema]?,
        emitHandler: @escaping @Sendable (String, [String: Any]?) -> Void
    ) {
        self.componentType = componentType
        self.containerSize = containerSize
        self.containerConstraints = containerConstraints
        self.outputSchemas = outputSchemas
        self.emitHandler = emitHandler
    }

    /// Emit a named event with optional payload
    ///
    /// The event enters FlowPilot's interaction system. The editor defines what actions
    /// happen in response (navigate, setVariable, track, etc).
    ///
    /// **Important**: Payloads are validated against the declared OutputSchema.
    /// If validation fails, a warning is logged and the event is still emitted
    /// (to avoid breaking flows), but this indicates a schema mismatch.
    ///
    /// - Parameters:
    ///   - eventName: Name of the event (must match a declared output)
    ///   - payload: Optional payload data (must match declared schema)
    public func emit(_ eventName: String, payload: [String: Any]? = nil) {
        // Validate event name against declared outputs
        if let schemas = outputSchemas {
            guard let schema = schemas[eventName] else {
                Logger.shared.warn(
                    "Custom component '\(componentType)' emitted undeclared event '\(eventName)'. " +
                    "Declared outputs: \(Array(schemas.keys))"
                )
                // Still emit - don't break flows, just warn
                emitHandler(eventName, payload)
                return
            }

            // Validate payload against schema
            if let expectedPayload = schema.payload {
                validatePayload(payload, against: expectedPayload, for: eventName)
            } else if payload != nil {
                Logger.shared.warn(
                    "Custom component '\(componentType)' event '\(eventName)' sent payload " +
                    "but schema declares no payload"
                )
            }
        }

        emitHandler(eventName, payload)
    }

    /// Emit an event without payload (convenience for events like "dismiss")
    public func emit(_ eventName: String) {
        emit(eventName, payload: nil)
    }

    // MARK: - Payload Validation

    private func validatePayload(
        _ payload: [String: Any]?,
        against schema: [String: VariableType],
        for eventName: String
    ) {
        guard let payload = payload else {
            if !schema.isEmpty {
                Logger.shared.warn(
                    "Custom component '\(componentType)' event '\(eventName)' missing payload. " +
                    "Expected keys: \(Array(schema.keys))"
                )
            }
            return
        }

        // Check for missing keys
        for (key, expectedType) in schema {
            guard let value = payload[key] else {
                Logger.shared.warn(
                    "Custom component '\(componentType)' event '\(eventName)' missing key '\(key)' " +
                    "(expected \(expectedType.rawValue))"
                )
                continue
            }

            // Validate type
            let isValid: Bool
            switch expectedType {
            case .string:
                isValid = value is String
            case .number:
                isValid = value is Double || value is Int || value is Float
            case .boolean:
                isValid = value is Bool
            case .list:
                isValid = value is [Any]
            }

            if !isValid {
                Logger.shared.warn(
                    "Custom component '\(componentType)' event '\(eventName)' key '\(key)' " +
                    "has wrong type. Expected \(expectedType.rawValue), got \(type(of: value))"
                )
            }
        }

        // Check for extra keys (warning only, not an error)
        let extraKeys = Set(payload.keys).subtracting(Set(schema.keys))
        if !extraKeys.isEmpty {
            Logger.shared.debug(
                "Custom component '\(componentType)' event '\(eventName)' has extra keys: \(extraKeys)"
            )
        }
    }
}

// MARK: - Custom Screen Definition

/// Definition for a custom screen
public struct CustomScreenDefinition: Sendable {
    /// Declared input types
    public let inputs: [String: VariableType]?

    /// Declared output schemas
    public let outputs: [String: OutputSchema]?

    /// Factory to create the view
    public let factory: @Sendable @MainActor (CustomScreenParams, CustomScreenContext) -> AnyView

    public init(
        inputs: [String: VariableType]? = nil,
        outputs: [String: OutputSchema]? = nil,
        factory: @escaping @Sendable @MainActor (CustomScreenParams, CustomScreenContext) -> AnyView
    ) {
        self.inputs = inputs
        self.outputs = outputs
        self.factory = factory
    }
}

// MARK: - Custom Screen Params

/// Parameters passed to custom screen factory
public struct CustomScreenParams: Sendable {
    /// All resolved inputs (unified model)
    public let inputs: [String: VariableValue]

    public init(inputs: [String: VariableValue]) {
        self.inputs = inputs
    }

    // MARK: - Convenience Accessors

    public func string(_ key: String) -> String? {
        inputs[key]?.stringValue
    }

    public func string(_ key: String, default defaultValue: String) -> String {
        inputs[key]?.stringValue ?? defaultValue
    }

    public func number(_ key: String) -> Double? {
        inputs[key]?.numberValue
    }

    public func number(_ key: String, default defaultValue: Double) -> Double {
        inputs[key]?.numberValue ?? defaultValue
    }

    public func bool(_ key: String) -> Bool? {
        inputs[key]?.boolValue
    }

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        inputs[key]?.boolValue ?? defaultValue
    }
}

// MARK: - Custom Screen Context

/// Restricted context for custom screens
/// Like components, screens only emit intent - FlowPilot decides what to do
public final class CustomScreenContext: @unchecked Sendable {
    private let emitHandler: @Sendable (String, [String: Any]?) -> Void
    private let setZonesVisibleHandler: @Sendable (Bool) -> Void
    private let outputSchemas: [String: OutputSchema]?
    private let screenId: String

    public init(
        screenId: String,
        outputSchemas: [String: OutputSchema]?,
        emitHandler: @escaping @Sendable (String, [String: Any]?) -> Void,
        setZonesVisibleHandler: @escaping @Sendable (Bool) -> Void
    ) {
        self.screenId = screenId
        self.outputSchemas = outputSchemas
        self.emitHandler = emitHandler
        self.setZonesVisibleHandler = setZonesVisibleHandler
    }

    /// Emit a named event with optional payload
    /// The event enters FlowPilot's interaction system for the editor to handle
    public func emit(_ eventName: String, payload: [String: Any]? = nil) {
        // Validate against schema (same logic as component context)
        if let schemas = outputSchemas {
            guard let schema = schemas[eventName] else {
                Logger.shared.warn(
                    "Custom screen '\(screenId)' emitted undeclared event '\(eventName)'. " +
                    "Declared outputs: \(Array(schemas.keys))"
                )
                emitHandler(eventName, payload)
                return
            }

            if let expectedPayload = schema.payload, let payload = payload {
                validatePayload(payload, against: expectedPayload, for: eventName)
            }
        }

        emitHandler(eventName, payload)
    }

    /// Emit an event without payload
    public func emit(_ eventName: String) {
        emit(eventName, payload: nil)
    }

    /// Request persistent zones visibility change
    public func setZonesVisible(_ visible: Bool) {
        setZonesVisibleHandler(visible)
    }

    /// @deprecated Use setZonesVisible. Kept for backward compatibility.
    public func setChromeVisible(_ visible: Bool) {
        setZonesVisibleHandler(visible)
    }

    private func validatePayload(
        _ payload: [String: Any],
        against schema: [String: VariableType],
        for eventName: String
    ) {
        for (key, expectedType) in schema {
            guard let value = payload[key] else {
                Logger.shared.warn(
                    "Custom screen '\(screenId)' event '\(eventName)' missing key '\(key)'"
                )
                continue
            }

            let isValid: Bool
            switch expectedType {
            case .string:
                isValid = value is String
            case .number:
                isValid = value is Double || value is Int || value is Float
            case .boolean:
                isValid = value is Bool
            case .list:
                isValid = value is [Any]
            }

            if !isValid {
                Logger.shared.warn(
                    "Custom screen '\(screenId)' event '\(eventName)' key '\(key)' " +
                    "has wrong type. Expected \(expectedType.rawValue)"
                )
            }
        }
    }
}
