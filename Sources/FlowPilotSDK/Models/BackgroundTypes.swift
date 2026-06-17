import Foundation

// MARK: - Screen Background

/// Layered background system supporting solid colors, gradients, images, and motion.
struct ScreenBackground: Codable, Sendable, Equatable {
    let layers: [BackgroundLayer]
}

// MARK: - Background Layer

struct BackgroundLayer: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let type: BackgroundLayerType
    let enabled: Bool
    let opacity: Double?       // 0-100, default 100

    // Type-specific payloads (only the matching one is populated):
    let color: String?                   // solid: hex color
    let gradient: GradientDefinition?    // gradient
    let image: ImageBackground?          // image
    let motion: MotionBackground?        // motion
}

enum BackgroundLayerType: String, Codable, Sendable {
    case solid
    case gradient
    case image
    case motion
}

// MARK: - Gradient

struct GradientDefinition: Codable, Sendable, Equatable {
    let type: GradientType
    let colors: [GradientStop]
    let angle: Double?       // linear: 0-360 degrees
    let centerX: Double?     // radial/conic: 0-100%
    let centerY: Double?     // radial/conic: 0-100%
}

enum GradientType: String, Codable, Sendable {
    case linear
    case radial
    case conic
}

struct GradientStop: Codable, Sendable, Equatable {
    let color: String        // hex color
    let position: Double     // 0-100
}

// MARK: - Image Background

struct ImageBackground: Codable, Sendable, Equatable {
    let src: String
    let fit: ImageFit
    let positionX: Double?   // 0-100%, default 50
    let positionY: Double?   // 0-100%, default 50
    let blur: Double?        // px, default 0
}

enum ImageFit: String, Codable, Sendable {
    case cover
    case contain
    case fill
    case tile
}

// MARK: - Motion Background

struct MotionBackground: Codable, Sendable, Equatable {
    let preset: MotionPreset
    let params: [String: MotionParamValue]
    let speed: Double?       // 0.1-3.0 multiplier, default 1.0
    let paused: Bool?
}

enum MotionPreset: String, Codable, Sendable {
    case gradientFlow
    case orbBlobs
    case aurora
}

/// Motion parameters can be strings, numbers, booleans, or arrays thereof
enum MotionParamValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case stringArray([String])
    case numberArray([Double])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try each type in order
        if let val = try? container.decode(Bool.self) {
            self = .bool(val)
        } else if let val = try? container.decode(Double.self) {
            self = .number(val)
        } else if let val = try? container.decode(String.self) {
            self = .string(val)
        } else if let val = try? container.decode([String].self) {
            self = .stringArray(val)
        } else if let val = try? container.decode([Double].self) {
            self = .numberArray(val)
        } else {
            throw DecodingError.typeMismatch(
                MotionParamValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported motion param type")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .stringArray(let v): try container.encode(v)
        case .numberArray(let v): try container.encode(v)
        }
    }

    // Convenience accessors
    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .number(let v) = self { return Int(v) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var stringArrayValue: [String]? {
        if case .stringArray(let v) = self { return v }
        return nil
    }

    var numberArrayValue: [Double]? {
        if case .numberArray(let v) = self { return v }
        return nil
    }
}
