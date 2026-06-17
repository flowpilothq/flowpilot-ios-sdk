import Foundation

// MARK: - Expression Evaluator

/// Evaluates a FlowExpression string against a `VariableStore`.
///
/// FlowExpression is a "safe-subset JS-like" string used by the `assign`
/// action and by compiled computed ("calculated") variables. Evaluation is
/// strictly LEFT-TO-RIGHT with NO operator precedence — use parentheses to
/// group. The supported grammar:
///
/// - Literals: `true`, `false`, `null`, numbers (decimal + negative),
///   quoted strings (`"..."` or `'...'`)
/// - Variable references: bare identifier (`userName`) or `vars.identifier`
/// - Binary arithmetic (`+ - * / %`); `+` is string concatenation when either
///   operand resolves to a string
/// - Parenthesized grouping: `(a + b) * c`
/// - Unary math functions: `round(x)`, `floor(x)`, `ceil(x)`, `abs(x)`
///
/// Unsupported expressions (comparisons, boolean logic, arbitrary calls,
/// member access) return `nil`. Callers MUST treat `nil` as "skip this
/// assignment" — never as "write empty/zero/false" — so a misconfigured
/// expression doesn't silently corrupt the variable.
///
/// Keep this in lockstep with the Expo `ExpressionEvaluator.ts` and the
/// dashboard `lib/variables/expression-evaluator.ts`.
enum ExpressionEvaluator {

    private static let maxDepth = 32
    private static let mathFuncs: Set<String> = ["round", "floor", "ceil", "abs"]

    /// Evaluate a FlowExpression and return its value, or `nil` if the
    /// expression cannot be evaluated. Callers should treat `nil` as
    /// "skip this assignment."
    static func evaluate(
        _ expression: String,
        store: VariableStore
    ) -> VariableValue? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return evalExpr(trimmed, store: store, depth: 0)
    }

    private static func evalExpr(
        _ src: String,
        store: VariableStore,
        depth: Int
    ) -> VariableValue? {
        if depth > maxDepth {
            Logger.shared.warn("Expression too deeply nested: \"\(src)\"")
            return nil
        }
        let s = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        switch parsePrimary(s, store: store, depth: depth) {
        case .matched(let value):
            return value
        case .unmatched:
            break
        }

        // Split on the LAST top-level binary operator (outside quotes/parens)
        // so recursion on the left side yields left-to-right evaluation.
        if let split = splitLastTopLevelBinary(s) {
            let lhs = evalExpr(split.left, store: store, depth: depth + 1)
            let rhs = evalExpr(split.right, store: store, depth: depth + 1)
            guard let left = lhs, let right = rhs else {
                Logger.shared.warn("Expression operand unresolved: \"\(s)\"")
                return nil
            }
            return applyBinary(op: split.op, left: left, right: right, source: s)
        }

        Logger.shared.warn("Unsupported expression: \"\(s)\"")
        return nil
    }

    // MARK: - Primary parsing

    /// Two-state result so the caller can tell "I parsed `null` deliberately"
    /// from "this string didn't match any primary form."
    private enum PrimaryResult {
        case matched(VariableValue?)
        case unmatched
    }

    private static func parsePrimary(
        _ src: String,
        store: VariableStore,
        depth: Int
    ) -> PrimaryResult {
        let s = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .unmatched }

        switch s {
        case "true": return .matched(.boolean(true))
        case "false": return .matched(.boolean(false))
        case "null": return .matched(nil)
        default: break
        }

        if isNumberLiteral(s), let n = Double(s) {
            return .matched(.number(n))
        }

        if let quoted = parseQuotedString(s) {
            return .matched(.string(quoted))
        }

        let chars = Array(s)

        // Parenthesized group: the first "(" closes exactly at the last char.
        if chars.first == "(" && matchingCloseIsLast(chars, openIdx: 0) {
            let inner = String(chars[1..<(chars.count - 1)])
            return .matched(evalExpr(inner, store: store, depth: depth + 1))
        }

        // Unary math function spanning the whole string.
        if let fn = matchFunctionCall(chars) {
            let arg = evalExpr(fn.argStr, store: store, depth: depth + 1)
            guard let argVal = arg, let n = numericValue(argVal) else {
                return .matched(nil)
            }
            return .matched(.number(applyMathFunc(fn.name, n)))
        }

        if let key = extractVariableKey(s) {
            return .matched(store.get(key))
        }

        return .unmatched
    }

    private static func isNumberLiteral(_ s: String) -> Bool {
        // Allows: 1, -1, 1.5, -1.5, .5, 1. — matches the JS evaluator's contract.
        var sawDigit = false
        var sawDot = false
        var i = s.startIndex
        if i < s.endIndex && s[i] == "-" {
            i = s.index(after: i)
        }
        while i < s.endIndex {
            let ch = s[i]
            if ch.isNumber {
                sawDigit = true
            } else if ch == "." {
                if sawDot { return false }
                sawDot = true
            } else {
                return false
            }
            i = s.index(after: i)
        }
        return sawDigit
    }

    private static func parseQuotedString(_ s: String) -> String? {
        guard s.count >= 2 else { return nil }
        let first = s.first!
        let last = s.last!
        guard (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return nil
        }
        let inner = s.dropFirst().dropLast()
        // Reject strings that contain the same quote character — the simple
        // parser can't distinguish those from two adjacent string literals.
        if inner.contains(first) { return nil }
        return String(inner)
    }

    /// True if the "(" at `openIdx` has its matching ")" as the last char.
    private static func matchingCloseIsLast(_ chars: [Character], openIdx: Int) -> Bool {
        var depth = 0
        var inSingle = false
        var inDouble = false
        var i = openIdx
        while i < chars.count {
            let ch = chars[i]
            if inSingle {
                if ch == "'" { inSingle = false }
                i += 1; continue
            }
            if inDouble {
                if ch == "\"" { inDouble = false }
                i += 1; continue
            }
            if ch == "'" { inSingle = true; i += 1; continue }
            if ch == "\"" { inDouble = true; i += 1; continue }
            if ch == "(" {
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0 { return i == chars.count - 1 }
            }
            i += 1
        }
        return false
    }

    private struct FunctionCall {
        let name: String
        let argStr: String
    }

    /// Matches `fnname(...)` where the call spans the entire string.
    private static func matchFunctionCall(_ chars: [Character]) -> FunctionCall? {
        guard let open = chars.firstIndex(of: "("), open > 0, chars.last == ")" else {
            return nil
        }
        let name = String(chars[0..<open])
        guard name.allSatisfy({ $0.isLetter }), mathFuncs.contains(name) else {
            return nil
        }
        guard matchingCloseIsLast(chars, openIdx: open) else { return nil }
        let argStr = String(chars[(open + 1)..<(chars.count - 1)])
        return FunctionCall(name: name, argStr: argStr)
    }

    private static func applyMathFunc(_ name: String, _ n: Double) -> Double {
        switch name {
        // round = nearest integer, ties toward +inf (floor(n + 0.5)) so all
        // three layers agree exactly.
        case "round": return (n + 0.5).rounded(.down)
        case "floor": return n.rounded(.down)
        case "ceil": return n.rounded(.up)
        case "abs": return Swift.abs(n)
        default: return n
        }
    }

    /// Strip a leading `vars.` prefix and validate the remainder is a plain
    /// identifier. Returns the bare key, or `nil` if not a simple var ref.
    private static func extractVariableKey(_ s: String) -> String? {
        let candidate: String
        if s.hasPrefix("vars.") {
            candidate = String(s.dropFirst("vars.".count))
        } else {
            candidate = s
        }
        return isIdentifier(candidate) ? candidate : nil
    }

    private static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        if !(first.isLetter || first == "_") { return false }
        for ch in s.dropFirst() {
            if !(ch.isLetter || ch.isNumber || ch == "_") { return false }
        }
        return true
    }

    // MARK: - Binary split

    private struct BinarySplit {
        let left: String
        let op: Character
        let right: String
    }

    /// Split on the LAST top-level operator outside of quotes and parentheses.
    /// Distinguishes unary minus (start of operand) from binary minus.
    private static func splitLastTopLevelBinary(_ s: String) -> BinarySplit? {
        var inSingle = false
        var inDouble = false
        var parenDepth = 0
        var prevNonSpaceWasOperand = false
        var lastOpIdx = -1
        var lastOp: Character? = nil

        let chars = Array(s)
        for i in 0..<chars.count {
            let ch = chars[i]

            if inSingle {
                if ch == "'" { inSingle = false }
                prevNonSpaceWasOperand = true
                continue
            }
            if inDouble {
                if ch == "\"" { inDouble = false }
                prevNonSpaceWasOperand = true
                continue
            }
            if ch == "'" { inSingle = true; continue }
            if ch == "\"" { inDouble = true; continue }

            if ch == "(" { parenDepth += 1; prevNonSpaceWasOperand = false; continue }
            if ch == ")" { parenDepth -= 1; prevNonSpaceWasOperand = true; continue }
            if parenDepth > 0 { continue }

            let isOp = (ch == "+" || ch == "-" || ch == "*" || ch == "/" || ch == "%")
            if isOp && prevNonSpaceWasOperand {
                lastOpIdx = i
                lastOp = ch
                prevNonSpaceWasOperand = false
                continue
            }

            if !ch.isWhitespace {
                prevNonSpaceWasOperand = !isOp
            }
        }

        guard lastOpIdx >= 0, let op = lastOp else { return nil }
        let left = String(chars[0..<lastOpIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(chars[(lastOpIdx + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty || right.isEmpty { return nil }
        return BinarySplit(left: left, op: op, right: right)
    }

    // MARK: - Binary operators

    private static func applyBinary(
        op: Character,
        left: VariableValue,
        right: VariableValue,
        source: String
    ) -> VariableValue? {
        // String concatenation when either side resolves to a string.
        if op == "+" && (left.isString || right.isString) {
            return .string(stringify(left) + stringify(right))
        }

        guard let ln = numericValue(left), let rn = numericValue(right) else {
            Logger.shared.warn("Cannot apply '\(op)' to non-numeric operands: \"\(source)\"")
            return nil
        }

        switch op {
        case "+": return .number(ln + rn)
        case "-": return .number(ln - rn)
        case "*": return .number(ln * rn)
        case "/":
            if rn == 0 {
                Logger.shared.warn("Division by zero: \"\(source)\"")
                return nil
            }
            return .number(ln / rn)
        case "%":
            if rn == 0 {
                Logger.shared.warn("Modulo by zero: \"\(source)\"")
                return nil
            }
            return .number(ln.truncatingRemainder(dividingBy: rn))
        default:
            return nil
        }
    }

    private static func numericValue(_ value: VariableValue) -> Double? {
        switch value {
        case .number(let n): return n.isFinite ? n : nil
        case .boolean(let b): return b ? 1 : 0
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            guard let n = Double(trimmed), n.isFinite else { return nil }
            return n
        default: return nil
        }
    }

    private static func stringify(_ value: VariableValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n):
            if n.truncatingRemainder(dividingBy: 1) == 0,
               abs(n) < 1e21,
               let asInt = Int64(exactly: n) {
                return String(asInt)
            }
            return String(n)
        case .boolean(let b): return b ? "true" : "false"
        default: return value.displayString
        }
    }
}
