import SwiftUI

// MARK: - Color Utilities for Motion Presets

/// Simple RGB color with 0-1 range components
struct RGBColor {
    let r: Double
    let g: Double
    let b: Double
}

/// Convert hex color string to RGBColor (0-1 range)
func hexToRGB(_ hex: String) -> RGBColor {
    let clean = hex.replacingOccurrences(of: "#", with: "")
    guard clean.count >= 6 else { return RGBColor(r: 1, g: 1, b: 1) }

    let scanner = Scanner(string: clean)
    var rgbValue: UInt64 = 0
    scanner.scanHexInt64(&rgbValue)

    return RGBColor(
        r: Double((rgbValue & 0xFF0000) >> 16) / 255.0,
        g: Double((rgbValue & 0x00FF00) >> 8) / 255.0,
        b: Double(rgbValue & 0x0000FF) / 255.0
    )
}

/// Brighten a hex color by increasing brightness and optionally saturation in HSL space
func brightenHex(
    _ hex: String,
    brightnessDelta: Double,
    saturationDelta: Double = 0
) -> RGBColor {
    let rgb = hexToRGB(hex)

    // Convert RGB to HSL
    let maxC = max(rgb.r, rgb.g, rgb.b)
    let minC = min(rgb.r, rgb.g, rgb.b)
    let l = (maxC + minC) / 2

    var h: Double = 0
    var s: Double = 0

    if maxC != minC {
        let d = maxC - minC
        s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        switch maxC {
        case rgb.r:
            h = ((rgb.g - rgb.b) / d + (rgb.g < rgb.b ? 6 : 0)) / 6
        case rgb.g:
            h = ((rgb.b - rgb.r) / d + 2) / 6
        case rgb.b:
            h = ((rgb.r - rgb.g) / d + 4) / 6
        default: break
        }
    }

    // Apply deltas
    let newL = min(1, l + brightnessDelta)
    let newS = min(1, s + saturationDelta)

    return hslToRGB(h: h, s: newS, l: newL)
}

/// Convert HSL to RGB (all values 0-1)
func hslToRGB(h: Double, s: Double, l: Double) -> RGBColor {
    if s == 0 {
        return RGBColor(r: l, g: l, b: l)
    }

    func hue2rgb(_ p: Double, _ q: Double, _ t: Double) -> Double {
        var tt = t
        if tt < 0 { tt += 1 }
        if tt > 1 { tt -= 1 }
        if tt < 1.0 / 6.0 { return p + (q - p) * 6 * tt }
        if tt < 1.0 / 2.0 { return q }
        if tt < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - tt) * 6 }
        return p
    }

    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q

    return RGBColor(
        r: hue2rgb(p, q, h + 1.0 / 3.0),
        g: hue2rgb(p, q, h),
        b: hue2rgb(p, q, h - 1.0 / 3.0)
    )
}
