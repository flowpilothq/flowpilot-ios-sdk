import Foundation

// MARK: - Variable Value

/// Represents any valid variable value in FlowPilot
public enum VariableValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case stringList([String])
    case numberList([Double])
    case booleanList([Bool])

    // MARK: - Convenience Accessors

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let str):
            // Try to coerce string to number
            return Double(str)
        default:
            return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let str):
            // Try to coerce string to int (try Int first, then Double)
            if let intVal = Int(str) {
                return intVal
            }
            if let doubleVal = Double(str) {
                return Int(doubleVal)
            }
            return nil
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .boolean(let value):
            return value
        case .string(let str):
            // Try to coerce string to boolean
            let lower = str.lowercased()
            if lower == "true" || lower == "1" || lower == "yes" {
                return true
            }
            if lower == "false" || lower == "0" || lower == "no" {
                return false
            }
            return nil
        case .number(let value):
            // 0 = false, non-zero = true
            return value != 0
        default:
            return nil
        }
    }

    public var stringListValue: [String]? {
        if case .stringList(let value) = self { return value }
        return nil
    }

    public var numberListValue: [Double]? {
        if case .numberList(let value) = self { return value }
        return nil
    }

    public var booleanListValue: [Bool]? {
        if case .booleanList(let value) = self { return value }
        return nil
    }

    public var isEmpty: Bool {
        switch self {
        case .string(let s): return s.isEmpty
        case .number: return false
        case .boolean: return false
        case .stringList(let arr): return arr.isEmpty
        case .numberList(let arr): return arr.isEmpty
        case .booleanList(let arr): return arr.isEmpty
        }
    }

    // MARK: - Type Checking

    public var isString: Bool {
        if case .string = self { return true }
        return false
    }

    public var isNumber: Bool {
        if case .number = self { return true }
        return false
    }

    public var isBoolean: Bool {
        if case .boolean = self { return true }
        return false
    }

    public var isList: Bool {
        switch self {
        case .stringList, .numberList, .booleanList: return true
        default: return false
        }
    }

    /// Human-readable type name for debugging/warnings
    public var typeName: String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .stringList: return "stringList"
        case .numberList: return "numberList"
        case .booleanList: return "booleanList"
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case type, value
    }

    public init(from decoder: Decoder) throws {
        // Try single value container first
        // Note: Order is critical for JSONDecoder:
        // - Int/Double MUST come before Bool (JSONDecoder decodes numbers as Bool successfully!)
        // - Numbers MUST come before String (some decoders coerce numbers to strings)
        if let container = try? decoder.singleValueContainer() {
            // Try Int first (most specific numeric type)
            if let value = try? container.decode(Int.self) {
                self = .number(Double(value))
                return
            }
            // Try Double (handles floating point)
            if let value = try? container.decode(Double.self) {
                self = .number(value)
                return
            }
            // Try Bool AFTER numbers (JSONDecoder decodes 200 as true if we try Bool first!)
            if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
                return
            }
            // String last for primitives
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            // Arrays - try numeric arrays before bool arrays for same reason
            if let value = try? container.decode([Int].self) {
                self = .numberList(value.map { Double($0) })
                return
            }
            if let value = try? container.decode([Double].self) {
                self = .numberList(value)
                return
            }
            if let value = try? container.decode([Bool].self) {
                self = .booleanList(value)
                return
            }
            if let value = try? container.decode([String].self) {
                self = .stringList(value)
                return
            }
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unable to decode VariableValue")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .stringList(let value):
            try container.encode(value)
        case .numberList(let value):
            try container.encode(value)
        case .booleanList(let value):
            try container.encode(value)
        }
    }

    // MARK: - String Representation

    public var displayString: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(n))" : "\(n)"
        case .boolean(let b): return b ? "true" : "false"
        case .stringList(let arr): return arr.joined(separator: ", ")
        case .numberList(let arr): return arr.map { "\($0)" }.joined(separator: ", ")
        case .booleanList(let arr): return arr.map { $0 ? "true" : "false" }.joined(separator: ", ")
        }
    }
}

// MARK: - ExpressibleBy Protocols

extension VariableValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension VariableValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension VariableValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension VariableValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .boolean(value)
    }
}

extension VariableValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: String...) {
        self = .stringList(elements)
    }
}

// MARK: - Variable Type

/// Type of a variable
public enum VariableType: String, Codable, Sendable {
    case string
    case number
    case boolean
    case list

    /// Default value for this type
    var defaultValue: VariableValue {
        switch self {
        case .string: return .string("")
        case .number: return .number(0)
        case .boolean: return .boolean(false)
        case .list: return .stringList([])
        }
    }
}

/// Type of items in a list variable
enum ListItemType: String, Codable, Sendable {
    case string
    case number
    case boolean
}

// MARK: - Variable Lifecycle

/// Lifecycle of a variable
enum VariableLifecycle: String, Codable, Sendable {
    case `static`
    case session
}

// MARK: - Variable Source

/// Source of a variable's value
enum VariableSource: Codable, Sendable {
    case constant(VariableValue)
    case sdk(path: String)

    enum CodingKeys: String, CodingKey {
        case kind, value, path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        case "constant":
            let value = try container.decode(VariableValue.self, forKey: .value)
            self = .constant(value)
        case "sdk":
            let path = try container.decode(String.self, forKey: .path)
            self = .sdk(path: path)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown source kind: \(kind)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .constant(let value):
            try container.encode("constant", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .sdk(let path):
            try container.encode("sdk", forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

// MARK: - Flow Variable

/// Definition of a variable in a flow
struct FlowVariable: Codable, Sendable {
    public let key: String
    public let label: String?
    public let type: VariableType
    public let listItemType: ListItemType?
    public let scope: String // "global" for v1
    public let lifecycle: VariableLifecycle
    public let source: VariableSource
    public let writable: Bool
    public let defaultValue: VariableValue?

    enum CodingKeys: String, CodingKey {
        case key, label, type, listItemType, scope, lifecycle, source, writable, defaultValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        type = try container.decode(VariableType.self, forKey: .type)
        listItemType = try container.decodeIfPresent(ListItemType.self, forKey: .listItemType)
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "global"
        lifecycle = try container.decodeIfPresent(VariableLifecycle.self, forKey: .lifecycle) ?? .session
        writable = try container.decodeIfPresent(Bool.self, forKey: .writable) ?? true
        defaultValue = try container.decodeIfPresent(VariableValue.self, forKey: .defaultValue)

        // Try to decode source, or create a default based on the variable type
        if let decodedSource = try container.decodeIfPresent(VariableSource.self, forKey: .source) {
            source = decodedSource
        } else {
            // Default source based on variable type
            let defaultSourceValue: VariableValue
            switch type {
            case .string:
                defaultSourceValue = .string("")
            case .number:
                defaultSourceValue = .number(0)
            case .boolean:
                defaultSourceValue = .boolean(false)
            case .list:
                // Default to string list, but could be overridden by listItemType
                switch listItemType {
                case .number:
                    defaultSourceValue = .numberList([])
                case .boolean:
                    defaultSourceValue = .booleanList([])
                case .string, .none:
                    defaultSourceValue = .stringList([])
                }
            }
            source = .constant(defaultSourceValue)
        }
    }
}
