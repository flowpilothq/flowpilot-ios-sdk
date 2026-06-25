import SwiftUI

// MARK: - Comparison Chart View

/// Renders a `comparisonChart` primitive: the "you without us vs you with us"
/// comparison curves (overhaul §3.3). Up to 5 smoothed series, each drawn in
/// on appear via SwiftUI `Path.trim`. Opinionated: no axes config, an optional
/// faint baseline, optional area fill / end dot per series, and optional
/// vertical marker annotations. Curves are smoothed with a uniform Catmull-Rom
/// interpolation matching the dashboard and Expo renderers.
struct ComparisonChartView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    var renderTrigger: Int = 0

    @State private var progress: CGFloat = 0

    // Max series rendered; mirrors MAX_SERIES on the dashboard/Expo renderers.
    private static let maxSeries = 5

    private var props: ComponentProps? { node.props }

    private var seriesList: [ChartSeries] {
        guard let raw = props?.getRaw("series") as? [Any] else { return [] }
        return raw.prefix(Self.maxSeries).compactMap { item -> ChartSeries? in
            guard let d = item as? [String: Any] else { return nil }
            let points: [CGPoint] = (d["points"] as? [Any] ?? []).compactMap { p in
                guard let pd = p as? [String: Any],
                      let x = Self.asDouble(pd["x"]),
                      let y = Self.asDouble(pd["y"]) else { return nil }
                return CGPoint(x: x, y: y)
            }
            return ChartSeries(
                label: d["label"] as? String ?? "",
                color: Color(hex: d["color"] as? String ?? "#4F46E5") ?? .blue,
                points: points,
                dashed: (d["style"] as? String) == "dashed",
                showArea: d["showArea"] as? Bool ?? false,
                showStartDot: d["showStartDot"] as? Bool ?? false,
                showEndDot: d["showEndDot"] as? Bool ?? false,
                hollowDots: (d["dotStyle"] as? String) == "hollow",
                animate: d["animate"] as? Bool ?? true
            )
        }
    }

    private var markers: [ChartMarker] {
        guard let raw = props?.getRaw("markers") as? [Any] else { return [] }
        return raw.compactMap { item in
            guard let d = item as? [String: Any], let x = Self.asDouble(d["x"]) else { return nil }
            return ChartMarker(x: x, label: d["label"] as? String ?? "")
        }
    }

    private var xLabelStart: String { (props?.getRaw("xLabels") as? [String: Any])?["start"] as? String ?? "" }
    private var xLabelEnd: String { (props?.getRaw("xLabels") as? [String: Any])?["end"] as? String ?? "" }
    private var yLabel: String { props?.getRaw("yLabel") as? String ?? "" }
    private var showLegend: Bool { props?.getRaw("legend") as? Bool ?? false }
    /// Number of evenly-spaced horizontal dotted reference lines (0 = none).
    private var gridLines: Int {
        guard let n = Self.asDouble(props?.getRaw("gridLines")) else { return 0 }
        return Swift.max(0, Int(n))
    }
    private var animateOnAppear: Bool {
        PropertyResolver.resolve(props?.animateOnAppear, store: variableStore, default: true)
    }
    private var animationDuration: Double {
        PropertyResolver.resolve(props?.animationDuration, store: variableStore, default: 900.0)
    }
    private var staggerSeries: Bool {
        PropertyResolver.resolve(props?.staggerSeries, store: variableStore, default: false)
    }
    private var staggerDelay: Double {
        PropertyResolver.resolve(props?.staggerDelay, store: variableStore, default: 250.0)
    }

    var body: some View {
        let _ = renderTrigger
        let series = seriesList
        VStack(alignment: .leading, spacing: 8) {
            if showLegend && !series.isEmpty {
                HStack(spacing: 16) {
                    ForEach(series.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            Circle().fill(series[i].color).frame(width: 10, height: 10)
                            Text(series[i].label)
                                .font(.system(size: 12))
                                .foregroundColor(Color(red: 0.42, green: 0.45, blue: 0.5))
                        }
                    }
                }
            }
            GeometryReader { geo in
                ChartCanvas(
                    size: geo.size,
                    series: series,
                    markers: markers,
                    gridLines: gridLines,
                    xLabelStart: xLabelStart,
                    xLabelEnd: xLabelEnd,
                    yLabel: yLabel,
                    progress: progress,
                    animateOnAppear: animateOnAppear,
                    animationDuration: animationDuration,
                    staggerSeries: staggerSeries,
                    staggerDelay: staggerDelay
                )
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            progress = 0
            if animateOnAppear {
                // Toggle on the next runloop so ChartCanvas's per-series
                // `.animation(_:value:)` modifiers animate the 0 -> 1 change,
                // each series offset by its own stagger delay.
                DispatchQueue.main.async { progress = 1 }
            } else {
                progress = 1
            }
        }
    }

    private static func asDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Data

struct ChartSeries {
    let label: String
    let color: Color
    let points: [CGPoint]   // data space (x, y)
    let dashed: Bool
    let showArea: Bool
    let showStartDot: Bool
    let showEndDot: Bool
    /// "hollow" dots render as a white fill + 2pt colored ring (Cal-AI weight
    /// curve); otherwise a solid disc in the series colour.
    let hollowDots: Bool
    /// Per-series opt-out of the on-appear animation (default true).
    let animate: Bool
}

struct ChartMarker {
    let x: Double
    let label: String
}

// MARK: - Canvas

private struct ChartCanvas: View {
    let size: CGSize
    let series: [ChartSeries]
    let markers: [ChartMarker]
    let gridLines: Int
    let xLabelStart: String
    let xLabelEnd: String
    let yLabel: String
    let progress: CGFloat
    let animateOnAppear: Bool
    let animationDuration: Double
    let staggerSeries: Bool
    let staggerDelay: Double

    private var insetTop: CGFloat { yLabel.isEmpty ? 10 : 22 }
    private var insetRight: CGFloat { 16 }
    private var insetBottom: CGFloat { (xLabelStart.isEmpty && xLabelEnd.isEmpty) ? 10 : 24 }
    private var insetLeft: CGFloat { 10 }

    private var baselineY: CGFloat { size.height - insetBottom }

    private var domain: (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for s in series {
            for p in s.points {
                minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
                minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
            }
        }
        if !minX.isFinite { return (0, 1, 0, 1) }
        return (minX, maxX, minY, maxY)
    }

    private func project(_ x: Double, _ y: Double) -> CGPoint {
        let d = domain
        let plotW = Swift.max(1, size.width - insetLeft - insetRight)
        let plotH = Swift.max(1, size.height - insetTop - insetBottom)
        let spanX = (d.maxX - d.minX) == 0 ? 1 : (d.maxX - d.minX)
        let rawSpanY = (d.maxY - d.minY) == 0 ? 1 : (d.maxY - d.minY)
        let padY = rawSpanY * 0.08
        let minYp = d.minY - padY
        let spanY = rawSpanY + padY * 2
        return CGPoint(
            x: insetLeft + CGFloat((x - d.minX) / spanX) * plotW,
            y: insetTop + CGFloat(1 - (y - minYp) / spanY) * plotH
        )
    }

    /// A start/end marker: solid disc, or a white fill + colored ring when the
    /// series uses `dotStyle: "hollow"`. Matches the web/Expo r=5 + 2px stroke.
    @ViewBuilder
    private func dotView(_ s: ChartSeries) -> some View {
        if s.hollowDots {
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(s.color, lineWidth: 2))
        } else {
            Circle()
                .fill(s.color)
                .frame(width: 10, height: 10)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Faint baseline
            Path { p in
                p.move(to: CGPoint(x: insetLeft, y: baselineY))
                p.addLine(to: CGPoint(x: size.width - insetRight, y: baselineY))
            }
            .stroke(Color(red: 0.9, green: 0.91, blue: 0.92), lineWidth: 1)

            // Horizontal dotted reference lines, evenly spaced between the top of
            // the plot and the baseline (the Cal-AI weight-curve gridlines).
            ForEach(Array(0..<Swift.max(0, gridLines)), id: \.self) { i in
                let gy = insetTop + (CGFloat(i + 1) / CGFloat(gridLines + 1)) * (baselineY - insetTop)
                Path { p in
                    p.move(to: CGPoint(x: insetLeft, y: gy))
                    p.addLine(to: CGPoint(x: size.width - insetRight, y: gy))
                }
                .stroke(Color(red: 0.82, green: 0.84, blue: 0.86), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }

            // Markers
            ForEach(markers.indices, id: \.self) { i in
                let mx = project(markers[i].x, domain.minY).x
                Path { p in
                    p.move(to: CGPoint(x: mx, y: insetTop))
                    p.addLine(to: CGPoint(x: mx, y: baselineY))
                }
                .stroke(Color(red: 0.82, green: 0.84, blue: 0.86), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if !markers[i].label.isEmpty {
                    Text(markers[i].label)
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0.61, green: 0.64, blue: 0.69))
                        .position(x: mx, y: insetTop - 6)
                }
            }

            // Series: area, line, end dot
            ForEach(series.indices, id: \.self) { i in
                let pts = series[i].points.map { project($0.x, $0.y) }
                // Per-series opt-out: a series with `animate == false` renders
                // fully drawn immediately (p = 1) and skips the animation.
                let seriesAnimates = animateOnAppear && series[i].animate
                let p: CGFloat = seriesAnimates ? progress : 1
                // Each animating series reveals over `animationDuration`, offset
                // by `i * staggerDelay` when stagger is on (0 otherwise).
                let seriesDelay = (seriesAnimates && staggerSeries) ? Double(i) * staggerDelay / 1000.0 : 0
                let seriesAnim: Animation? = seriesAnimates
                    ? .easeOut(duration: max(0.1, animationDuration / 1000.0)).delay(seriesDelay)
                    : nil
                if series[i].showArea {
                    SmoothAreaShape(points: pts, baselineY: baselineY)
                        .fill(series[i].color.opacity(0.14))
                        .opacity(Double(p))
                        .animation(seriesAnim, value: progress)
                }
                SmoothLineShape(points: pts)
                    .trim(from: 0, to: p)
                    .stroke(
                        series[i].color,
                        style: StrokeStyle(
                            lineWidth: 3,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: series[i].dashed ? [6, 6] : []
                        )
                    )
                    .animation(seriesAnim, value: progress)
                if series[i].showStartDot, let first = pts.first {
                    dotView(series[i])
                        .position(x: first.x, y: first.y)
                        .opacity(Double(p))
                        .animation(seriesAnim, value: progress)
                }
                if series[i].showEndDot, let last = pts.last {
                    dotView(series[i])
                        .position(x: last.x, y: last.y)
                        .opacity(Double(p))
                        .animation(seriesAnim, value: progress)
                }
            }

            // y label (top-left)
            if !yLabel.isEmpty {
                Text(yLabel)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.61, green: 0.64, blue: 0.69))
                    .position(x: insetLeft + 30, y: 8)
            }

            // x labels (bottom corners)
            if !xLabelStart.isEmpty {
                Text(xLabelStart)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.61, green: 0.64, blue: 0.69))
                    .position(x: insetLeft + 24, y: size.height - 8)
            }
            if !xLabelEnd.isEmpty {
                Text(xLabelEnd)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.61, green: 0.64, blue: 0.69))
                    .position(x: size.width - insetRight - 24, y: size.height - 8)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Shapes

/// Uniform Catmull-Rom spline through the given pixel-space points.
func comparisonChartSmoothPath(_ pts: [CGPoint]) -> Path {
    var path = Path()
    guard let first = pts.first else { return path }
    path.move(to: first)
    if pts.count == 1 { return path }
    for i in 0..<(pts.count - 1) {
        let p0 = i > 0 ? pts[i - 1] : pts[i]
        let p1 = pts[i]
        let p2 = pts[i + 1]
        let p3 = (i + 2 < pts.count) ? pts[i + 2] : p2
        let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: cp1, control2: cp2)
    }
    return path
}

private struct SmoothLineShape: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path { comparisonChartSmoothPath(points) }
}

private struct SmoothAreaShape: Shape {
    let points: [CGPoint]
    let baselineY: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = comparisonChartSmoothPath(points)
        guard let last = points.last, let first = points.first else { return path }
        path.addLine(to: CGPoint(x: last.x, y: baselineY))
        path.addLine(to: CGPoint(x: first.x, y: baselineY))
        path.closeSubpath()
        return path
    }
}
