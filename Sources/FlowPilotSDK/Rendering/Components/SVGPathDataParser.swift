import CoreGraphics
import Foundation

// MARK: - SVG Path Data Parser

/// Parses an SVG `path` element's `d` attribute into a `CGPath`.
///
/// Supports the full SVG path command grammar (M/m, L/l, H/h, V/v, C/c, S/s,
/// Q/q, T/t, A/a, Z/z), implicit command repetition, and the SVG number
/// tokenisation rules (whitespace, comma, or bare sign separators; scientific
/// notation; arc flags as single 0/1 characters).
///
/// Designed for the Lucide icon set's `d` strings but is general-purpose. A
/// malformed `d` string never crashes — parsing halts at the first unrecognised
/// token and the partial path collected so far is returned.
enum SVGPathDataParser {

    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = SVGNumberScanner(d)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint? = nil
        var lastQuadControl: CGPoint? = nil
        var lastCommand: Character? = nil

        while !scanner.isAtEnd {
            scanner.skipSeparators()
            if scanner.isAtEnd { break }

            let command: Character
            if let c = scanner.peek(), c.isLetter {
                command = c
                _ = scanner.advance()
            } else {
                // Implicit continuation: repeat the last command (with M/m
                // promoting to L/l per SVG spec).
                guard let last = lastCommand else { return path }
                command = (last == "M") ? "L" : (last == "m") ? "l" : last
            }

            switch command {
            case "M":
                guard let x = scanner.scanNumber(), let y = scanner.scanNumber() else { return path }
                current = CGPoint(x: x, y: y)
                subpathStart = current
                path.move(to: current)

            case "m":
                guard let dx = scanner.scanNumber(), let dy = scanner.scanNumber() else { return path }
                current = CGPoint(x: current.x + dx, y: current.y + dy)
                subpathStart = current
                path.move(to: current)

            case "L":
                guard let x = scanner.scanNumber(), let y = scanner.scanNumber() else { return path }
                current = CGPoint(x: x, y: y)
                path.addLine(to: current)

            case "l":
                guard let dx = scanner.scanNumber(), let dy = scanner.scanNumber() else { return path }
                current = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addLine(to: current)

            case "H":
                guard let x = scanner.scanNumber() else { return path }
                current = CGPoint(x: x, y: current.y)
                path.addLine(to: current)

            case "h":
                guard let dx = scanner.scanNumber() else { return path }
                current = CGPoint(x: current.x + dx, y: current.y)
                path.addLine(to: current)

            case "V":
                guard let y = scanner.scanNumber() else { return path }
                current = CGPoint(x: current.x, y: y)
                path.addLine(to: current)

            case "v":
                guard let dy = scanner.scanNumber() else { return path }
                current = CGPoint(x: current.x, y: current.y + dy)
                path.addLine(to: current)

            case "C":
                guard let x1 = scanner.scanNumber(), let y1 = scanner.scanNumber(),
                      let x2 = scanner.scanNumber(), let y2 = scanner.scanNumber(),
                      let x = scanner.scanNumber(), let y = scanner.scanNumber()
                else { return path }
                let c1 = CGPoint(x: x1, y: y1)
                let c2 = CGPoint(x: x2, y: y2)
                current = CGPoint(x: x, y: y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2

            case "c":
                guard let dx1 = scanner.scanNumber(), let dy1 = scanner.scanNumber(),
                      let dx2 = scanner.scanNumber(), let dy2 = scanner.scanNumber(),
                      let dx = scanner.scanNumber(), let dy = scanner.scanNumber()
                else { return path }
                let c1 = CGPoint(x: current.x + dx1, y: current.y + dy1)
                let c2 = CGPoint(x: current.x + dx2, y: current.y + dy2)
                current = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2

            case "S":
                guard let x2 = scanner.scanNumber(), let y2 = scanner.scanNumber(),
                      let x = scanner.scanNumber(), let y = scanner.scanNumber()
                else { return path }
                let c1 = Self.reflectControl(prevControl: lastCubicControl, current: current, prevCommand: lastCommand, validPrev: "CcSs")
                let c2 = CGPoint(x: x2, y: y2)
                current = CGPoint(x: x, y: y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2

            case "s":
                guard let dx2 = scanner.scanNumber(), let dy2 = scanner.scanNumber(),
                      let dx = scanner.scanNumber(), let dy = scanner.scanNumber()
                else { return path }
                let c1 = Self.reflectControl(prevControl: lastCubicControl, current: current, prevCommand: lastCommand, validPrev: "CcSs")
                let c2 = CGPoint(x: current.x + dx2, y: current.y + dy2)
                current = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2

            case "Q":
                guard let x1 = scanner.scanNumber(), let y1 = scanner.scanNumber(),
                      let x = scanner.scanNumber(), let y = scanner.scanNumber()
                else { return path }
                let cp = CGPoint(x: x1, y: y1)
                current = CGPoint(x: x, y: y)
                path.addQuadCurve(to: current, control: cp)
                lastQuadControl = cp

            case "q":
                guard let dx1 = scanner.scanNumber(), let dy1 = scanner.scanNumber(),
                      let dx = scanner.scanNumber(), let dy = scanner.scanNumber()
                else { return path }
                let cp = CGPoint(x: current.x + dx1, y: current.y + dy1)
                current = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addQuadCurve(to: current, control: cp)
                lastQuadControl = cp

            case "T":
                guard let x = scanner.scanNumber(), let y = scanner.scanNumber() else { return path }
                let cp = Self.reflectControl(prevControl: lastQuadControl, current: current, prevCommand: lastCommand, validPrev: "QqTt")
                current = CGPoint(x: x, y: y)
                path.addQuadCurve(to: current, control: cp)
                lastQuadControl = cp

            case "t":
                guard let dx = scanner.scanNumber(), let dy = scanner.scanNumber() else { return path }
                let cp = Self.reflectControl(prevControl: lastQuadControl, current: current, prevCommand: lastCommand, validPrev: "QqTt")
                current = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addQuadCurve(to: current, control: cp)
                lastQuadControl = cp

            case "A":
                guard let rx = scanner.scanNumber(), let ry = scanner.scanNumber(),
                      let xRot = scanner.scanNumber(),
                      let largeArc = scanner.scanFlag(),
                      let sweep = scanner.scanFlag(),
                      let x = scanner.scanNumber(), let y = scanner.scanNumber()
                else { return path }
                let end = CGPoint(x: x, y: y)
                SVGArc.addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                              xAxisRotationDegrees: xRot, largeArc: largeArc, sweep: sweep)
                current = end

            case "a":
                guard let rx = scanner.scanNumber(), let ry = scanner.scanNumber(),
                      let xRot = scanner.scanNumber(),
                      let largeArc = scanner.scanFlag(),
                      let sweep = scanner.scanFlag(),
                      let dx = scanner.scanNumber(), let dy = scanner.scanNumber()
                else { return path }
                let end = CGPoint(x: current.x + dx, y: current.y + dy)
                SVGArc.addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                              xAxisRotationDegrees: xRot, largeArc: largeArc, sweep: sweep)
                current = end

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart

            default:
                // Unknown command — bail out gracefully with what we have so far.
                return path
            }

            // Reset implicit-control state if the command was not a curve.
            if !"CcSs".contains(command) { lastCubicControl = nil }
            if !"QqTt".contains(command) { lastQuadControl = nil }

            lastCommand = command
        }

        return path
    }

    /// Reflects the previous control point through `current` for smooth-curve
    /// commands (S/s/T/t). If the previous command was not a curve of matching
    /// kind, the current point is returned per SVG spec.
    private static func reflectControl(prevControl: CGPoint?, current: CGPoint,
                                       prevCommand: Character?, validPrev: String) -> CGPoint {
        guard let lc = prevControl, let prev = prevCommand, validPrev.contains(prev) else {
            return current
        }
        return CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
    }
}

// MARK: - SVG Number Scanner

/// Tokenises the body of an SVG path `d` attribute, an SVG `points` list, or
/// any SVG attribute that uses the same number grammar.
///
/// Rules:
/// - Numbers may be integer, decimal, or scientific (`1.5e-2`).
/// - Whitespace, commas, and bare sign characters all act as separators.
///   `"10-20"` tokenises as `10`, `-20` per the SVG spec.
/// - Arc flags are single `0`/`1` characters without an enclosing separator.
struct SVGNumberScanner {
    private let chars: [Character]
    private var index: Int

    init(_ string: String) {
        self.chars = Array(string)
        self.index = 0
    }

    var isAtEnd: Bool { index >= chars.count }

    func peek() -> Character? {
        guard index < chars.count else { return nil }
        return chars[index]
    }

    mutating func advance() -> Character? {
        guard index < chars.count else { return nil }
        defer { index += 1 }
        return chars[index]
    }

    /// Skips whitespace and comma separators (but not signs — signs are part of
    /// the following number).
    mutating func skipSeparators() {
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace || c == "," {
                index += 1
            } else {
                return
            }
        }
    }

    mutating func scanNumber() -> Double? {
        skipSeparators()
        guard index < chars.count else { return nil }

        let start = index
        var hasDigit = false
        var hasDot = false
        var hasExponent = false

        // Optional leading sign.
        if let c = peek(), c == "-" || c == "+" {
            index += 1
        }

        while index < chars.count {
            let c = chars[index]
            if c.isNumber {
                hasDigit = true
                index += 1
            } else if c == "." && !hasDot && !hasExponent {
                hasDot = true
                index += 1
            } else if (c == "e" || c == "E") && hasDigit && !hasExponent {
                hasExponent = true
                index += 1
                if let next = peek(), next == "-" || next == "+" {
                    index += 1
                }
            } else {
                break
            }
        }

        guard hasDigit else {
            index = start
            return nil
        }
        return Double(String(chars[start..<index]))
    }

    /// Scans a single-character SVG arc flag (`0` or `1`). Returns nil if the
    /// next non-separator character is anything else.
    mutating func scanFlag() -> Bool? {
        skipSeparators()
        guard let c = peek() else { return nil }
        if c == "0" {
            index += 1
            return false
        }
        if c == "1" {
            index += 1
            return true
        }
        return nil
    }
}

// MARK: - SVG Arc Conversion

/// Converts SVG endpoint-parameterised elliptical arcs into a sequence of
/// cubic Bézier segments approximating the arc, following the algorithm in the
/// SVG 1.1 spec, Implementation Notes §F.6.
enum SVGArc {

    static func addArc(to path: CGMutablePath, from start: CGPoint, to end: CGPoint,
                       rx: Double, ry: Double, xAxisRotationDegrees: Double,
                       largeArc: Bool, sweep: Bool) {
        // Degenerate cases per SVG spec §F.6.2.
        if start == end { return }
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }

        let rxAbs = abs(rx)
        let ryAbs = abs(ry)
        let phi = xAxisRotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        // Step 1: compute (x1', y1') — the start point in a frame centred on
        // the midpoint of the chord and rotated by -phi.
        let dx = (Double(start.x) - Double(end.x)) / 2
        let dy = (Double(start.y) - Double(end.y)) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // Ensure radii are large enough (spec §F.6.6.3).
        var rxFinal = rxAbs
        var ryFinal = ryAbs
        let lambda = (x1p * x1p) / (rxFinal * rxFinal) + (y1p * y1p) / (ryFinal * ryFinal)
        if lambda > 1 {
            let s = sqrt(lambda)
            rxFinal *= s
            ryFinal *= s
        }

        let rx2 = rxFinal * rxFinal
        let ry2 = ryFinal * ryFinal
        let x1p2 = x1p * x1p
        let y1p2 = y1p * y1p

        // Step 2: compute (cx', cy').
        let sign: Double = (largeArc == sweep) ? -1 : 1
        let numerator = max(0, rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
        let denominator = rx2 * y1p2 + ry2 * x1p2
        let factor = sign * sqrt(denominator == 0 ? 0 : numerator / denominator)
        let cxp = factor * (rxFinal * y1p / ryFinal)
        let cyp = -factor * (ryFinal * x1p / rxFinal)

        // Step 3: rotate / translate back to user space to get (cx, cy).
        let cx = cosPhi * cxp - sinPhi * cyp + (Double(start.x) + Double(end.x)) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (Double(start.y) + Double(end.y)) / 2

        // Step 4: compute theta1 + deltaTheta on the unit circle of the
        // ellipse's parametric space.
        let ux = (x1p - cxp) / rxFinal
        let uy = (y1p - cyp) / ryFinal
        let vx = (-x1p - cxp) / rxFinal
        let vy = (-y1p - cyp) / ryFinal

        let theta1 = vectorAngle(ux: 1, uy: 0, vx: ux, vy: uy)
        var deltaTheta = vectorAngle(ux: ux, uy: uy, vx: vx, vy: vy).truncatingRemainder(dividingBy: 2 * .pi)
        if !sweep && deltaTheta > 0 {
            deltaTheta -= 2 * .pi
        } else if sweep && deltaTheta < 0 {
            deltaTheta += 2 * .pi
        }

        // Approximate the arc as a chain of cubic Béziers, one per <= 90°.
        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let segmentAngle = deltaTheta / Double(segments)
        // Bézier control-point distance factor for arc approximation.
        // alpha = sin(theta) * (sqrt(4 + 3 * tan(theta/2)^2) - 1) / 3
        let alpha = sin(segmentAngle) * (sqrt(4 + 3 * pow(tan(segmentAngle / 2), 2)) - 1) / 3

        var theta = theta1
        for _ in 0..<segments {
            let theta2 = theta + segmentAngle
            let cosT1 = cos(theta), sinT1 = sin(theta)
            let cosT2 = cos(theta2), sinT2 = sin(theta2)

            // Unit-circle control points.
            let c1ux = cosT1 - alpha * sinT1
            let c1uy = sinT1 + alpha * cosT1
            let c2ux = cosT2 + alpha * sinT2
            let c2uy = sinT2 - alpha * cosT2

            let c1 = mapEllipseToUserSpace(ux: c1ux, uy: c1uy, rx: rxFinal, ry: ryFinal,
                                           cosPhi: cosPhi, sinPhi: sinPhi, cx: cx, cy: cy)
            let c2 = mapEllipseToUserSpace(ux: c2ux, uy: c2uy, rx: rxFinal, ry: ryFinal,
                                           cosPhi: cosPhi, sinPhi: sinPhi, cx: cx, cy: cy)
            let p3 = mapEllipseToUserSpace(ux: cosT2, uy: sinT2, rx: rxFinal, ry: ryFinal,
                                           cosPhi: cosPhi, sinPhi: sinPhi, cx: cx, cy: cy)

            path.addCurve(to: p3, control1: c1, control2: c2)
            theta = theta2
        }
    }

    private static func mapEllipseToUserSpace(ux: Double, uy: Double, rx: Double, ry: Double,
                                              cosPhi: Double, sinPhi: Double,
                                              cx: Double, cy: Double) -> CGPoint {
        let xe = ux * rx
        let ye = uy * ry
        let xr = xe * cosPhi - ye * sinPhi
        let yr = xe * sinPhi + ye * cosPhi
        return CGPoint(x: xr + cx, y: yr + cy)
    }

    /// Signed angle between two 2-D vectors, in radians. Used by the SVG arc
    /// conversion to compute theta1 and delta-theta.
    private static func vectorAngle(ux: Double, uy: Double, vx: Double, vy: Double) -> Double {
        let dot = ux * vx + uy * vy
        let cross = ux * vy - uy * vx
        return atan2(cross, dot)
    }
}
