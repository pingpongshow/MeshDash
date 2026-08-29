import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

// MARK: - Identity

struct IdentityForm: View {
    @Environment(MeshSession.self) private var session
    @State private var longName = ""
    @State private var shortName = ""
    @State private var isLicensed = false
    @State private var isUnmessagable = false
    @State private var loaded = false

    private var user: User? { session.myNode?.user }

    private var isDirty: Bool {
        guard let user else { return false }
        return longName != user.longName || shortName != user.shortName
            || isLicensed != user.isLicensed
            || isUnmessagable != (user.hasIsUnmessagable ? user.isUnmessagable : false)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Names") {
                    TextField("Long name", text: $longName)
                        .onChange(of: longName) { _, new in
                            // The firmware stores names as bytes, not characters.
                            if new.utf8.count > 39 { longName = String(new.prefix(new.count - 1)) }
                        }
                    FieldNote("Shown in node lists across the mesh. Up to 39 bytes — \(39 - longName.utf8.count) left.")

                    TextField("Short name", text: $shortName)
                        .onChange(of: shortName) { _, new in
                            if new.utf8.count > 4 { shortName = String(new.prefix(new.count - 1)) }
                        }
                    FieldNote("Two to four characters, drawn on the device screen and on map pins.")
                }

                Section("Options") {
                    Toggle("Licensed amateur radio operator", isOn: $isLicensed)
                    FieldNote(isLicensed
                        ? "Encryption is disabled and your call sign travels in the clear, as amateur licensing requires."
                        : "Turn this on only if you are transmitting under an amateur radio licence.",
                        isWarning: isLicensed)

                    Toggle("Tell others this node cannot receive messages", isOn: $isUnmessagable)
                    FieldNote("Useful for sensors and repeaters, so people do not message a node with no screen or operator.")
                }

                Section("Node") {
                    if let node = session.myNode {
                        DetailRow("Node ID", node.hexID, monospaced: true)
                        DetailRow("Node Number", "\(node.num)", monospaced: true)
                        DetailRow("Hardware", node.hardwareModel.displayName)
                    }
                    if let metadata = session.metadata {
                        DetailRow("Firmware", metadata.firmwareVersion, monospaced: true)
                        DetailRow("Bluetooth", metadata.hasBluetooth_p ? "Supported" : "Not supported")
                        DetailRow("WiFi", metadata.hasWifi_p ? "Supported" : "Not supported")
                        DetailRow("Ethernet", metadata.hasEthernet_p ? "Supported" : "Not supported")
                        DetailRow("Public Key Cryptography", metadata.hasPkc_p ? "Supported" : "Not supported")
                    }
                    if let info = session.myInfo {
                        DetailRow("Reboots", "\(info.rebootCount)")
                        DetailRow("Nodes in Database", "\(info.nodedbCount)")
                    }
                }
            }
            .formStyle(.grouped)

            if isDirty {
                Divider()
                SaveBar(isDirty: isDirty, isBusy: false) {
                    Task {
                        await session.setOwner(longName: longName, shortName: shortName,
                                               isLicensed: isLicensed, isUnmessagable: isUnmessagable)
                    }
                } revert: { load() }
            }
        }
        .navigationTitle("Identity")
        .onAppear { if !loaded { load(); loaded = true } }
        .onChange(of: session.myNode?.user) { _, _ in if !isDirty { load() } }
    }

    private func load() {
        guard let user else { return }
        longName = user.longName
        shortName = user.shortName
        isLicensed = user.isLicensed
        isUnmessagable = user.hasIsUnmessagable ? user.isUnmessagable : false
    }
}

// MARK: - Device

struct DeviceConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Device",
                        subtitle: "How this radio behaves on the mesh",
                        current: session.deviceConfig,
                        save: { await session.saveDeviceConfig($0) }) { config in
            Section("Role") {
                Picker("Role", selection: config.role) {
                    ForEach(deviceRoles, id: \.self) { Text($0.displayName).tag($0) }
                }
                FieldNote(config.wrappedValue.role.explanation,
                          isWarning: config.wrappedValue.role.isInfrastructure)
                if config.wrappedValue.role.isInfrastructure {
                    FieldNote("Router and Repeater roles rebroadcast everything they hear. Using them on a node you carry around congests the mesh for everyone.", isWarning: true)
                }
            }

            Section("Rebroadcasting") {
                Picker("Rebroadcast mode", selection: config.rebroadcastMode) {
                    ForEach(rebroadcastModes, id: \.self) { Text(humanizedName($0)).tag($0) }
                }
                FieldNote("Controls which packets this node repeats. \"All\" is the normal setting; the others restrict repeating to your own channels or turn it off.")
            }

            Section("Broadcast Intervals") {
                IntervalPicker(title: "Node info broadcast", seconds: config.nodeInfoBroadcastSecs,
                               offLabel: "Default (3 hours)",
                               options: [3600, 7200, 10800, 21600, 43200, 86400])
                FieldNote("How often this radio tells the mesh its name and hardware. Shorter intervals use more airtime.")
            }

            Section("Buttons and Indicators") {
                PinField(title: "Button GPIO", pin: config.buttonGpio,
                         help: "Override the user button pin. Leave at 0 unless your board needs it.")
                PinField(title: "Buzzer GPIO", pin: config.buzzerGpio)
                Picker("Buzzer mode", selection: config.buzzerMode) {
                    ForEach(buzzerModes, id: \.self) { Text(humanizedName($0)).tag($0) }
                }
                Toggle("Double tap counts as a button press", isOn: config.doubleTapAsButtonPress)
                Toggle("Disable triple click", isOn: config.disableTripleClick)
                Toggle("Turn off the LED heartbeat", isOn: config.ledHeartbeatDisabled)
                FieldNote("The heartbeat LED blinks to show the firmware is alive. Turning it off saves a little power.")
            }

            Section("Serial Console") {
                Toggle("Enable the serial console", isOn: config.serialEnabled)
                FieldNote("Leave this on. Turning it off stops MeshDash and the Python CLI from connecting over USB.",
                          isWarning: !config.wrappedValue.serialEnabled)
            }

            Section("Time Zone") {
                TextField("POSIX time zone", text: config.tzdef, prompt: Text("EST5EDT,M3.2.0,M11.1.0"))
                    .font(.system(.body, design: .monospaced))
                FieldNote("Used for the clock on the device screen. Leave empty to use UTC.")
                Button("Use This Mac's Time Zone") {
                    config.tzdef.wrappedValue = posixTimeZoneString()
                }
            }

            Section("Managed Mode") {
                Toggle("Managed device", isOn: config.isManaged)
                FieldNote("A managed device refuses configuration changes except from an authorized admin key. Turn this on only after you have set an admin key in Security, or you will lock yourself out.",
                          isWarning: config.wrappedValue.isManaged)
            }
        }
    }

    private var deviceRoles: [Config.DeviceConfig.Role] {
        [.client, .clientMute, .clientHidden, .clientBase, .router, .routerLate, .repeater,
         .tracker, .sensor, .tak, .takTracker, .lostAndFound]
    }
    private var rebroadcastModes: [Config.DeviceConfig.RebroadcastMode] {
        Config.DeviceConfig.RebroadcastMode.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }
    private var buzzerModes: [Config.DeviceConfig.BuzzerMode] {
        Config.DeviceConfig.BuzzerMode.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }

    /// Builds the POSIX TZ string the firmware expects from the Mac's zone.
    private func posixTimeZoneString() -> String {
        let zone = TimeZone.current
        let standardOffset = -zone.secondsFromGMT(for: Date(timeIntervalSince1970: 0)) / 3600
        let abbreviation = zone.abbreviation() ?? "UTC"
        return "\(abbreviation)\(standardOffset)"
    }
}

// MARK: - Position

struct PositionConfigForm: View {
    @Environment(MeshSession.self) private var session
    @State private var fixedLatitude = ""
    @State private var fixedLongitude = ""
    @State private var fixedAltitude = ""

    var body: some View {
        ConfigFormShell(title: "Position",
                        subtitle: "GPS and location sharing",
                        current: session.positionConfig,
                        save: { await session.savePositionConfig($0) }) { config in
            Section("GPS") {
                Picker("GPS mode", selection: config.gpsMode) {
                    ForEach(gpsModes, id: \.self) { Text(humanizedName($0)).tag($0) }
                }
                FieldNote("\"Enabled\" powers the GPS normally. \"Not present\" tells the firmware there is no GPS at all, which saves power on boards that do not have one.")

                IntervalPicker(title: "GPS update interval", seconds: config.gpsUpdateInterval,
                               offLabel: "Default (2 minutes)",
                               options: [30, 60, 120, 300, 600, 900, 1800, 3600])
                PinField(title: "GPS receive GPIO", pin: config.rxGpio)
                PinField(title: "GPS transmit GPIO", pin: config.txGpio)
                PinField(title: "GPS enable GPIO", pin: config.gpsEnGpio)
            }

            Section("Broadcasting") {
                IntervalPicker(title: "Position broadcast", seconds: config.positionBroadcastSecs,
                               offLabel: "Default (15 minutes)",
                               options: [60, 300, 900, 1800, 3600, 7200, 21600, 43200])
                Toggle("Smart position broadcast", isOn: config.positionBroadcastSmartEnabled)
                FieldNote("Smart broadcast only sends a position when you have actually moved, which saves a lot of airtime on a node that sits still.")

                if config.wrappedValue.positionBroadcastSmartEnabled {
                    LabeledContent("Minimum distance") {
                        TextField("", value: config.broadcastSmartMinimumDistance, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    FieldNote("Metres of movement before a new position goes out. Zero uses the firmware default.")
                    IntervalPicker(title: "Minimum interval",
                                   seconds: config.broadcastSmartMinimumIntervalSecs,
                                   offLabel: "Default",
                                   options: [30, 60, 120, 300, 600])
                }
            }

            Section("Fixed Position") {
                Toggle("This node does not move", isOn: config.fixedPosition)
                FieldNote("A fixed position is broadcast without needing a GPS fix. Set the coordinates below, then save.")

                if config.wrappedValue.fixedPosition {
                    LabeledContent("Latitude") {
                        TextField("", text: $fixedLatitude).textFieldStyle(.roundedBorder).frame(width: 130)
                    }
                    LabeledContent("Longitude") {
                        TextField("", text: $fixedLongitude).textFieldStyle(.roundedBorder).frame(width: 130)
                    }
                    LabeledContent("Altitude (m)") {
                        TextField("", text: $fixedAltitude).textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    HStack {
                        Button("Set Fixed Position on Radio") {
                            guard let latitude = Double(fixedLatitude), let longitude = Double(fixedLongitude) else { return }
                            Task {
                                await session.setFixedPosition(latitude: latitude, longitude: longitude,
                                                               altitude: Int32(fixedAltitude) ?? nil)
                            }
                        }
                        .disabled(Double(fixedLatitude) == nil || Double(fixedLongitude) == nil)
                        Button("Clear") { Task { await session.clearFixedPosition() } }
                    }
                }
            }

            Section("What to Share") {
                PositionFlagsEditor(flags: config.positionFlags)
            }
        }
        .onAppear {
            if let position = session.myNode?.position, position.latitudeI != 0 {
                fixedLatitude = String(Double(position.latitudeI) * 1e-7)
                fixedLongitude = String(Double(position.longitudeI) * 1e-7)
                fixedAltitude = String(position.altitude)
            }
        }
    }

    private var gpsModes: [Config.PositionConfig.GpsMode] {
        Config.PositionConfig.GpsMode.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }
}

/// The `position_flags` bitfield decides which fields ride along with a position.
private struct PositionFlagsEditor: View {
    @Binding var flags: UInt32

    private static let options: [(bit: UInt32, label: String, note: String)] = [
        (1, "Altitude", "Include height above sea level."),
        (2, "Altitude is mean sea level", "Report altitude relative to MSL rather than the ellipsoid."),
        (4, "Geoidal separation", "Include the difference between the two altitude references."),
        (8, "Dilution of precision", "Include a single combined accuracy figure."),
        (16, "Horizontal and vertical precision", "Include separate horizontal and vertical accuracy."),
        (32, "Satellites in view", "Include how many satellites the GPS can see."),
        (64, "Sequence number", "Include a counter so receivers can spot gaps."),
        (128, "Timestamp", "Include the exact time of the fix."),
        (256, "Heading", "Include the direction of travel."),
        (512, "Speed", "Include ground speed."),
    ]

    var body: some View {
        ForEach(Self.options, id: \.bit) { option in
            Toggle(option.label, isOn: Binding(
                get: { flags & option.bit != 0 },
                set: { isOn in
                    if isOn { flags |= option.bit } else { flags &= ~option.bit }
                }
            ))
            .help(option.note)
        }
        FieldNote("Every extra field makes the position packet larger and uses more airtime. Altitude and satellites are the usual choices.")
    }
}

// MARK: - Power

struct PowerConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Power",
                        subtitle: "Sleep behaviour and battery measurement",
                        current: session.powerConfig,
                        save: { await session.savePowerConfig($0) }) { config in
            Section("Power Saving") {
                Toggle("Power saving mode", isOn: config.isPowerSaving)
                FieldNote("Puts the ESP32 into light sleep between transmissions. It extends battery life considerably but adds latency, so a node in this mode is a poor router.")
            }

            Section("Sleep Timers") {
                IntervalPicker(title: "Super-deep sleep after", seconds: config.sdsSecs,
                               offLabel: "Never", options: [3600, 7200, 21600, 43200, 86400])
                FieldNote("The radio powers down almost completely. It will not hear anything until it wakes.")

                IntervalPicker(title: "Light sleep after", seconds: config.lsSecs,
                               offLabel: "Default", options: [30, 60, 300, 600, 1800, 3600])
                IntervalPicker(title: "Minimum wake time", seconds: config.minWakeSecs,
                               offLabel: "Default", options: [10, 30, 60, 120, 300])
                IntervalPicker(title: "Wait for Bluetooth", seconds: config.waitBluetoothSecs,
                               offLabel: "Default", options: [10, 30, 60, 120])
                FieldNote("How long the radio stays awake waiting for a phone or Mac to connect before sleeping again.")

                IntervalPicker(title: "Shut down on battery after", seconds: config.onBatteryShutdownAfterSecs,
                               offLabel: "Never", options: [3600, 7200, 21600, 43200, 86400])
            }

            Section("Battery Measurement") {
                LabeledContent("ADC multiplier override") {
                    TextField("", value: config.adcMultiplierOverride, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                FieldNote("Corrects a battery percentage that reads consistently high or low. Zero uses the value built into the firmware for your board.")

                LabeledContent("INA current sensor I²C address") {
                    TextField("", value: config.deviceBatteryInaAddress, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                FieldNote("Only needed if you have wired an INA219 or INA260 to measure battery current.")
            }
        }
    }
}

// MARK: - Network

struct NetworkConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Network",
                        subtitle: "WiFi, Ethernet, and the network API",
                        current: session.networkConfig,
                        save: { await session.saveNetworkConfig($0) }) { config in
            Section("WiFi") {
                Toggle("Enable WiFi", isOn: config.wifiEnabled)
                FieldNote("WiFi and Bluetooth cannot both run on an ESP32. Turning WiFi on disables the Bluetooth connection to this radio.",
                          isWarning: config.wrappedValue.wifiEnabled)
                TextField("Network name", text: config.wifiSsid)
                    .disabled(!config.wrappedValue.wifiEnabled)
                SecureField("Password", text: config.wifiPsk)
                    .disabled(!config.wrappedValue.wifiEnabled)
                FieldNote("Once the radio joins your network it appears in MeshDash's Network tab automatically, and you can connect to it over TCP.")
            }

            Section("Ethernet") {
                Toggle("Enable Ethernet", isOn: config.ethEnabled)
                FieldNote("For boards with a wired network port, such as the T-Eth Elite.")
            }

            Section("Addressing") {
                Picker("Address mode", selection: config.addressMode) {
                    ForEach(addressModes, id: \.self) { Text(humanizedName($0)).tag($0) }
                }
                if config.wrappedValue.addressMode == .static {
                    TextField("IP address", text: ipBinding(config.ipv4Config.ip))
                    TextField("Gateway", text: ipBinding(config.ipv4Config.gateway))
                    TextField("Subnet mask", text: ipBinding(config.ipv4Config.subnet))
                    TextField("DNS server", text: ipBinding(config.ipv4Config.dns))
                }
                Toggle("Enable IPv6", isOn: config.ipv6Enabled)
            }

            Section("Services") {
                TextField("NTP server", text: config.ntpServer, prompt: Text("meshtastic.pool.ntp.org"))
                FieldNote("Where the radio gets the time when it has network but no GPS.")
                TextField("Syslog server", text: config.rsyslogServer)
                FieldNote("Optional. Sends the device log to a syslog collector on your network.")
                NetworkProtocolsEditor(protocols: config.enabledProtocols)
            }
        }
    }

    private var addressModes: [Config.NetworkConfig.AddressMode] {
        Config.NetworkConfig.AddressMode.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }

    /// The firmware stores addresses as little-endian 32-bit integers.
    private func ipBinding(_ value: Binding<UInt32>) -> Binding<String> {
        Binding {
            let raw = value.wrappedValue
            guard raw != 0 else { return "" }
            return "\(raw & 0xFF).\((raw >> 8) & 0xFF).\((raw >> 16) & 0xFF).\((raw >> 24) & 0xFF)"
        } set: { text in
            let parts = text.split(separator: ".").compactMap { UInt32($0) }
            guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else {
                if text.isEmpty { value.wrappedValue = 0 }
                return
            }
            value.wrappedValue = parts[0] | (parts[1] << 8) | (parts[2] << 16) | (parts[3] << 24)
        }
    }
}

private struct NetworkProtocolsEditor: View {
    @Binding var protocols: UInt32

    var body: some View {
        Toggle("UDP broadcast over the local network", isOn: Binding(
            get: { protocols & 1 != 0 },
            set: { protocols = $0 ? protocols | 1 : protocols & ~1 }
        ))
        FieldNote("Lets nodes on the same WiFi network exchange mesh traffic directly, without using LoRa airtime.")
    }
}

// MARK: - Display

struct DisplayConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Display",
                        subtitle: "The screen on the device itself",
                        current: session.displayConfig,
                        save: { await session.saveDisplayConfig($0) }) { config in
            Section("Screen") {
                IntervalPicker(title: "Screen stays on for", seconds: config.screenOnSecs,
                               offLabel: "Default (1 minute)",
                               options: [10, 30, 60, 120, 300, 600, 3600])
                IntervalPicker(title: "Auto-advance pages every", seconds: config.autoScreenCarouselSecs,
                               offLabel: "Off", options: [5, 10, 15, 30, 60])
                Toggle("Wake on tap or motion", isOn: config.wakeOnTapOrMotion)
                Toggle("Flip the screen 180°", isOn: config.flipScreen)
                Toggle("Use a 12-hour clock", isOn: config.use12HClock)
                Toggle("Bold headings", isOn: config.headingBold)
                Toggle("Show long node names", isOn: config.useLongNodeName)
                Toggle("Message bubbles", isOn: config.enableMessageBubbles)
            }

            Section("Units and Layout") {
                Picker("Units", selection: config.units) {
                    Text("Metric").tag(Config.DisplayConfig.DisplayUnits.metric)
                    Text("Imperial").tag(Config.DisplayConfig.DisplayUnits.imperial)
                }
                Picker("Display mode", selection: config.displaymode) {
                    ForEach(displayModes, id: \.self) { Text(humanizedName($0)).tag($0) }
                }
                Picker("OLED type", selection: config.oled) {
                    ForEach(oledTypes, id: \.self) { Text(humanizedName($0)).tag($0) }
                }
                FieldNote("Leave the OLED type on automatic unless your screen shows garbage.")
            }

            Section("Compass") {
                Toggle("North is always at the top", isOn: config.compassNorthTop)
                Picker("Compass orientation", selection: config.compassOrientation) {
                    ForEach(compassOrientations, id: \.self) { Text(humanizedName($0)).tag($0) }
                }
            }
        }
    }

    private var displayModes: [Config.DisplayConfig.DisplayMode] {
        Config.DisplayConfig.DisplayMode.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }
    private var oledTypes: [Config.DisplayConfig.OledType] {
        Config.DisplayConfig.OledType.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }
    private var compassOrientations: [Config.DisplayConfig.CompassOrientation] {
        Config.DisplayConfig.CompassOrientation.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }
}

// MARK: - LoRa

struct LoRaConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "LoRa",
                        subtitle: "Radio band, preset, and transmit power",
                        current: session.loraConfig,
                        save: { await session.saveLoRaConfig($0) }) { config in
            Section("Region") {
                Picker("Region", selection: config.region) {
                    ForEach(regions, id: \.self) { Text($0.displayName).tag($0) }
                }
                FieldNote(config.wrappedValue.region == .unset
                    ? "The radio will not transmit until you choose your region. Pick the one matching where you are — the legal frequencies differ."
                    : "This must match the region you are operating in. Transmitting outside your allocated band is illegal.",
                    isWarning: config.wrappedValue.region == .unset)
            }

            Section("Modem Preset") {
                Toggle("Use a standard preset", isOn: config.usePreset)
                FieldNote("Presets keep you compatible with everyone else. Only turn this off if you are deliberately running a private mesh with custom radio parameters.")

                if config.wrappedValue.usePreset {
                    Picker("Preset", selection: config.modemPreset) {
                        ForEach(presets, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    FieldNote(config.wrappedValue.modemPreset.rangeHint)
                    if config.wrappedValue.modemPreset.isWideband {
                        FieldNote("Short Turbo uses 500 kHz of bandwidth, which is not permitted in every region.", isWarning: true)
                    }
                    FieldNote("Everyone on your mesh needs the same preset. Changing it cuts you off from nodes still on the old one.")
                } else {
                    LabeledContent("Bandwidth (kHz)") {
                        TextField("", value: config.bandwidth, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    Stepper("Spreading factor: \(config.wrappedValue.spreadFactor)",
                            value: config.spreadFactor, in: 7...12)
                    Stepper("Coding rate: 4/\(max(5, config.wrappedValue.codingRate))",
                            value: config.codingRate, in: 5...8)
                }
            }

            Section("Frequency") {
                Stepper("Channel number: \(config.wrappedValue.channelNum == 0 ? "automatic" : String(config.wrappedValue.channelNum))",
                        value: config.channelNum, in: 0...200)
                FieldNote("Zero derives the frequency from your primary channel name, which is what keeps a mesh together. Change it only to deliberately separate two meshes in the same area.")
                LabeledContent("Frequency offset (MHz)") {
                    TextField("", value: config.frequencyOffset, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                LabeledContent("Override frequency (MHz)") {
                    TextField("", value: config.overrideFrequency, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                FieldNote("Only for licensed operators working outside the standard band plan.")
            }

            Section("Transmission") {
                Toggle("Transmit enabled", isOn: config.txEnabled)
                FieldNote("Turning this off makes the node listen only. Useful for a monitoring station.",
                          isWarning: !config.wrappedValue.txEnabled)
                Stepper("Transmit power: \(config.wrappedValue.txPower == 0 ? "maximum for region" : "\(config.wrappedValue.txPower) dBm")",
                        value: config.txPower, in: 0...30)
                Stepper("Hop limit: \(config.wrappedValue.hopLimit)", value: config.hopLimit, in: 1...7)
                FieldNote("How many times a packet may be relayed. Three is the default and is right for almost every mesh; higher values flood the network.")
                Toggle("Override the duty cycle limit", isOn: config.overrideDutyCycle)
                FieldNote("Regions such as the EU legally cap how much airtime you may use. Only override this if you are licensed to.",
                          isWarning: config.wrappedValue.overrideDutyCycle)
            }

            Section("Receiver") {
                Toggle("Boosted receive gain (SX126x)", isOn: config.sx126XRxBoostedGain)
                FieldNote("Slightly better sensitivity at the cost of a little more current draw.")
                Toggle("Disable the power amplifier fan", isOn: config.paFanDisabled)
                Picker("Front-end LNA mode", selection: config.femLnaMode) {
                    ForEach(lnaModes, id: \.self) { Text(humanizedName($0)).tag($0) }
                }
            }

            Section("MQTT Interaction") {
                Toggle("Ignore packets that arrived over MQTT", isOn: config.ignoreMqtt)
                Toggle("Allow this node's settings to reach MQTT", isOn: config.configOkToMqtt)
            }
        }
    }

    private var regions: [Config.LoRaConfig.RegionCode] {
        Config.LoRaConfig.RegionCode.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }
    private var presets: [Config.LoRaConfig.ModemPreset] {
        Config.LoRaConfig.ModemPreset.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }
    private var lnaModes: [Config.LoRaConfig.FEM_LNA_Mode] {
        Config.LoRaConfig.FEM_LNA_Mode.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }
}

// MARK: - Bluetooth

struct BluetoothConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Bluetooth",
                        subtitle: "How phones and Macs pair with this radio",
                        current: session.bluetoothConfig,
                        save: { await session.saveBluetoothConfig($0) }) { config in
            Section {
                Toggle("Enable Bluetooth", isOn: config.enabled)
                FieldNote("If you are connected over Bluetooth right now, turning this off ends the connection and you will need USB or the network to turn it back on.",
                          isWarning: !config.wrappedValue.enabled)
            }

            Section("Pairing") {
                Picker("Pairing mode", selection: config.mode) {
                    ForEach(modes, id: \.self) { Text(humanizedName($0)).tag($0) }
                }
                if config.wrappedValue.mode == .fixedPin {
                    LabeledContent("Fixed PIN") {
                        TextField("", value: config.fixedPin, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    FieldNote("Six digits. Devices with no screen ship with 123456.")
                }
                FieldNote("Random PIN shows a fresh code on the device screen each time something pairs. It is the safer choice when the device has a display.")
            }
        }
    }

    private var modes: [Config.BluetoothConfig.PairingMode] {
        Config.BluetoothConfig.PairingMode.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }
}

// MARK: - Security

struct SecurityConfigForm: View {
    @Environment(MeshSession.self) private var session
    @State private var newAdminKey = ""

    var body: some View {
        ConfigFormShell(title: "Security",
                        subtitle: "Keys and remote administration",
                        current: session.securityConfig,
                        save: { await session.saveSecurityConfig($0) }) { config in
            Section("Node Keys") {
                DetailRow("Public Key",
                          config.wrappedValue.publicKey.isEmpty ? "Not set" : config.wrappedValue.publicKey.base64EncodedString(),
                          monospaced: true)
                FieldNote("Other nodes use this key to encrypt direct messages so only this radio can read them. Share it freely.")
                if !config.wrappedValue.publicKey.isEmpty {
                    Button("Copy Public Key") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(config.wrappedValue.publicKey.base64EncodedString(), forType: .string)
                    }
                }
                DetailRow("Private Key", config.wrappedValue.privateKey.isEmpty ? "Not set" : "Stored on the device")
                FieldNote("Never share the private key. If you believe it has leaked, factory reset the device to generate a new pair.")
            }

            Section("Administration Keys") {
                if config.wrappedValue.adminKey.filter({ !$0.isEmpty }).isEmpty {
                    Text("No admin keys set.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(config.wrappedValue.adminKey.enumerated()), id: \.offset) { index, key in
                        if !key.isEmpty {
                            HStack {
                                Text(key.base64EncodedString())
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    var keys = config.wrappedValue.adminKey
                                    keys.remove(at: index)
                                    config.adminKey.wrappedValue = keys
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                HStack {
                    TextField("Public key to authorize", text: $newAdminKey)
                        .font(.system(.body, design: .monospaced))
                    Button("Add") {
                        guard let data = Data(base64Encoded: newAdminKey.trimmingCharacters(in: .whitespaces)),
                              data.count == 32 else { return }
                        var keys = config.wrappedValue.adminKey
                        if keys.count < 3 { keys.append(data) }
                        config.adminKey.wrappedValue = keys
                        newAdminKey = ""
                    }
                    .disabled(Data(base64Encoded: newAdminKey.trimmingCharacters(in: .whitespaces))?.count != 32)
                }
                FieldNote("Up to three keys. A node holding one of these private keys can change this radio's settings remotely. Add your own node's public key before turning on managed mode.")
            }

            Section("Access") {
                Toggle("Managed device", isOn: config.isManaged)
                FieldNote("Refuses local configuration changes. Only an authorized admin key can reconfigure this node.",
                          isWarning: config.wrappedValue.isManaged)
                Toggle("Allow administration over the legacy admin channel", isOn: config.adminChannelEnabled)
                FieldNote("The old, unauthenticated remote admin path. Admin keys are the safer replacement.",
                          isWarning: config.wrappedValue.adminChannelEnabled)
                Toggle("Serial console enabled", isOn: config.serialEnabled)
                Toggle("Debug log over the client API", isOn: config.debugLogApiEnabled)
                FieldNote("Streams the device log to MeshDash's Diagnostics tab.")
            }

            Section("Packet Signing") {
                Picker("Signature policy", selection: config.packetSignaturePolicy) {
                    ForEach(policies, id: \.self) { Text(humanizedName($0)).tag($0) }
                }
                FieldNote("Signed packets let receivers prove who sent a broadcast, at the cost of a larger packet.")
            }
        }
    }

    private var policies: [Config.SecurityConfig.PacketSignaturePolicy] {
        Config.SecurityConfig.PacketSignaturePolicy.allCases.filter { if case .UNRECOGNIZED = $0 { false } else { true } }
    }
}
