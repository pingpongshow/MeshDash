import Foundation
import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

enum Format {
    /// "3m ago", "2h ago", "Never" — the node list's freshness column.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let interval = Date().timeIntervalSince(date)
        if interval < 0 { return "Just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86_400))d ago"
    }

    static func timestamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(total % 60)s" }
        return "\(total)s"
    }

    static func bytes(_ value: Double) -> String {
        Int64(value).formatted(.byteCount(style: .memory))
    }

    /// Distance in the user's preferred units.
    static func distance(meters: Double, metric: Bool) -> String {
        if metric {
            return meters < 1000
                ? "\(Int(meters.rounded())) m"
                : "\((meters / 1000).formatted(.number.precision(.fractionLength(0...2)))) km"
        }
        let feet = meters * 3.280_84
        return feet < 5280
            ? "\(Int(feet.rounded())) ft"
            : "\((feet / 5280).formatted(.number.precision(.fractionLength(0...2)))) mi"
    }

    static func altitude(meters: Int32, metric: Bool) -> String {
        metric ? "\(meters) m" : "\(Int((Double(meters) * 3.280_84).rounded())) ft"
    }

    static func speed(kmh: Double, metric: Bool) -> String {
        metric
            ? "\(kmh.formatted(.number.precision(.fractionLength(0...1)))) km/h"
            : "\((kmh * 0.621_371).formatted(.number.precision(.fractionLength(0...1)))) mph"
    }

    static func temperature(celsius: Double, metric: Bool) -> String {
        metric
            ? "\(celsius.formatted(.number.precision(.fractionLength(0...1))))°C"
            : "\((celsius * 9 / 5 + 32).formatted(.number.precision(.fractionLength(0...1))))°F"
    }

    static func coordinate(_ latitude: Double, _ longitude: Double) -> String {
        let ns = latitude >= 0 ? "N" : "S"
        let ew = longitude >= 0 ? "E" : "W"
        return "\(abs(latitude).formatted(.number.precision(.fractionLength(5))))° \(ns), "
             + "\(abs(longitude).formatted(.number.precision(.fractionLength(5))))° \(ew)"
    }

    static func snr(_ value: Float?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) dB"
    }

    static func rssi(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value) dBm"
    }
}

/// Signal strength buckets shared by the node list and detail views.
enum SignalQuality: Int, Comparable {
    case none = 0, poor, fair, good, excellent

    static func < (lhs: SignalQuality, rhs: SignalQuality) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Meshtastic's own thresholds: SNR above about -7 dB decodes reliably on
    /// the long presets, and RSSI above -115 dBm is a usable link.
    init(snr: Float?, rssi: Int?) {
        guard let snr else {
            self = .none
            return
        }
        let rssiValue = rssi ?? -200
        if snr > -7, rssiValue > -115 {
            self = rssiValue > -100 ? .excellent : .good
        } else if snr > -12, rssiValue > -126 {
            self = .fair
        } else {
            self = .poor
        }
    }

    var label: String {
        switch self {
        case .none: "Unknown"
        case .poor: "Poor"
        case .fair: "Fair"
        case .good: "Good"
        case .excellent: "Excellent"
        }
    }

    var color: Color {
        switch self {
        case .none: .secondary
        case .poor: .red
        case .fair: .orange
        case .good: .green
        case .excellent: .green
        }
    }

    var bars: Int {
        switch self {
        case .none: 0
        case .poor: 1
        case .fair: 2
        case .good: 3
        case .excellent: 4
        }
    }
}
