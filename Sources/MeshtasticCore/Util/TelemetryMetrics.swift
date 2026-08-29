import Foundation
import MeshtasticProtobufs

/// Describes one numeric field inside a telemetry protobuf, so charts, tables
/// and the database can treat every metric the same way.
public struct MetricDescriptor: Sendable, Hashable, Identifiable {
    public var key: String
    public var label: String
    public var unit: String
    public var symbolName: String
    /// How many digits to show; percentages want none, voltages want two.
    public var fractionDigits: Int

    public var id: String { key }

    public init(_ key: String, _ label: String, _ unit: String = "", symbol: String = "chart.xyaxis.line", digits: Int = 1) {
        self.key = key
        self.label = label
        self.unit = unit
        self.symbolName = symbol
        self.fractionDigits = digits
    }

    public func format(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...fractionDigits)))
        return unit.isEmpty ? number : "\(number)\(unit.hasPrefix("°") || unit == "%" ? "" : " ")\(unit)"
    }
}

private struct Field<Message: Sendable>: Sendable {
    var descriptor: MetricDescriptor
    var value: @Sendable (Message) -> Double?
}

/// Flattens telemetry protobufs into `[key: Double]` and supplies the metadata
/// needed to label them.
public enum TelemetryMetrics {

    // MARK: - Field tables

    private static func field<M, V: BinaryFloatingPoint & Sendable>(_ descriptor: MetricDescriptor,
                                                         _ value: KeyPath<M, V> & Sendable,
                                                         _ present: KeyPath<M, Bool> & Sendable) -> Field<M> {
        Field(descriptor: descriptor) { message in
            message[keyPath: present] ? Double(message[keyPath: value]) : nil
        }
    }

    private static func field<M, V: BinaryInteger & Sendable>(_ descriptor: MetricDescriptor,
                                                   _ value: KeyPath<M, V> & Sendable,
                                                   _ present: KeyPath<M, Bool> & Sendable) -> Field<M> {
        Field(descriptor: descriptor) { message in
            message[keyPath: present] ? Double(message[keyPath: value]) : nil
        }
    }

    /// For fields with no `has` accessor, where zero means "not reported".
    private static func nonZero<M, V: BinaryInteger & Sendable>(_ descriptor: MetricDescriptor,
                                                     _ value: KeyPath<M, V> & Sendable) -> Field<M> {
        Field(descriptor: descriptor) { message in
            let raw = Double(message[keyPath: value])
            return raw == 0 ? nil : raw
        }
    }

    private static func nonZero<M, V: BinaryFloatingPoint & Sendable>(_ descriptor: MetricDescriptor,
                                                           _ value: KeyPath<M, V> & Sendable) -> Field<M> {
        Field(descriptor: descriptor) { message in
            let raw = Double(message[keyPath: value])
            return raw == 0 ? nil : raw
        }
    }

    private static let deviceFields: [Field<DeviceMetrics>] = [
        field(.init("batteryLevel", "Battery", "%", symbol: "battery.100", digits: 0), \.batteryLevel, \.hasBatteryLevel),
        field(.init("voltage", "Voltage", "V", symbol: "bolt", digits: 2), \.voltage, \.hasVoltage),
        field(.init("channelUtilization", "Channel Utilization", "%", symbol: "chart.bar", digits: 1), \.channelUtilization, \.hasChannelUtilization),
        field(.init("airUtilTx", "Air Time (TX)", "%", symbol: "antenna.radiowaves.left.and.right", digits: 1), \.airUtilTx, \.hasAirUtilTx),
        field(.init("uptimeSeconds", "Uptime", "s", symbol: "clock", digits: 0), \.uptimeSeconds, \.hasUptimeSeconds),
    ]

    private static let environmentFields: [Field<EnvironmentMetrics>] = {
        var fields: [Field<EnvironmentMetrics>] = []
        fields += [
            field(.init("temperature", "Temperature", "°C", symbol: "thermometer.medium", digits: 1), \.temperature, \.hasTemperature),
            field(.init("relativeHumidity", "Humidity", "%", symbol: "humidity", digits: 1), \.relativeHumidity, \.hasRelativeHumidity),
            field(.init("barometricPressure", "Pressure", "hPa", symbol: "barometer", digits: 1), \.barometricPressure, \.hasBarometricPressure),
            field(.init("gasResistance", "Gas Resistance", "MΩ", symbol: "aqi.medium", digits: 2), \.gasResistance, \.hasGasResistance),
            field(.init("voltage", "Voltage", "V", symbol: "bolt", digits: 2), \.voltage, \.hasVoltage),
            field(.init("current", "Current", "mA", symbol: "bolt.horizontal", digits: 1), \.current, \.hasCurrent),
        ]
        fields += [
            field(.init("iaq", "Air Quality Index", "", symbol: "aqi.medium", digits: 0), \.iaq, \.hasIaq),
            field(.init("distance", "Distance", "mm", symbol: "ruler", digits: 0), \.distance, \.hasDistance),
            field(.init("lux", "Illuminance", "lx", symbol: "sun.max", digits: 0), \.lux, \.hasLux),
            field(.init("whiteLux", "White Light", "lx", symbol: "sun.max", digits: 0), \.whiteLux, \.hasWhiteLux),
            field(.init("irLux", "Infrared", "lx", symbol: "sun.max", digits: 0), \.irLux, \.hasIrLux),
            field(.init("uvLux", "Ultraviolet", "lx", symbol: "sun.max.trianglebadge.exclamationmark", digits: 0), \.uvLux, \.hasUvLux),
        ]
        fields += [
            field(.init("windDirection", "Wind Direction", "°", symbol: "location.north.line", digits: 0), \.windDirection, \.hasWindDirection),
            field(.init("windSpeed", "Wind Speed", "m/s", symbol: "wind", digits: 1), \.windSpeed, \.hasWindSpeed),
            field(.init("windGust", "Wind Gust", "m/s", symbol: "wind", digits: 1), \.windGust, \.hasWindGust),
            field(.init("windLull", "Wind Lull", "m/s", symbol: "wind", digits: 1), \.windLull, \.hasWindLull),
            field(.init("weight", "Weight", "kg", symbol: "scalemass", digits: 2), \.weight, \.hasWeight),
            field(.init("radiation", "Radiation", "µR/h", symbol: "atom", digits: 2), \.radiation, \.hasRadiation),
        ]
        fields += [
            field(.init("rainfall1H", "Rainfall (1 h)", "mm", symbol: "cloud.rain", digits: 1), \.rainfall1H, \.hasRainfall1H),
            field(.init("rainfall24H", "Rainfall (24 h)", "mm", symbol: "cloud.rain", digits: 1), \.rainfall24H, \.hasRainfall24H),
            field(.init("soilMoisture", "Soil Moisture", "%", symbol: "drop", digits: 0), \.soilMoisture, \.hasSoilMoisture),
            field(.init("soilTemperature", "Soil Temperature", "°C", symbol: "thermometer.low", digits: 1), \.soilTemperature, \.hasSoilTemperature),
            field(.init("lightningStrikeCount1H", "Lightning Strikes (1 h)", "", symbol: "bolt.trianglebadge.exclamationmark", digits: 0), \.lightningStrikeCount1H, \.hasLightningStrikeCount1H),
            field(.init("lightningDistanceKm", "Lightning Distance", "km", symbol: "bolt.trianglebadge.exclamationmark", digits: 0), \.lightningDistanceKm, \.hasLightningDistanceKm),
        ]
        fields += [
            // `oneWireTemperature` is a repeated field; surface the first probe here
        // and the fixed channel slots below.
        Field(descriptor: .init("oneWireTemperature", "1-Wire Temperature", "°C", symbol: "thermometer.medium", digits: 1)) {
            $0.oneWireTemperature.first.map(Double.init)
        },
        ]
        fields += sensorChannelFields
        return fields
    }()

    /// The eight ADC and eight 1-Wire slots a multi-probe sensor board reports.
    private static let sensorChannelFields: [Field<EnvironmentMetrics>] = {
        let adcPaths: [KeyPath<EnvironmentMetrics, Float> & Sendable] = [
            \.adcVoltageCh0, \.adcVoltageCh1, \.adcVoltageCh2, \.adcVoltageCh3,
            \.adcVoltageCh4, \.adcVoltageCh5, \.adcVoltageCh6, \.adcVoltageCh7]
        let adcFlags: [KeyPath<EnvironmentMetrics, Bool> & Sendable] = [
            \.hasAdcVoltageCh0, \.hasAdcVoltageCh1, \.hasAdcVoltageCh2, \.hasAdcVoltageCh3,
            \.hasAdcVoltageCh4, \.hasAdcVoltageCh5, \.hasAdcVoltageCh6, \.hasAdcVoltageCh7]
        let wirePaths: [KeyPath<EnvironmentMetrics, Float> & Sendable] = [
            \.oneWireTemperatureCh0, \.oneWireTemperatureCh1, \.oneWireTemperatureCh2, \.oneWireTemperatureCh3,
            \.oneWireTemperatureCh4, \.oneWireTemperatureCh5, \.oneWireTemperatureCh6, \.oneWireTemperatureCh7]
        let wireFlags: [KeyPath<EnvironmentMetrics, Bool> & Sendable] = [
            \.hasOneWireTemperatureCh0, \.hasOneWireTemperatureCh1, \.hasOneWireTemperatureCh2, \.hasOneWireTemperatureCh3,
            \.hasOneWireTemperatureCh4, \.hasOneWireTemperatureCh5, \.hasOneWireTemperatureCh6, \.hasOneWireTemperatureCh7]
        return (0..<8).flatMap { index -> [Field<EnvironmentMetrics>] in
            [
                field(.init("adcVoltageCh\(index)", "ADC Channel \(index)", "V", symbol: "bolt", digits: 3),
                      adcPaths[index], adcFlags[index]),
                field(.init("oneWireTemperatureCh\(index)", "1-Wire Probe \(index)", "°C", symbol: "thermometer.medium", digits: 1),
                      wirePaths[index], wireFlags[index]),
            ]
        }
    }()

    private static let airQualityFields: [Field<AirQualityMetrics>] = [
        field(.init("pm10Standard", "PM1.0", "µg/m³", symbol: "aqi.low", digits: 0), \.pm10Standard, \.hasPm10Standard),
        field(.init("pm25Standard", "PM2.5", "µg/m³", symbol: "aqi.medium", digits: 0), \.pm25Standard, \.hasPm25Standard),
        field(.init("pm40Standard", "PM4.0", "µg/m³", symbol: "aqi.medium", digits: 0), \.pm40Standard, \.hasPm40Standard),
        field(.init("pm100Standard", "PM10", "µg/m³", symbol: "aqi.high", digits: 0), \.pm100Standard, \.hasPm100Standard),
        field(.init("co2", "CO₂", "ppm", symbol: "carbon.dioxide.cloud", digits: 0), \.co2, \.hasCo2),
        field(.init("co2Temperature", "CO₂ Sensor Temperature", "°C", symbol: "thermometer.medium", digits: 1), \.co2Temperature, \.hasCo2Temperature),
        field(.init("co2Humidity", "CO₂ Sensor Humidity", "%", symbol: "humidity", digits: 1), \.co2Humidity, \.hasCo2Humidity),
        field(.init("pmTemperature", "PM Sensor Temperature", "°C", symbol: "thermometer.medium", digits: 1), \.pmTemperature, \.hasPmTemperature),
        field(.init("pmHumidity", "PM Sensor Humidity", "%", symbol: "humidity", digits: 1), \.pmHumidity, \.hasPmHumidity),
        field(.init("pmVocIdx", "VOC Index", "", symbol: "aqi.medium", digits: 0), \.pmVocIdx, \.hasPmVocIdx),
        field(.init("pmNoxIdx", "NOx Index", "", symbol: "aqi.medium", digits: 0), \.pmNoxIdx, \.hasPmNoxIdx),
        field(.init("formFormaldehyde", "Formaldehyde", "ppb", symbol: "aqi.high", digits: 1), \.formFormaldehyde, \.hasFormFormaldehyde),
        field(.init("particles03Um", "Particles > 0.3 µm", "/dL", symbol: "circle.grid.3x3", digits: 0), \.particles03Um, \.hasParticles03Um),
        field(.init("particles05Um", "Particles > 0.5 µm", "/dL", symbol: "circle.grid.3x3", digits: 0), \.particles05Um, \.hasParticles05Um),
        field(.init("particles10Um", "Particles > 1.0 µm", "/dL", symbol: "circle.grid.3x3", digits: 0), \.particles10Um, \.hasParticles10Um),
        field(.init("particles25Um", "Particles > 2.5 µm", "/dL", symbol: "circle.grid.3x3", digits: 0), \.particles25Um, \.hasParticles25Um),
        field(.init("particles50Um", "Particles > 5.0 µm", "/dL", symbol: "circle.grid.3x3", digits: 0), \.particles50Um, \.hasParticles50Um),
        field(.init("particles100Um", "Particles > 10 µm", "/dL", symbol: "circle.grid.3x3", digits: 0), \.particles100Um, \.hasParticles100Um),
    ]

    private static let powerFields: [Field<PowerMetrics>] = (1...8).flatMap { channel -> [Field<PowerMetrics>] in
        let voltagePaths: [KeyPath<PowerMetrics, Float> & Sendable] = [\.ch1Voltage, \.ch2Voltage, \.ch3Voltage, \.ch4Voltage,
                                                            \.ch5Voltage, \.ch6Voltage, \.ch7Voltage, \.ch8Voltage]
        let voltageFlags: [KeyPath<PowerMetrics, Bool> & Sendable] = [\.hasCh1Voltage, \.hasCh2Voltage, \.hasCh3Voltage, \.hasCh4Voltage,
                                                           \.hasCh5Voltage, \.hasCh6Voltage, \.hasCh7Voltage, \.hasCh8Voltage]
        let currentPaths: [KeyPath<PowerMetrics, Float> & Sendable] = [\.ch1Current, \.ch2Current, \.ch3Current, \.ch4Current,
                                                            \.ch5Current, \.ch6Current, \.ch7Current, \.ch8Current]
        let currentFlags: [KeyPath<PowerMetrics, Bool> & Sendable] = [\.hasCh1Current, \.hasCh2Current, \.hasCh3Current, \.hasCh4Current,
                                                           \.hasCh5Current, \.hasCh6Current, \.hasCh7Current, \.hasCh8Current]
        let index = channel - 1
        return [
            field(.init("ch\(channel)Voltage", "Channel \(channel) Voltage", "V", symbol: "bolt", digits: 3),
                  voltagePaths[index], voltageFlags[index]),
            field(.init("ch\(channel)Current", "Channel \(channel) Current", "mA", symbol: "bolt.horizontal", digits: 1),
                  currentPaths[index], currentFlags[index]),
        ]
    }

    private static let localStatsFields: [Field<LocalStats>] = [
        nonZero(.init("uptimeSeconds", "Uptime", "s", symbol: "clock", digits: 0), \.uptimeSeconds),
        Field(descriptor: .init("channelUtilization", "Channel Utilization", "%", symbol: "chart.bar", digits: 1)) { Double($0.channelUtilization) },
        Field(descriptor: .init("airUtilTx", "Air Time (TX)", "%", symbol: "antenna.radiowaves.left.and.right", digits: 1)) { Double($0.airUtilTx) },
        Field(descriptor: .init("numPacketsTx", "Packets Sent", "", symbol: "arrow.up", digits: 0)) { Double($0.numPacketsTx) },
        Field(descriptor: .init("numPacketsRx", "Packets Received", "", symbol: "arrow.down", digits: 0)) { Double($0.numPacketsRx) },
        Field(descriptor: .init("numPacketsRxBad", "Bad Packets", "", symbol: "exclamationmark.triangle", digits: 0)) { Double($0.numPacketsRxBad) },
        Field(descriptor: .init("numOnlineNodes", "Nodes Online", "", symbol: "person.2", digits: 0)) { Double($0.numOnlineNodes) },
        Field(descriptor: .init("numTotalNodes", "Nodes Known", "", symbol: "person.3", digits: 0)) { Double($0.numTotalNodes) },
        Field(descriptor: .init("numRxDupe", "Duplicates Received", "", symbol: "doc.on.doc", digits: 0)) { Double($0.numRxDupe) },
        Field(descriptor: .init("numTxRelay", "Packets Relayed", "", symbol: "arrow.triangle.branch", digits: 0)) { Double($0.numTxRelay) },
        Field(descriptor: .init("numTxRelayCanceled", "Relays Canceled", "", symbol: "xmark.circle", digits: 0)) { Double($0.numTxRelayCanceled) },
        Field(descriptor: .init("numTxDropped", "Transmits Dropped", "", symbol: "trash", digits: 0)) { Double($0.numTxDropped) },
        nonZero(.init("heapFreeBytes", "Free Heap", "B", symbol: "memorychip", digits: 0), \.heapFreeBytes),
        nonZero(.init("heapTotalBytes", "Total Heap", "B", symbol: "memorychip", digits: 0), \.heapTotalBytes),
        Field(descriptor: .init("noiseFloor", "Noise Floor", "dBm", symbol: "waveform", digits: 0)) {
            $0.noiseFloor == 0 ? nil : Double($0.noiseFloor)
        },
    ]

    private static let healthFields: [Field<HealthMetrics>] = [
        field(.init("heartBpm", "Heart Rate", "bpm", symbol: "heart", digits: 0), \.heartBpm, \.hasHeartBpm),
        field(.init("spO2", "Blood Oxygen", "%", symbol: "lungs", digits: 0), \.spO2, \.hasSpO2),
        field(.init("temperature", "Body Temperature", "°C", symbol: "thermometer.medium", digits: 1), \.temperature, \.hasTemperature),
    ]

    private static let hostFields: [Field<HostMetrics>] = [
        nonZero(.init("uptimeSeconds", "Uptime", "s", symbol: "clock", digits: 0), \.uptimeSeconds),
        nonZero(.init("freememBytes", "Free Memory", "B", symbol: "memorychip", digits: 0), \.freememBytes),
        nonZero(.init("diskfree1Bytes", "Disk 1 Free", "B", symbol: "internaldrive", digits: 0), \.diskfree1Bytes),
        field(.init("diskfree2Bytes", "Disk 2 Free", "B", symbol: "internaldrive", digits: 0), \.diskfree2Bytes, \.hasDiskfree2Bytes),
        field(.init("diskfree3Bytes", "Disk 3 Free", "B", symbol: "internaldrive", digits: 0), \.diskfree3Bytes, \.hasDiskfree3Bytes),
        Field(descriptor: .init("load1", "Load (1 min)", "", symbol: "gauge", digits: 2)) { Double($0.load1) / 100 },
        Field(descriptor: .init("load5", "Load (5 min)", "", symbol: "gauge", digits: 2)) { Double($0.load5) / 100 },
        Field(descriptor: .init("load15", "Load (15 min)", "", symbol: "gauge", digits: 2)) { Double($0.load15) / 100 },
    ]

    private static let trafficFields: [Field<TrafficManagementStats>] = [
        Field(descriptor: .init("packetsInspected", "Packets Inspected", "", symbol: "magnifyingglass", digits: 0)) { Double($0.packetsInspected) },
        Field(descriptor: .init("positionDedupDrops", "Position Duplicates Dropped", "", symbol: "location.slash", digits: 0)) { Double($0.positionDedupDrops) },
        Field(descriptor: .init("nodeinfoCacheHits", "Node Info Cache Hits", "", symbol: "tray.full", digits: 0)) { Double($0.nodeinfoCacheHits) },
        Field(descriptor: .init("rateLimitDrops", "Rate Limit Drops", "", symbol: "hand.raised", digits: 0)) { Double($0.rateLimitDrops) },
        Field(descriptor: .init("unknownPacketDrops", "Unknown Packets Dropped", "", symbol: "questionmark.circle", digits: 0)) { Double($0.unknownPacketDrops) },
        Field(descriptor: .init("hopExhaustedPackets", "Hop-Exhausted Packets", "", symbol: "arrow.uturn.down", digits: 0)) { Double($0.hopExhaustedPackets) },
        Field(descriptor: .init("routerHopsPreserved", "Router Hops Preserved", "", symbol: "arrow.triangle.branch", digits: 0)) { Double($0.routerHopsPreserved) },
    ]

    // MARK: - Public API

    /// Every metric a given telemetry kind can report, in display order.
    public static func descriptors(for kind: TelemetryKind) -> [MetricDescriptor] {
        switch kind {
        case .device: deviceFields.map(\.descriptor)
        case .environment: environmentFields.map(\.descriptor)
        case .airQuality: airQualityFields.map(\.descriptor)
        case .power: powerFields.map(\.descriptor)
        case .localStats: localStatsFields.map(\.descriptor)
        case .health: healthFields.map(\.descriptor)
        case .host: hostFields.map(\.descriptor)
        case .trafficManagement: trafficFields.map(\.descriptor)
        }
    }

    public static func descriptor(kind: TelemetryKind, key: String) -> MetricDescriptor? {
        descriptors(for: kind).first { $0.key == key }
    }

    /// Turns a telemetry packet into a storable sample, or nil if it carried no
    /// readings (which is how a telemetry *request* arrives).
    public static func sample(from telemetry: Telemetry, nodeNum: UInt32, fallbackTime: Date) -> TelemetrySample? {
        let time = telemetry.time > 0 ? Date(timeIntervalSince1970: TimeInterval(telemetry.time)) : fallbackTime
        guard let variant = telemetry.variant else { return nil }

        func collect<M>(_ fields: [Field<M>], _ message: M) -> [String: Double] {
            var metrics: [String: Double] = [:]
            for field in fields {
                if let value = field.value(message) { metrics[field.descriptor.key] = value }
            }
            return metrics
        }

        let kind: TelemetryKind
        let metrics: [String: Double]
        switch variant {
        case .deviceMetrics(let message): kind = .device; metrics = collect(deviceFields, message)
        case .environmentMetrics(let message): kind = .environment; metrics = collect(environmentFields, message)
        case .airQualityMetrics(let message): kind = .airQuality; metrics = collect(airQualityFields, message)
        case .powerMetrics(let message): kind = .power; metrics = collect(powerFields, message)
        case .localStats(let message): kind = .localStats; metrics = collect(localStatsFields, message)
        case .healthMetrics(let message): kind = .health; metrics = collect(healthFields, message)
        case .hostMetrics(let message): kind = .host; metrics = collect(hostFields, message)
        case .trafficManagementStats(let message): kind = .trafficManagement; metrics = collect(trafficFields, message)
        }
        guard !metrics.isEmpty else { return nil }
        return TelemetrySample(nodeNum: nodeNum, kind: kind, time: time, metrics: metrics)
    }
}
