import Foundation

// MARK: - Variable Operations

/// Operations that can be performed on variables
enum VariableOperation: String, Sendable {
    // Boolean operations
    case setTrue = "set_true"
    case setFalse = "set_false"
    case toggle = "toggle"

    // Number operations
    case set = "set"
    case increment = "increment"
    case decrement = "decrement"
    case multiply = "multiply"
    case divide = "divide"
    case reset = "reset"

    // String operations
    case append = "append"
    case prepend = "prepend"
    case clear = "clear"

    // List operations
    case add = "add"
    case remove = "remove"
    // toggle is reused for lists
}

// MARK: - Variable Operation Executor

/// Executes variable operations
struct VariableOperationExecutor: Sendable {

    /// Apply an operation to a variable
    @discardableResult
    static func apply(
        operation: String,
        key: String,
        operand: VariableValue?,
        store: VariableStore
    ) -> Bool {
        guard let definition = store.getDefinition(key) else {
            Logger.shared.warn("Variable not found: \(key)")
            return false
        }

        guard definition.writable else {
            Logger.shared.warn("Cannot modify non-writable variable: \(key)")
            return false
        }

        let current = store.get(key)
        let newValue = computeNewValue(
            operation: operation,
            current: current,
            operand: operand,
            definition: definition
        )

        guard let value = newValue else {
            Logger.shared.warn("Failed to compute new value for operation \(operation) on \(key)")
            return false
        }

        return store.set(key, value: value)
    }

    private static func computeNewValue(
        operation: String,
        current: VariableValue?,
        operand: VariableValue?,
        definition: FlowVariable
    ) -> VariableValue? {
        switch operation {
        // Boolean operations
        case "set_true":
            return .boolean(true)

        case "set_false":
            return .boolean(false)

        case "toggle":
            // Toggle for list (add/remove item). A multi-select question fires
            // `toggle` with the option value (a string) as the operand, so this
            // must run before the boolean branch — an empty-list variable can
            // decode as `.numberList([])` whose `boolValue` is nil anyway, but
            // being explicit keeps list toggles off the boolean path.
            if let operand = operand, current == nil || current?.isList == true {
                return toggleInList(list: current, item: operand)
            }
            // Toggle for boolean
            if let boolValue = current?.boolValue {
                return .boolean(!boolValue)
            }
            return nil

        // Number operations
        case "set":
            return operand

        case "increment":
            guard let currentNum = current?.numberValue else { return nil }
            let amount = operand?.numberValue ?? 1
            return .number(currentNum + amount)

        case "decrement":
            guard let currentNum = current?.numberValue else { return nil }
            let amount = operand?.numberValue ?? 1
            return .number(currentNum - amount)

        case "multiply":
            guard let currentNum = current?.numberValue,
                  let factor = operand?.numberValue else { return nil }
            return .number(currentNum * factor)

        case "divide":
            guard let currentNum = current?.numberValue,
                  let divisor = operand?.numberValue,
                  divisor != 0 else { return nil }
            return .number(currentNum / divisor)

        case "reset":
            return definition.defaultValue ?? definition.type.defaultValue

        // String operations
        case "append":
            guard let currentStr = current?.stringValue,
                  let appendStr = operand?.stringValue else { return nil }
            return .string(currentStr + appendStr)

        case "prepend":
            guard let currentStr = current?.stringValue,
                  let prependStr = operand?.stringValue else { return nil }
            return .string(prependStr + currentStr)

        case "clear":
            switch definition.type {
            case .string: return .string("")
            case .list: return .stringList([])
            default: return nil
            }

        // List operations
        case "add":
            return addToList(list: current, item: operand, listItemType: definition.listItemType)

        case "remove":
            return removeFromList(list: current, item: operand)

        default:
            Logger.shared.warn("Unknown operation: \(operation)")
            return nil
        }
    }

    // MARK: - List Helpers

    private static func addToList(list: VariableValue?, item: VariableValue?, listItemType: ListItemType?) -> VariableValue? {
        guard let item = item else { return list }

        switch (list, item) {
        case (.stringList(var arr), .string(let s)):
            arr.append(s)
            return .stringList(arr)

        case (.numberList(var arr), .number(let n)):
            arr.append(n)
            return .numberList(arr)

        case (.booleanList(var arr), .boolean(let b)):
            arr.append(b)
            return .booleanList(arr)

        default:
            // Absent list, or an empty list that decoded as the wrong subtype:
            // seed a fresh list of the item's type. A populated mismatched list
            // is left untouched.
            let listIsEmptyOrNil = list.map { $0.isList && $0.isEmpty } ?? true
            guard listIsEmptyOrNil else { return list }
            return newList(seededWith: item)
        }
    }

    private static func removeFromList(list: VariableValue?, item: VariableValue?) -> VariableValue? {
        guard let list = list, let item = item else { return list }

        switch (list, item) {
        case (.stringList(var arr), .string(let s)):
            arr.removeAll { $0 == s }
            return .stringList(arr)

        case (.numberList(var arr), .number(let n)):
            arr.removeAll { $0 == n }
            return .numberList(arr)

        case (.booleanList(var arr), .boolean(let b)):
            arr.removeAll { $0 == b }
            return .booleanList(arr)

        default:
            return list
        }
    }

    /// Toggle an item in a list.
    ///
    /// If the existing list is `nil` or empty, adopt the item's element type and
    /// start a fresh list. This matters because an empty `[]` default (a
    /// multi-select with no preselected answers) decodes as `.numberList([])`
    /// via `VariableValue`'s decode order, so a string-valued option toggled
    /// into it would otherwise fall through to `default` and silently no-op —
    /// making the choices unselectable on device.
    private static func toggleInList(list: VariableValue?, item: VariableValue) -> VariableValue? {
        switch (list, item) {
        case (.stringList(var arr), .string(let s)):
            if arr.contains(s) {
                arr.removeAll { $0 == s }
            } else {
                arr.append(s)
            }
            return .stringList(arr)

        case (.numberList(var arr), .number(let n)):
            if arr.contains(n) {
                arr.removeAll { $0 == n }
            } else {
                arr.append(n)
            }
            return .numberList(arr)

        case (.booleanList(var arr), .boolean(let b)):
            if arr.contains(b) {
                arr.removeAll { $0 == b }
            } else {
                arr.append(b)
            }
            return .booleanList(arr)

        default:
            // Element type didn't match the list subtype. If the list is absent
            // or empty, seed a new list of the item's type; otherwise leave the
            // populated list untouched.
            let listIsEmptyOrNil = list.map { $0.isList && $0.isEmpty } ?? true
            guard listIsEmptyOrNil else { return list }
            return newList(seededWith: item)
        }
    }

    /// Build a single-element list matching the item's element type.
    private static func newList(seededWith item: VariableValue) -> VariableValue? {
        switch item {
        case .string(let s): return .stringList([s])
        case .number(let n): return .numberList([n])
        case .boolean(let b): return .booleanList([b])
        default: return nil
        }
    }
}
