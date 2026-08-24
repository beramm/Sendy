import Foundation

/// View-only scale and formatting rules for pipeline-produced sequence metrics.
/// The analysis chooses which metrics matter; this type only draws their
/// already-computed values on a shared, meaningful domain.
struct MetricPresentation {
    var kind: MetricKind
    var lowerBound: Double
    var upperBound: Double

    init(kind: MetricKind, values: [Double]) {
        self.kind = kind

        switch kind {
        case .straightArmRatio, .loadAsymmetry, .armLoadShare, .armLoadPeak,
             .unweightedFootTime, .feetSetBeforeReach, .pullingArmTime,
             .latLoadTime, .elbowFlexTime, .diagonalLoadBalance,
             .comPathEfficiency:
            lowerBound = 0
            upperBound = 1
        case .hipDistanceMean, .hipDistancePeak, .hipDistanceStart, .hipDistanceEnd,
             .reachMargin:
            lowerBound = 0
            upperBound = 2
        case .kneeDrive:
            // Knee drive is signed around the ankle: negative is behind it,
            // positive is driven past it. Keep zero centered in the bar.
            lowerBound = min(-1, (values.min() ?? 0) * 1.15)
            upperBound = max(1, (values.max() ?? 0) * 1.15)
        case .comPathLength, .comDisplacement:
            lowerBound = 0
            upperBound = 3
        case .comPeakVelocity:
            lowerBound = 0
            upperBound = 4
        case .footCommitmentSeconds:
            lowerBound = 0
            upperBound = max(4, (values.max() ?? 0) * 1.15)
        case .footPlacementCount:
            lowerBound = 0
            upperBound = max(6, ceil(values.max() ?? 0))
        case .hipTwist, .pelvisTilt, .pelvisTiltStart, .pelvisTiltEnd,
             .pelvisTurn, .pelvisTurnStart, .pelvisTurnEnd,
             .torsoLean, .torsoLeanStart, .torsoLeanEnd:
            lowerBound = 0
            upperBound = 90
        case .sectionDwellRatio:
            lowerBound = 0
            upperBound = max(3, (values.max() ?? 0) * 1.15)
        }
    }

    func fraction(for value: Double?) -> Double {
        guard let value, upperBound > lowerBound else { return 0 }
        return ((value - lowerBound) / (upperBound - lowerBound)).clamped(to: 0 ... 1)
    }

    func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        switch kind.unit {
        case "%": return String(format: "%.0f%%", value * 100)
        case "°": return String(format: "%.0f°", value)
        case "s": return String(format: "%.1fs", value)
        case "count": return String(format: "%.0f", value)
        case "×": return String(format: "%.2f×", value)
        default: return String(format: "%.2f", value)
        }
    }
}
