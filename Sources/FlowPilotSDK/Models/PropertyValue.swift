import Foundation

// MARK: - Property Value

/// A property value that can be static or conditional
/// Note: Simplified structure to avoid recursive generic types that cause Swift compiler crashes (Signal 11)
enum PropertyValue<T: Codable & Sendable>: Codable, Sendable {
    case `static`(T)
    case conditional(cases: [ConditionalCase<T>], defaultValue: T?)

    enum CodingKeys: String, CodingKey {
        case type, value, cases, `else`
    }

    init(from decoder: Decoder) throws {
        // First try to decode as a raw value (shorthand)
        if let container = try? decoder.singleValueContainer() {
            if let value = try? container.decode(T.self) {
                self = .static(value)
                return
            }
        }

        // Try as keyed container
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "static":
            let value = try container.decode(T.self, forKey: .value)
            self = .static(value)
        case "conditional":
            let cases = try container.decode([ConditionalCase<T>].self, forKey: .cases)
            // Handle `else` as either a raw value or a wrapped {"type":"static","value":...}
            let defaultValue = Self.decodeWrappedOrRawValue(from: container, forKey: .else)
            self = .conditional(cases: cases, defaultValue: defaultValue)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown PropertyValue type: \(type)")
            )
        }
    }

    /// Decode a value that might be wrapped in {"type":"static","value":...} or just raw
    private static func decodeWrappedOrRawValue(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> T? {
        // Try raw value first
        if let value = try? container.decodeIfPresent(T.self, forKey: key) {
            return value
        }

        // Try wrapped static value {"type":"static","value":...}
        if let wrapper = try? container.decodeIfPresent(WrappedStaticValue<T>.self, forKey: key) {
            return wrapper.value
        }

        return nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .static(let value):
            try container.encode("static", forKey: .type)
            try container.encode(value, forKey: .value)
        case .conditional(let cases, let defaultValue):
            try container.encode("conditional", forKey: .type)
            try container.encode(cases, forKey: .cases)
            try container.encodeIfPresent(defaultValue, forKey: .else)
        }
    }
}

// MARK: - Wrapped Static Value

/// Helper to decode {"type":"static","value":...} wrapped values
private struct WrappedStaticValue<T: Codable>: Codable {
    let value: T

    enum CodingKeys: String, CodingKey {
        case type, value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "static" else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected static type")
            )
        }
        value = try container.decode(T.self, forKey: .value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("static", forKey: .type)
        try container.encode(value, forKey: .value)
    }
}

// MARK: - Conditional Case

/// A conditional case within a PropertyValue
/// Note: value is T (not PropertyValue<T>) to avoid recursive generic that causes compiler crash
struct ConditionalCase<T: Codable & Sendable>: Codable, Sendable {
    let when: Condition
    let value: T
    let label: String?

    enum CodingKeys: String, CodingKey {
        case when, value, label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        when = try container.decode(Condition.self, forKey: .when)
        label = try container.decodeIfPresent(String.self, forKey: .label)

        // Try raw value first
        if let rawValue = try? container.decode(T.self, forKey: .value) {
            value = rawValue
        }
        // Try wrapped static value {"type":"static","value":...}
        else if let wrapper = try? container.decode(WrappedStaticValue<T>.self, forKey: .value) {
            value = wrapper.value
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unable to decode conditional case value")
            )
        }
    }
}

// MARK: - Condition

/// Condition for conditional values
indirect enum Condition: Codable, Sendable {
    // Equality operations
    case equals(left: VarRef, right: ConditionValue)
    case notEquals(left: VarRef, right: ConditionValue)

    // Numeric comparisons
    case greaterThan(left: VarRef, right: Double)
    case lessThan(left: VarRef, right: Double)
    case greaterThanOrEquals(left: VarRef, right: Double)
    case lessThanOrEquals(left: VarRef, right: Double)

    // String/Array operations
    case contains(left: VarRef, right: String)
    case notContains(left: VarRef, right: String)
    case startsWith(left: VarRef, right: String)
    case endsWith(left: VarRef, right: String)

    // Empty checks
    case isEmpty(left: VarRef)
    case isNotEmpty(left: VarRef)

    // Logical operators
    case and(conditions: [Condition])
    case or(conditions: [Condition])
    case not(condition: Condition)

    enum CodingKeys: String, CodingKey {
        case op, left, right, conditions, condition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(String.self, forKey: .op)

        switch op {
        case "equals":
            let left = try container.decode(VarRef.self, forKey: .left)
            let right = try container.decode(ConditionValue.self, forKey: .right)
            self = .equals(left: left, right: right)

        case "not_equals":
            let left = try container.decode(VarRef.self, forKey: .left)
            let right = try container.decode(ConditionValue.self, forKey: .right)
            self = .notEquals(left: left, right: right)

        case "greater_than":
            let left = try container.decode(VarRef.self, forKey: .left)
            let right = try container.decode(Double.self, forKey: .right)
            self = .greaterThan(left: left, right: right)

        case "less_than":
            let left = try container.decode(VarRef.self, forKey: .left)
            let right = try container.decode(Double.self, forKey: .right)
            self = .lessThan(left: left, right: right)

        case "greater_than_or_equals":
            let left = try container.decode(VarRef.self, forKey: .left)
            let right = try container.decode(Double.self, forKey: .right)
            self = .greaterThanOrEquals(left: left, right: right)

        case "less_than_or_equals":
            let left = try container.decode(VarRef.self, forKey: .left)
            let right = try container.decode(Double.self, forKey: .right)
            self = .lessThanOrEquals(left: left, right: right)

        case "contains":
            let left = try container.decode(VarRef.self, forKey: .left)
            let right = try container.decode(String.self, forKey: .right)
            self = .contains(left: left, right: right)

        case "not_contains":
            let left = try container.decode(VarRef.self, forKey: .left)
            let right = try container.decode(String.self, forKey: .right)
            self = .notContains(left: left, right: right)

        case "starts_with":
            let left = try container.decode(VarRef.self, forKey: .left)
            let right = try container.decode(String.self, forKey: .right)
            self = .startsWith(left: left, right: right)

        case "ends_with":
            let left = try container.decode(VarRef.self, forKey: .left)
            let right = try container.decode(String.self, forKey: .right)
            self = .endsWith(left: left, right: right)

        case "is_empty":
            let left = try container.decode(VarRef.self, forKey: .left)
            self = .isEmpty(left: left)

        case "is_not_empty":
            let left = try container.decode(VarRef.self, forKey: .left)
            self = .isNotEmpty(left: left)

        case "and":
            let conditions = try container.decode([Condition].self, forKey: .conditions)
            self = .and(conditions: conditions)

        case "or":
            let conditions = try container.decode([Condition].self, forKey: .conditions)
            self = .or(conditions: conditions)

        case "not":
            let condition = try container.decode(Condition.self, forKey: .condition)
            self = .not(condition: condition)

        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown condition operator: \(op)")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .equals(let left, let right):
            try container.encode("equals", forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .notEquals(let left, let right):
            try container.encode("not_equals", forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .greaterThan(let left, let right):
            try container.encode("greater_than", forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .lessThan(let left, let right):
            try container.encode("less_than", forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .greaterThanOrEquals(let left, let right):
            try container.encode("greater_than_or_equals", forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .lessThanOrEquals(let left, let right):
            try container.encode("less_than_or_equals", forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .contains(let left, let right):
            try container.encode("contains", forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .notContains(let left, let right):
            try container.encode("not_contains", forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .startsWith(let left, let right):
            try container.encode("starts_with", forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .endsWith(let left, let right):
            try container.encode("ends_with", forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .isEmpty(let left):
            try container.encode("is_empty", forKey: .op)
            try container.encode(left, forKey: .left)

        case .isNotEmpty(let left):
            try container.encode("is_not_empty", forKey: .op)
            try container.encode(left, forKey: .left)

        case .and(let conditions):
            try container.encode("and", forKey: .op)
            try container.encode(conditions, forKey: .conditions)

        case .or(let conditions):
            try container.encode("or", forKey: .op)
            try container.encode(conditions, forKey: .conditions)

        case .not(let condition):
            try container.encode("not", forKey: .op)
            try container.encode(condition, forKey: .condition)
        }
    }
}

// MARK: - Variable Reference

/// Reference to a variable
struct VarRef: Codable, Sendable {
    let `var`: String

    enum CodingKeys: String, CodingKey {
        case `var`
    }
}

// MARK: - Condition Value

/// Value used in condition comparisons
enum ConditionValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unable to decode ConditionValue")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }

    /// Compare with a VariableValue
    func matches(_ variableValue: VariableValue?) -> Bool {
        guard let variableValue = variableValue else { return false }

        switch (self, variableValue) {
        case (.string(let s1), .string(let s2)): return s1 == s2
        case (.number(let n1), .number(let n2)): return n1 == n2
        case (.boolean(let b1), .boolean(let b2)): return b1 == b2
        default: return false
        }
    }
}
