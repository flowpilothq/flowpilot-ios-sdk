import Foundation

// MARK: - Condition Evaluator

/// Evaluates conditions against the variable store
struct ConditionEvaluator: Sendable {

    /// Evaluate a condition against the variable store
    static func evaluate(_ condition: Condition, store: VariableStore) -> Bool {
        switch condition {
        case .equals(let left, let right):
            return evaluateEquals(varRef: left, right: right, store: store)

        case .notEquals(let left, let right):
            return !evaluateEquals(varRef: left, right: right, store: store)

        case .greaterThan(let left, let right):
            guard let value = store.get(left.var),
                  let number = value.numberValue else { return false }
            return number > right

        case .lessThan(let left, let right):
            guard let value = store.get(left.var),
                  let number = value.numberValue else { return false }
            return number < right

        case .greaterThanOrEquals(let left, let right):
            guard let value = store.get(left.var),
                  let number = value.numberValue else { return false }
            return number >= right

        case .lessThanOrEquals(let left, let right):
            guard let value = store.get(left.var),
                  let number = value.numberValue else { return false }
            return number <= right

        case .contains(let left, let right):
            return evaluateContains(varRef: left, right: right, store: store)

        case .notContains(let left, let right):
            return !evaluateContains(varRef: left, right: right, store: store)

        case .startsWith(let left, let right):
            guard let value = store.get(left.var),
                  let string = value.stringValue else { return false }
            return string.hasPrefix(right)

        case .endsWith(let left, let right):
            guard let value = store.get(left.var),
                  let string = value.stringValue else { return false }
            return string.hasSuffix(right)

        case .isEmpty(let left):
            guard let value = store.get(left.var) else { return true }
            return value.isEmpty

        case .isNotEmpty(let left):
            guard let value = store.get(left.var) else { return false }
            return !value.isEmpty

        case .and(let conditions):
            return conditions.allSatisfy { evaluate($0, store: store) }

        case .or(let conditions):
            return conditions.contains { evaluate($0, store: store) }

        case .not(let condition):
            return !evaluate(condition, store: store)
        }
    }

    // MARK: - Helpers

    private static func evaluateEquals(varRef: VarRef, right: ConditionValue, store: VariableStore) -> Bool {
        guard let value = store.get(varRef.var) else { return false }

        switch (value, right) {
        case (.string(let s), .string(let r)): return s == r
        case (.number(let n), .number(let r)): return n == r
        case (.boolean(let b), .boolean(let r)): return b == r
        default: return false
        }
    }

    private static func evaluateContains(varRef: VarRef, right: String, store: VariableStore) -> Bool {
        guard let value = store.get(varRef.var) else {
            Logger.shared.debug("evaluateContains - variable '\(varRef.var)' not found")
            return false
        }

        Logger.shared.debug("evaluateContains - variable '\(varRef.var)' = \(value), checking contains '\(right)'")

        switch value {
        case .string(let s):
            let result = s.contains(right)
            Logger.shared.debug("evaluateContains - string.contains result: \(result)")
            return result
        case .stringList(let arr):
            let result = arr.contains(right)
            Logger.shared.debug("evaluateContains - stringList.contains result: \(result), array: \(arr)")
            return result
        default:
            Logger.shared.debug("evaluateContains - value type not supported for contains: \(type(of: value))")
            return false
        }
    }
}

// MARK: - Property Value Resolution

/// Resolves PropertyValue<T> against the variable store
struct PropertyResolver: Sendable {

    /// Resolve a property value. String results that are theme token
    /// references ("token:primary", schema v9) — raw or produced by a
    /// conditional case — resolve against the flow palette seeded on the
    /// store.
    static func resolve<T>(_ property: PropertyValue<T>?, store: VariableStore) -> T? {
        let resolved = resolveRaw(property, store: store)
        if let token = resolved as? String, ThemeTokens.isRef(token) {
            return store.resolveThemeToken(token) as? T
        }
        return resolved
    }

    private static func resolveRaw<T>(_ property: PropertyValue<T>?, store: VariableStore) -> T? {
        guard let property = property else { return nil }

        switch property {
        case .static(let value):
            return value

        case .conditional(let cases, let defaultValue):
            // Evaluate cases in order
            for caseItem in cases {
                if ConditionEvaluator.evaluate(caseItem.when, store: store) {
                    return caseItem.value
                }
            }

            // No case matched - use default fallback
            return defaultValue
        }
    }

    /// Resolve a property value with a default
    static func resolve<T>(_ property: PropertyValue<T>?, store: VariableStore, default defaultValue: T) -> T {
        return resolve(property, store: store) ?? defaultValue
    }

    /// Resolve a string property with variable interpolation
    static func resolveString(_ property: PropertyValue<String>?, store: VariableStore) -> String? {
        guard let resolved = resolve(property, store: store) else { return nil }
        return store.interpolate(resolved)
    }

    /// Resolve a string property with variable interpolation and default
    static func resolveString(_ property: PropertyValue<String>?, store: VariableStore, default defaultValue: String) -> String {
        let resolved = resolve(property, store: store) ?? defaultValue
        return store.interpolate(resolved)
    }
}
