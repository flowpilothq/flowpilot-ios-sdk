import Foundation
import Combine

// MARK: - Variable Store

/// Reactive store for flow variables
final class VariableStore: @unchecked Sendable {
    private var definitions: [String: FlowVariable] = [:]
    private var definitionsByLabel: [String: FlowVariable] = [:]  // For label-based lookup
    private var values: [String: VariableValue] = [:]  // Keyed by variable key
    private var themeColors: [String: String] = [:]  // globalStyles.colors for token: resolution
    private let lock = NSLock()

    // Publishers for reactivity
    private let changeSubject = PassthroughSubject<(key: String, value: VariableValue), Never>()
    private let anyChangeSubject = PassthroughSubject<Void, Never>()

    /// Publisher for specific variable changes
    var changePublisher: AnyPublisher<(key: String, value: VariableValue), Never> {
        changeSubject.eraseToAnyPublisher()
    }

    /// Publisher for any variable change
    var anyChangePublisher: AnyPublisher<Void, Never> {
        anyChangeSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    /// Initialize the store with flow variables and SDK context
    func initialize(variables: [FlowVariable], sdkContext: SDKContext?) {
        lock.lock()
        defer { lock.unlock() }

        definitions.removeAll()
        definitionsByLabel.removeAll()
        values.removeAll()

        for variable in variables {
            definitions[variable.key] = variable

            // Also index by label for interpolation lookup
            if let label = variable.label, !label.isEmpty {
                definitionsByLabel[label] = variable
            }

            // Resolve initial value
            let value = resolveInitialValue(variable: variable, sdkContext: sdkContext)
            values[variable.key] = value

            let labelInfo = variable.label.map { " (label: \($0))" } ?? ""
            Logger.shared.verbose("Variable initialized: \(variable.key)\(labelInfo) = \(value.displayString)")
        }
    }

    private func resolveInitialValue(variable: FlowVariable, sdkContext: SDKContext?) -> VariableValue {
        switch variable.source {
        case .constant(let value):
            return value

        case .sdk(let path):
            // Look up in SDK context
            if let contextValue = sdkContext?[path] {
                return convertToVariableValue(contextValue, type: variable.type)
            }
            // Fall back to default or type default
            return variable.defaultValue ?? getTypeDefault(variable.type, listItemType: variable.listItemType)
        }
    }

    private func convertToVariableValue(_ value: Any, type: VariableType) -> VariableValue {
        switch type {
        case .string:
            if let s = value as? String { return .string(s) }
            return .string(String(describing: value))

        case .number:
            if let n = value as? Double { return .number(n) }
            if let n = value as? Int { return .number(Double(n)) }
            if let s = value as? String, let n = Double(s) { return .number(n) }
            return .number(0)

        case .boolean:
            if let b = value as? Bool { return .boolean(b) }
            if let s = value as? String { return .boolean(s.lowercased() == "true") }
            if let n = value as? Int { return .boolean(n != 0) }
            return .boolean(false)

        case .list:
            if let arr = value as? [String] { return .stringList(arr) }
            if let arr = value as? [Double] { return .numberList(arr) }
            if let arr = value as? [Int] { return .numberList(arr.map { Double($0) }) }
            if let arr = value as? [Bool] { return .booleanList(arr) }
            return .stringList([])
        }
    }

    private func getTypeDefault(_ type: VariableType, listItemType: ListItemType?) -> VariableValue {
        switch type {
        case .string: return .string("")
        case .number: return .number(0)
        case .boolean: return .boolean(false)
        case .list:
            switch listItemType {
            case .string, .none: return .stringList([])
            case .number: return .numberList([])
            case .boolean: return .booleanList([])
            }
        }
    }

    // MARK: - Getters

    /// Get current value of a variable
    func get(_ key: String) -> VariableValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    /// Get definition of a variable
    func getDefinition(_ key: String) -> FlowVariable? {
        lock.lock()
        defer { lock.unlock() }
        return definitions[key]
    }

    /// Get all current values
    func getAll() -> [String: VariableValue] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    /// Check if a variable exists
    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values[key] != nil
    }

    // MARK: - Setters

    /// Set value of a variable (respects writable flag)
    @discardableResult
    func set(_ key: String, value: VariableValue) -> Bool {
        lock.lock()

        guard let definition = definitions[key] else {
            lock.unlock()
            Logger.shared.warn("Attempted to set unknown variable: \(key)")
            return false
        }

        guard definition.writable else {
            lock.unlock()
            Logger.shared.warn("Attempted to set non-writable variable: \(key)")
            return false
        }

        values[key] = value
        lock.unlock()

        Logger.shared.verbose("Variable updated: \(key) = \(value.displayString)")

        // Notify subscribers
        changeSubject.send((key: key, value: value))
        anyChangeSubject.send()

        return true
    }

    /// Update context values (for SDK-sourced variables)
    func updateContext(_ context: SDKContext) {
        lock.lock()

        for (key, definition) in definitions {
            if case .sdk(let path) = definition.source {
                if let contextValue = context[path] {
                    let value = convertToVariableValue(contextValue, type: definition.type)
                    values[key] = value

                    Logger.shared.verbose("Context variable updated: \(key) = \(value.displayString)")

                    lock.unlock()
                    changeSubject.send((key: key, value: value))
                    anyChangeSubject.send()
                    lock.lock()
                }
            }
        }

        lock.unlock()
    }

    // MARK: - Theme Tokens

    /// Seed the theme palette (`flow.globalStyles.colors`) for `token:`
    /// reference resolution. Called wherever the store is initialized.
    func setThemeColors(_ colors: [String: String]?) {
        lock.lock()
        defer { lock.unlock() }
        themeColors = colors ?? [:]
    }

    /// Resolve a `token:<name>` color reference; non-references pass through.
    func resolveThemeToken(_ value: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return ThemeTokens.resolve(value, colors: themeColors)
    }

    // MARK: - Text Interpolation

    /// Interpolate variables in a text template
    /// Supports both variable labels (e.g., {{Height}}) and keys (e.g., {{var_abc123}})
    func interpolate(_ template: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        var result = template
        let pattern = "\\{\\{([^}]+)\\}\\}"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return template
        }

        let range = NSRange(template.startIndex..., in: template)
        let matches = regex.matches(in: template, range: range)

        // Process matches in reverse order to maintain correct indices
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: template) else { continue }
            let identifier = String(template[keyRange]).trimmingCharacters(in: .whitespaces)

            let replacement: String

            // First try to find by label, then by key
            if let definition = definitionsByLabel[identifier], let value = values[definition.key] {
                // Found by label
                replacement = value.displayString
                Logger.shared.debug("Interpolate: Resolved {{\(identifier)}} (label) -> \"\(replacement)\"")
            } else if let value = values[identifier] {
                // Found by key directly
                replacement = value.displayString
                Logger.shared.debug("Interpolate: Resolved {{\(identifier)}} (key) -> \"\(replacement)\"")
            } else {
                replacement = ""
                let availableLabels = definitionsByLabel.keys.sorted()
                Logger.shared.warn("Interpolate: Variable '\(identifier)' not found. Available labels: \(availableLabels)")
            }

            if let fullRange = Range(match.range, in: result) {
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        return result
    }
}
