import SwiftUI

// MARK: - Aurora Preset

/// Premium 3-layer aurora borealis effect with directional and immersive rendering paths.

private let POSITION_MAP: [String: (yCenter: Double, height: Double)] = [
    "top":    (yCenter: 0.22, height: 0.55),
    "center": (yCenter: 0.5,  height: 0.55),
    "bottom": (yCenter: 0.78, height: 0.55),
    "full":   (yCenter: 0.5,  height: 0.9)
]

private struct AuroraState {
    let primaryRgb: RGBColor
    let secondaryRgb: RGBColor
    let tertiaryRgb: RGBColor
    let tealRgb: RGBColor
    let baseOpacity: Double
    let streakOpacity: Double
    let baseBlur: Double
    let streakBlur: Double
    let masterOpacity: Double
    let effectiveIntensity: Double
    let colors: [String]
    let coverage: Double
}

func drawAurora(
    ctx: GraphicsContext,
    size: CGSize,
    time: Double,
    params: [String: MotionParamValue]
) {
    // Guard against an explicitly-empty `colors: []` from the flow JSON: the
    // preset indexes `colors[0]` (and divides by `colors.count` for orbs), so an
    // empty array would trap. Fall back to the default palette when empty.
    let colors: [String] = {
        if let c = params["colors"]?.stringArrayValue, !c.isEmpty { return c }
        return ["#00C2FF", "#6E6AE8", "#EAEAEA"]
    }()
    let intensity = params["intensity"]?.doubleValue ?? 0.45
    let position = params["position"]?.stringValue ?? "top"
    let masterOpacity = params["opacity"]?.doubleValue ?? 0.85
    let vignette = params["vignette"]?.boolValue ?? false
    let breathing = params["breathing"]?.boolValue ?? false
    let coverage = params["coverage"]?.doubleValue ?? 0.5

    let isImmersive = position == "full"
    let pos = POSITION_MAP[position] ?? POSITION_MAP["top"]!

    // Breathing: subtle intensity modulation over ~20 seconds
    var effectiveIntensity = intensity
    if breathing {
        let breathCycle = sin(time * (2 * .pi / 20)) * 0.5 + 0.5
        effectiveIntensity = intensity + (breathCycle - 0.5) * 0.06
        effectiveIntensity = max(0, min(1, effectiveIntensity))
    }

    // Derived values from intensity
    let baseOpacity = 0.6 + effectiveIntensity * 0.35
    let streakOpacity = 0.12 + effectiveIntensity * 0.16
    let baseBlur = 80 - effectiveIntensity * 15
    let streakBlur: Double = 120

    let primaryRgb = hexToRGB(colors[0])
    let secondaryRgb = hexToRGB(colors.count > 1 ? colors[1] : colors[0])
    let tertiaryRgb = hexToRGB(colors.count > 2 ? colors[2] : "#EAEAEA")

    // Teal undertone: brightened primary with color shift
    let tealBase = brightenHex(colors[0], brightnessDelta: 0.05, saturationDelta: 0.08)
    let tealRgb = RGBColor(
        r: tealBase.r * 0.7,
        g: min(1.0, tealBase.g * 1.15),
        b: tealBase.b * 0.95
    )

    let state = AuroraState(
        primaryRgb: primaryRgb,
        secondaryRgb: secondaryRgb,
        tertiaryRgb: tertiaryRgb,
        tealRgb: tealRgb,
        baseOpacity: baseOpacity,
        streakOpacity: streakOpacity,
        baseBlur: baseBlur,
        streakBlur: streakBlur,
        masterOpacity: masterOpacity,
        effectiveIntensity: effectiveIntensity,
        colors: colors,
        coverage: coverage
    )

    // Branch: directional vs immersive
    if isImmersive {
        drawImmersive(ctx: ctx, size: size, time: time, state: state)
    } else {
        drawDirectional(ctx: ctx, size: size, time: time, pos: pos, state: state)
    }

    // Layer 3: Corner depth (always-on)
    drawCornerDepth(ctx: ctx, size: size)

    // Optional vignette
    if vignette {
        drawVignette(ctx: ctx, size: size)
    }

    // Content protection: subtle white gradient on lower 30%
    let protectionOpacity = 0.04 + effectiveIntensity * 0.04
    drawContentProtection(ctx: ctx, size: size, opacity: protectionOpacity)
}

// MARK: - Directional Mode

private func drawDirectional(
    ctx: GraphicsContext,
    size: CGSize,
    time: Double,
    pos: (yCenter: Double, height: Double),
    state: AuroraState
) {
    let width = Double(size.width)
    let height = Double(size.height)
    let bandCenterY = height * pos.yCenter

    // Slow drift
    let driftX = sin(time * 0.08) * width * 0.03
    let driftY = cos(time * 0.06) * height * 0.02

    let verticalStretch = 0.35 + state.coverage * 0.75
    let washRadius = max(width, height) * (0.2 + state.coverage * 0.4)

    // Primary wash
    var washCtx = ctx
    washCtx.addFilter(.blur(radius: state.baseBlur))
    washCtx.opacity = state.baseOpacity * state.masterOpacity

    let primaryCenter = CGPoint(x: width * 0.5 + driftX, y: bandCenterY + driftY)
    let primaryGradient = Gradient(stops: [
        .init(color: Color(red: state.primaryRgb.r, green: state.primaryRgb.g, blue: state.primaryRgb.b).opacity(0.7), location: 0),
        .init(color: Color(red: state.tealRgb.r, green: state.tealRgb.g, blue: state.tealRgb.b).opacity(0.4), location: 0.3),
        .init(color: Color(red: state.secondaryRgb.r, green: state.secondaryRgb.g, blue: state.secondaryRgb.b).opacity(0.25), location: 0.6),
        .init(color: Color(red: state.tertiaryRgb.r, green: state.tertiaryRgb.g, blue: state.tertiaryRgb.b).opacity(0.1), location: 0.8),
        .init(color: Color.clear, location: 1.0)
    ])

    let primaryEllipse = Path(ellipseIn: CGRect(
        x: primaryCenter.x - washRadius * 1.6,
        y: primaryCenter.y - washRadius * verticalStretch,
        width: washRadius * 3.2,
        height: washRadius * verticalStretch * 2
    ))

    washCtx.fill(primaryEllipse, with: .radialGradient(
        primaryGradient,
        center: primaryCenter,
        startRadius: 0,
        endRadius: washRadius
    ))

    // Secondary wash (offset)
    let secondaryCenter = CGPoint(x: width * 0.3, y: bandCenterY - height * 0.1)
    let secondaryGradient = Gradient(stops: [
        .init(color: Color(red: state.secondaryRgb.r, green: state.secondaryRgb.g, blue: state.secondaryRgb.b).opacity(0.5), location: 0),
        .init(color: Color(red: state.primaryRgb.r, green: state.primaryRgb.g, blue: state.primaryRgb.b).opacity(0.2), location: 0.5),
        .init(color: Color.clear, location: 1.0)
    ])

    let secondaryEllipse = Path(ellipseIn: CGRect(
        x: secondaryCenter.x - washRadius * 1.2,
        y: secondaryCenter.y - washRadius * verticalStretch * 0.8,
        width: washRadius * 2.4,
        height: washRadius * verticalStretch * 1.6
    ))

    washCtx.fill(secondaryEllipse, with: .radialGradient(
        secondaryGradient,
        center: secondaryCenter,
        startRadius: 0,
        endRadius: washRadius * 0.8
    ))

    // Light streaks (2 streaks)
    drawStreaks(ctx: ctx, size: size, time: time, state: state, bandCenterY: bandCenterY, streakCount: 2, thinFactor: 1.0)
}

// MARK: - Immersive Mode

private func drawImmersive(
    ctx: GraphicsContext,
    size: CGSize,
    time: Double,
    state: AuroraState
) {
    let width = Double(size.width)
    let height = Double(size.height)

    let zoneScale = 0.25 + state.coverage * 1.4
    let zoneOpacity = state.baseOpacity * 0.45
    let zoneBlur = state.baseBlur + 10

    // 4 fog zones with incommensurate drift periods
    let zones: [(cx: Double, cy: Double, color: RGBColor, period: Double)] = [
        (0.25, 0.3, state.primaryRgb, 23.1),
        (0.75, 0.7, state.secondaryRgb, 19.7),
        (0.5, 0.25, state.tealRgb, 31.1),
        (0.3, 0.75, RGBColor(
            r: (state.primaryRgb.r + state.secondaryRgb.r) / 2,
            g: (state.primaryRgb.g + state.secondaryRgb.g) / 2,
            b: (state.primaryRgb.b + state.secondaryRgb.b) / 2
        ), 16.3)
    ]

    for (i, zone) in zones.enumerated() {
        let fi = Double(i)
        let driftX = sin(time * (2 * .pi / zone.period) + fi) * width * 0.05
        let driftY = cos(time * (2 * .pi / zone.period) + fi * 1.3) * height * 0.04

        let zoneCenter = CGPoint(x: zone.cx * width + driftX, y: zone.cy * height + driftY)
        let radius = max(width, height) * zoneScale * 0.5

        var zoneCtx = ctx
        zoneCtx.addFilter(.blur(radius: zoneBlur))
        zoneCtx.opacity = zoneOpacity * state.masterOpacity

        let gradient = Gradient(stops: [
            .init(color: Color(red: zone.color.r, green: zone.color.g, blue: zone.color.b).opacity(0.6), location: 0),
            .init(color: Color(red: zone.color.r, green: zone.color.g, blue: zone.color.b).opacity(0.25), location: 0.5),
            .init(color: Color.clear, location: 1.0)
        ])

        let ellipse = Path(ellipseIn: CGRect(
            x: zoneCenter.x - radius * 1.4,
            y: zoneCenter.y - radius,
            width: radius * 2.8,
            height: radius * 2
        ))

        zoneCtx.fill(ellipse, with: .radialGradient(
            gradient,
            center: zoneCenter,
            startRadius: 0,
            endRadius: radius
        ))
    }

    // 3 distributed streaks
    let streakYPositions: [Double] = [0.28, 0.55, 0.75]
    for (i, yPos) in streakYPositions.enumerated() {
        drawSingleStreak(
            ctx: ctx,
            size: size,
            time: time,
            state: state,
            bandCenterY: height * yPos,
            index: i,
            opacityMultiplier: 0.7,
            blurExtra: 20,
            thinFactor: 0.7
        )
    }
}

// MARK: - Streaks

private func drawStreaks(
    ctx: GraphicsContext,
    size: CGSize,
    time: Double,
    state: AuroraState,
    bandCenterY: Double,
    streakCount: Int,
    thinFactor: Double
) {
    for i in 0..<streakCount {
        drawSingleStreak(
            ctx: ctx,
            size: size,
            time: time,
            state: state,
            bandCenterY: bandCenterY,
            index: i,
            opacityMultiplier: 1.0,
            blurExtra: 0,
            thinFactor: thinFactor
        )
    }
}

private func drawSingleStreak(
    ctx: GraphicsContext,
    size: CGSize,
    time: Double,
    state: AuroraState,
    bandCenterY: Double,
    index: Int,
    opacityMultiplier: Double,
    blurExtra: Double,
    thinFactor: Double
) {
    let width = Double(size.width)
    let height = Double(size.height)
    let fi = Double(index)

    // Compound sinusoidal lateral oscillation
    let lateralOffset = sin(time * 0.12 + fi * 2.1) * width * 0.08
        + sin(time * 0.07 + fi * 1.3) * width * 0.04
    let verticalDrift = cos(time * 0.05 + fi * 1.7) * height * 0.02

    let streakColor = index % 2 == 0 ? state.primaryRgb : state.secondaryRgb
    let brightenedColor = brightenHex(
        state.colors[index % state.colors.count],
        brightnessDelta: 0.1,
        saturationDelta: 0.05
    )

    let streakX = width * (0.3 + fi * 0.2) + lateralOffset
    let streakY = bandCenterY + verticalDrift + fi * height * 0.05
    let streakWidth = width * 0.6 * thinFactor
    let streakHeight = height * 0.03 * thinFactor

    var streakCtx = ctx
    streakCtx.addFilter(.blur(radius: state.streakBlur + blurExtra))
    streakCtx.opacity = state.streakOpacity * opacityMultiplier * state.masterOpacity
    streakCtx.blendMode = .plusLighter

    let gradient = Gradient(stops: [
        .init(color: Color(red: brightenedColor.r, green: brightenedColor.g, blue: brightenedColor.b).opacity(0.6), location: 0),
        .init(color: Color(red: streakColor.r, green: streakColor.g, blue: streakColor.b).opacity(0.3), location: 0.5),
        .init(color: Color.clear, location: 1.0)
    ])

    let ellipse = Path(ellipseIn: CGRect(
        x: streakX - streakWidth / 2,
        y: streakY - streakHeight / 2,
        width: streakWidth,
        height: streakHeight
    ))

    streakCtx.fill(ellipse, with: .radialGradient(
        gradient,
        center: CGPoint(x: streakX, y: streakY),
        startRadius: 0,
        endRadius: streakWidth / 2
    ))
}

// MARK: - Corner Depth

private func drawCornerDepth(ctx: GraphicsContext, size: CGSize) {
    let width = Double(size.width)
    let height = Double(size.height)
    let radius = max(width, height) * 0.45

    let corners: [(x: Double, y: Double)] = [
        (0, 0),          // top-left
        (width, 0)       // top-right
    ]

    for corner in corners {
        let gradient = Gradient(stops: [
            .init(color: Color.black.opacity(0.05), location: 0),
            .init(color: Color.black.opacity(0.02), location: 0.5),
            .init(color: Color.clear, location: 1.0)
        ])

        let center = CGPoint(x: corner.x, y: corner.y)
        let ellipse = Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        ctx.fill(ellipse, with: .radialGradient(
            gradient,
            center: center,
            startRadius: 0,
            endRadius: radius
        ))
    }
}

// MARK: - Vignette

private func drawVignette(ctx: GraphicsContext, size: CGSize) {
    let width = Double(size.width)
    let height = Double(size.height)
    let radius = max(width, height) * 0.7

    let gradient = Gradient(stops: [
        .init(color: Color.clear, location: 0.4),
        .init(color: Color.black.opacity(0.15), location: 0.8),
        .init(color: Color.black.opacity(0.3), location: 1.0)
    ])

    let center = CGPoint(x: width / 2, y: height / 2)
    let ellipse = Path(ellipseIn: CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    ))

    ctx.fill(ellipse, with: .radialGradient(
        gradient,
        center: center,
        startRadius: 0,
        endRadius: radius
    ))
}

// MARK: - Content Protection

private func drawContentProtection(ctx: GraphicsContext, size: CGSize, opacity: Double) {
    let width = Double(size.width)
    let height = Double(size.height)

    let gradient = Gradient(stops: [
        .init(color: Color.clear, location: 0),
        .init(color: Color.white.opacity(opacity), location: 1.0)
    ])

    let protectionRect = CGRect(x: 0, y: height * 0.7, width: width, height: height * 0.3)
    ctx.fill(
        Path(protectionRect),
        with: .linearGradient(
            gradient,
            startPoint: CGPoint(x: width / 2, y: height * 0.7),
            endPoint: CGPoint(x: width / 2, y: height)
        )
    )
}
