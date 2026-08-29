import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

/// Filters the `UNRECOGNIZED` case out of a generated protobuf enum so it never
/// shows up in a picker.
func knownCases<E: SwiftProtobufEnumLike>(_ type: E.Type) -> [E] {
    E.allCases.filter { !String(describing: $0).hasPrefix("UNRECOGNIZED") }
}

/// The generated enums are all `CaseIterable`; this is just a name for that.
protocol SwiftProtobufEnumLike: CaseIterable, Hashable {}

extension ModuleConfig.SerialConfig.Serial_Baud: SwiftProtobufEnumLike {}
extension ModuleConfig.SerialConfig.Serial_Mode: SwiftProtobufEnumLike {}
extension ModuleConfig.AudioConfig.Audio_Baud: SwiftProtobufEnumLike {}
extension ModuleConfig.DetectionSensorConfig.TriggerType: SwiftProtobufEnumLike {}
extension ModuleConfig.CannedMessageConfig.InputEventChar: SwiftProtobufEnumLike {}
extension Team: SwiftProtobufEnumLike {}
extension MemberRole: SwiftProtobufEnumLike {}

// MARK: - MQTT

struct MQTTConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "MQTT",
                        subtitle: "Bridge this mesh to an internet broker",
                        current: session.mqttConfig,
                        save: { value in await session.saveModule { $0.mqtt = value } }) { config in
            Section {
                Toggle("Enable MQTT", isOn: config.enabled)
                FieldNote("MQTT links your local mesh to a broker over the internet, so distant nodes appear as if they were nearby. It needs WiFi or Ethernet, or a phone or Mac acting as a proxy.")
            }

            Section("Broker") {
                TextField("Address", text: config.address, prompt: Text("mqtt.meshtastic.org"))
                TextField("Username", text: config.username)
                SecureField("Password", text: config.password)
                TextField("Root topic", text: config.root, prompt: Text("msh"))
                Toggle("Use TLS", isOn: config.tlsEnabled)
                FieldNote("The public Meshtastic broker accepts the default credentials. A private broker keeps your traffic off the global map.")
            }

            Section("Behaviour") {
                Toggle("Encrypt packets sent to the broker", isOn: config.encryptionEnabled)
                FieldNote("Leave this on. With it off, anyone reading the broker sees your messages in plain text.",
                          isWarning: !config.wrappedValue.encryptionEnabled)
                Toggle("Also publish decoded JSON", isOn: config.jsonEnabled)
                FieldNote("Convenient for home automation, but it publishes your traffic unencrypted regardless of the setting above.",
                          isWarning: config.wrappedValue.jsonEnabled)
                Toggle("Proxy through the connected client", isOn: config.proxyToClientEnabled)
                FieldNote("Sends MQTT traffic through this Mac's internet connection instead of the radio's own WiFi. Useful for a node with no network of its own.")
            }

            Section("Map Reporting") {
                Toggle("Report this node to the public map", isOn: config.mapReportingEnabled)
                FieldNote("Publishes your node's name, position and firmware to meshmap.net. Only turn this on if you are happy for that to be public.",
                          isWarning: config.wrappedValue.mapReportingEnabled)
                if config.wrappedValue.mapReportingEnabled {
                    IntervalPicker(title: "Publish every",
                                   seconds: config.mapReportSettings.publishIntervalSecs,
                                   offLabel: "Default",
                                   options: [3600, 7200, 21600, 43200, 86400])
                    Picker("Position precision", selection: config.mapReportSettings.positionPrecision) {
                        Text("Within about 23 km").tag(UInt32(10))
                        Text("Within about 6 km").tag(UInt32(12))
                        Text("Within about 1.5 km").tag(UInt32(14))
                        Text("Within about 350 m").tag(UInt32(16))
                        Text("Precise").tag(UInt32(32))
                    }
                }
            }
        }
    }
}

// MARK: - Serial

struct SerialConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Serial",
                        subtitle: "Talk to another device over the radio's UART",
                        current: session.serialModuleConfig,
                        save: { value in await session.saveModule { $0.serial = value } }) { config in
            Section {
                Toggle("Enable the serial module", isOn: config.enabled)
                FieldNote("Bridges a hardware serial port to the mesh, so a microcontroller or sensor can send and receive messages.")
            }

            Section("Port") {
                PinField(title: "Receive pin", pin: config.rxd)
                PinField(title: "Transmit pin", pin: config.txd)
                Picker("Baud rate", selection: config.baud) {
                    ForEach(knownCases(ModuleConfig.SerialConfig.Serial_Baud.self), id: \.self) {
                        Text(humanizedName($0)).tag($0)
                    }
                }
                Toggle("Take over the console serial port", isOn: config.overrideConsoleSerialPort)
                FieldNote("This uses the same port MeshDash connects over. Only enable it if you connect by Bluetooth or network.",
                          isWarning: config.wrappedValue.overrideConsoleSerialPort)
            }

            Section("Protocol") {
                Picker("Mode", selection: config.mode) {
                    ForEach(knownCases(ModuleConfig.SerialConfig.Serial_Mode.self), id: \.self) {
                        Text(humanizedName($0)).tag($0)
                    }
                }
                Toggle("Echo received characters", isOn: config.echo)
                IntervalPicker(title: "Send after idle for", seconds: config.timeout,
                               offLabel: "Default", options: [1, 2, 5, 10, 30])
                FieldNote("How long the module waits for more input before packaging what it has and sending it.")
            }
        }
    }
}

// MARK: - External notification

struct ExternalNotificationConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "External Notification",
                        subtitle: "Drive an LED, buzzer, or vibration motor",
                        current: session.externalNotificationConfig,
                        save: { value in await session.saveModule { $0.externalNotification = value } }) { config in
            Section {
                Toggle("Enable external notifications", isOn: config.enabled)
                FieldNote("Flashes a light or sounds a buzzer when a message arrives, so you notice without looking at the screen.")
            }

            Section("Outputs") {
                PinField(title: "LED pin", pin: config.output)
                PinField(title: "Vibration motor pin", pin: config.outputVibra)
                PinField(title: "Buzzer pin", pin: config.outputBuzzer)
                Toggle("Active high", isOn: config.active)
                FieldNote("Turn this on if your LED or buzzer is wired to trigger on a high signal rather than a low one.")
                Toggle("Use PWM for the buzzer", isOn: config.usePwm)
                Toggle("Use the I²S output as the buzzer", isOn: config.useI2SAsBuzzer)
            }

            Section("Triggers") {
                Toggle("Any message", isOn: config.alertMessage)
                Toggle("Any message — vibrate", isOn: config.alertMessageVibra)
                Toggle("Any message — buzz", isOn: config.alertMessageBuzzer)
                Divider()
                Toggle("Bell character only", isOn: config.alertBell)
                Toggle("Bell character — vibrate", isOn: config.alertBellVibra)
                Toggle("Bell character — buzz", isOn: config.alertBellBuzzer)
                FieldNote("A sender can include a bell character to mark a message urgent. Alerting only on those keeps routine chatter quiet.")
            }

            Section("Timing") {
                LabeledContent("Output duration (ms)") {
                    TextField("", value: config.outputMs, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                IntervalPicker(title: "Keep nagging for", seconds: config.nagTimeout,
                               offLabel: "Do not nag", options: [10, 30, 60, 120, 300])
                FieldNote("Repeats the alert until you press the button or the time runs out.")
            }
        }
    }
}

// MARK: - Store & Forward

struct StoreForwardConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Store & Forward",
                        subtitle: "Replay messages to nodes that were out of range",
                        current: session.storeForwardConfig,
                        save: { value in await session.saveModule { $0.storeForward = value } }) { config in
            Section {
                Toggle("Enable Store & Forward", isOn: config.enabled)
                FieldNote("A server node keeps recent messages and replays them on request, so a node that was out of range catches up when it returns.")
            }

            Section("Server") {
                Toggle("Act as a Store & Forward server", isOn: config.isServer)
                FieldNote("Only ESP32 boards with PSRAM — such as the T-Beam or T3-S3 — have the memory to be a server.",
                          isWarning: config.wrappedValue.isServer)
                Toggle("Send periodic heartbeats", isOn: config.heartbeat)
                FieldNote("Lets clients discover that this server exists.")

                LabeledContent("Messages to keep") {
                    TextField("", value: config.records, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                FieldNote("Zero lets the firmware decide based on available memory.")

                LabeledContent("Maximum messages per reply") {
                    TextField("", value: config.historyReturnMax, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                LabeledContent("History window (minutes)") {
                    TextField("", value: config.historyReturnWindow, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                FieldNote("Replaying a long history uses a lot of airtime. Keep these modest on a busy mesh.")
            }

            Section("Request History") {
                Text("Ask a server for messages you missed from the node's page, or from any conversation's menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Range test

struct RangeTestConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Range Test",
                        subtitle: "Measure how far your radios reach",
                        current: session.rangeTestConfig,
                        save: { value in await session.saveModule { $0.rangeTest = value } }) { config in
            Section {
                Toggle("Enable range test", isOn: config.enabled)
                FieldNote("One node sends numbered packets on a timer while you walk or drive away. Received packets show up in Diagnostics with their signal strength.")
            }

            Section("Sender") {
                IntervalPicker(title: "Send a test packet every", seconds: config.sender,
                               offLabel: "Receive only",
                               options: [10, 15, 30, 60, 120, 300])
                FieldNote("Leave this on \"Receive only\" for the node that stays put. Set an interval on the node you carry.")
                Toggle("Save results to the device filesystem", isOn: config.save)
                Toggle("Clear saved results on reboot", isOn: config.clearOnReboot_p)
            }

            Section {
                FieldNote("Range test packets are unencrypted and use real airtime. Turn the module off again when you are finished testing.",
                          isWarning: config.wrappedValue.enabled)
            }
        }
    }
}

// MARK: - Telemetry

struct TelemetryConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Telemetry",
                        subtitle: "What this node measures and how often it shares it",
                        current: session.telemetryConfig,
                        save: { value in await session.saveModule { $0.telemetry = value } }) { config in
            Section("Device Metrics") {
                Toggle("Share battery and channel usage", isOn: config.deviceTelemetryEnabled)
                IntervalPicker(title: "Send every", seconds: config.deviceUpdateInterval,
                               offLabel: "Default (30 minutes)",
                               options: [900, 1800, 3600, 7200, 21600])
                FieldNote("These are the numbers behind the battery and utilization figures in the node list.")
            }

            Section("Environment Sensors") {
                Toggle("Read environment sensors", isOn: config.environmentMeasurementEnabled)
                FieldNote("Supported I²C sensors — temperature, humidity, pressure and more — are detected automatically at boot.")
                IntervalPicker(title: "Send every", seconds: config.environmentUpdateInterval,
                               offLabel: "Default", options: [300, 900, 1800, 3600, 7200])
                Toggle("Show on the device screen", isOn: config.environmentScreenEnabled)
                Toggle("Display in Fahrenheit", isOn: config.environmentDisplayFahrenheit)
            }

            Section("Air Quality") {
                Toggle("Read air quality sensors", isOn: config.airQualityEnabled)
                IntervalPicker(title: "Send every", seconds: config.airQualityInterval,
                               offLabel: "Default", options: [300, 900, 1800, 3600])
                Toggle("Show on the device screen", isOn: config.airQualityScreenEnabled)
            }

            Section("Power Monitoring") {
                Toggle("Read power sensors", isOn: config.powerMeasurementEnabled)
                IntervalPicker(title: "Send every", seconds: config.powerUpdateInterval,
                               offLabel: "Default", options: [300, 900, 1800, 3600])
                Toggle("Show on the device screen", isOn: config.powerScreenEnabled)
                FieldNote("For INA-series current sensors measuring solar panels or battery banks.")
            }

            Section("Health Sensors") {
                Toggle("Read health sensors", isOn: config.healthMeasurementEnabled)
                IntervalPicker(title: "Send every", seconds: config.healthUpdateInterval,
                               offLabel: "Default", options: [300, 900, 1800, 3600])
                Toggle("Show on the device screen", isOn: config.healthScreenEnabled)
                FieldNote("For heart rate and blood oxygen sensors such as the MAX30102.")
            }
        }
    }
}

// MARK: - Canned messages

struct CannedMessagesForm: View {
    @Environment(MeshSession.self) private var session
    @State private var messagesText = ""
    @State private var loaded = false

    var body: some View {
        ConfigFormShell(title: "Canned Messages",
                        subtitle: "Quick replies you can send from the device itself",
                        current: session.cannedMessageConfig,
                        save: { value in await session.saveModule { $0.cannedMessage = value } }) { config in
            Section {
                Toggle("Enable canned messages", isOn: config.enabled)
                FieldNote("Lets you send a preset reply using the device's buttons or rotary encoder, without a phone.")
            }

            Section("Messages") {
                TextEditor(text: $messagesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                FieldNote("One message per line. The firmware stores them separated by pipes, in at most 200 characters total — \(200 - messagesText.replacingOccurrences(of: "\n", with: "|").utf8.count) left.")
                HStack {
                    Button("Load from Radio") {
                        Task { await session.refreshCannedMessages() }
                    }
                    Button("Save Messages to Radio") {
                        let joined = messagesText
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "|")
                        Task { await session.saveCannedMessages(joined) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                FieldNote("The message list is stored separately from the settings below, so it has its own save button.")
            }

            Section("Input Device") {
                Toggle("Rotary encoder", isOn: config.rotary1Enabled)
                Toggle("Up/down buttons", isOn: config.updown1Enabled)
                if config.wrappedValue.rotary1Enabled || config.wrappedValue.updown1Enabled {
                    PinField(title: "Pin A", pin: config.inputbrokerPinA)
                    PinField(title: "Pin B", pin: config.inputbrokerPinB)
                    PinField(title: "Press pin", pin: config.inputbrokerPinPress)
                    Picker("Clockwise event", selection: config.inputbrokerEventCw) {
                        ForEach(knownCases(ModuleConfig.CannedMessageConfig.InputEventChar.self), id: \.self) {
                            Text(humanizedName($0)).tag($0)
                        }
                    }
                    Picker("Counter-clockwise event", selection: config.inputbrokerEventCcw) {
                        ForEach(knownCases(ModuleConfig.CannedMessageConfig.InputEventChar.self), id: \.self) {
                            Text(humanizedName($0)).tag($0)
                        }
                    }
                    Picker("Press event", selection: config.inputbrokerEventPress) {
                        ForEach(knownCases(ModuleConfig.CannedMessageConfig.InputEventChar.self), id: \.self) {
                            Text(humanizedName($0)).tag($0)
                        }
                    }
                }
                TextField("Allowed input source", text: config.allowInputSource, prompt: Text("_any"))
                Toggle("Include a bell character", isOn: config.sendBell)
                FieldNote("Marks canned messages as urgent so receiving nodes with External Notification will alert.")
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await session.refreshCannedMessages()
        }
        .onChange(of: session.cannedMessages) { _, new in
            guard let new else { return }
            messagesText = new.split(separator: "|").joined(separator: "\n")
        }
    }
}

// MARK: - Audio

struct AudioConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Audio",
                        subtitle: "Codec 2 voice over LoRa",
                        current: session.audioConfig,
                        save: { value in await session.saveModule { $0.audio = value } }) { config in
            Section {
                Toggle("Enable Codec 2 audio", isOn: config.codec2Enabled)
                FieldNote("Sends very low bitrate voice over the mesh. It needs an I²S microphone and speaker wired up, and uses a great deal of airtime.")
            }

            Section("Hardware") {
                PinField(title: "Push-to-talk pin", pin: config.pttPin)
                PinField(title: "I²S word select", pin: config.i2SWs)
                PinField(title: "I²S serial data", pin: config.i2SSd)
                PinField(title: "I²S data in", pin: config.i2SDin)
                PinField(title: "I²S serial clock", pin: config.i2SSck)
            }

            Section("Quality") {
                Picker("Bitrate", selection: config.bitrate) {
                    ForEach(knownCases(ModuleConfig.AudioConfig.Audio_Baud.self), id: \.self) {
                        Text(humanizedName($0)).tag($0)
                    }
                }
                FieldNote("Lower bitrates sound worse but fit in less airtime. Voice needs one of the faster modem presets to work at all.")
            }
        }
    }
}

// MARK: - Remote hardware

struct RemoteHardwareConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Remote Hardware",
                        subtitle: "Read and control GPIO pins over the mesh",
                        current: session.remoteHardwareConfig,
                        save: { value in await session.saveModule { $0.remoteHardware = value } }) { config in
            Section {
                Toggle("Enable remote hardware", isOn: config.enabled)
                FieldNote("Lets another node read or set this device's GPIO pins — a gate opener, a relay, a switch.")
                Toggle("Allow access to undefined pins", isOn: config.allowUndefinedPinAccess)
                FieldNote("With this on, any node on the channel can drive any pin. Leave it off and list only the pins you mean to expose.",
                          isWarning: config.wrappedValue.allowUndefinedPinAccess)
            }

            Section("Available Pins") {
                if config.wrappedValue.availablePins.isEmpty {
                    Text("No pins defined.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(config.wrappedValue.availablePins.enumerated()), id: \.offset) { index, pin in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pin.name.isEmpty ? "Pin \(pin.gpioPin)" : pin.name)
                                Text("GPIO \(pin.gpioPin) · \(humanizedName(pin.type))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                var pins = config.wrappedValue.availablePins
                                pins.remove(at: index)
                                config.availablePins.wrappedValue = pins
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add Pin") {
                    var pins = config.wrappedValue.availablePins
                    guard pins.count < 4 else { return }
                    var pin = RemoteHardwarePin()
                    pin.name = "Pin \(pins.count + 1)"
                    pin.type = .digitalRead
                    pins.append(pin)
                    config.availablePins.wrappedValue = pins
                }
                .disabled(config.wrappedValue.availablePins.count >= 4)
                FieldNote("Up to four pins. Edit the name and number after adding, then save.")
            }
        }
    }
}

// MARK: - Neighbor info

struct NeighborInfoConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Neighbor Info",
                        subtitle: "Share which nodes this radio hears directly",
                        current: session.neighborInfoConfig,
                        save: { value in await session.saveModule { $0.neighborInfo = value } }) { config in
            Section {
                Toggle("Enable neighbor info", isOn: config.enabled)
                FieldNote("Broadcasts the list of nodes this radio hears with no hops in between, which is how you map the real shape of a mesh.")
            }

            Section("Broadcasting") {
                IntervalPicker(title: "Send every", seconds: config.updateInterval,
                               offLabel: "Default (6 hours)",
                               options: [3600, 7200, 21600, 43200, 86400])
                Toggle("Transmit over LoRa", isOn: config.transmitOverLora)
                FieldNote("With this off the node still collects neighbor data for the app, but does not spend airtime broadcasting it. That is the polite setting on a busy mesh.",
                          isWarning: config.wrappedValue.transmitOverLora)
            }
        }
    }
}

// MARK: - Ambient lighting

struct AmbientLightingConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Ambient Lighting",
                        subtitle: "The RGB LED on boards that have one",
                        current: session.ambientLightingConfig,
                        save: { value in await session.saveModule { $0.ambientLighting = value } }) { config in
            Section {
                Toggle("LED on", isOn: config.ledState)
            }

            Section("Colour") {
                ColorPicker("Colour", selection: Binding(
                    get: {
                        Color(red: Double(config.wrappedValue.red) / 255,
                              green: Double(config.wrappedValue.green) / 255,
                              blue: Double(config.wrappedValue.blue) / 255)
                    },
                    set: { color in
                        guard let components = NSColor(color).usingColorSpace(.sRGB) else { return }
                        config.red.wrappedValue = UInt32(components.redComponent * 255)
                        config.green.wrappedValue = UInt32(components.greenComponent * 255)
                        config.blue.wrappedValue = UInt32(components.blueComponent * 255)
                    }
                ))
                Slider(value: Binding(
                    get: { Double(config.wrappedValue.current) },
                    set: { config.current.wrappedValue = UInt32($0) }
                ), in: 0...31) {
                    Text("Brightness")
                }
                FieldNote("Higher brightness draws noticeably more current, which matters on battery.")
            }
        }
    }
}

// MARK: - Detection sensor

struct DetectionSensorConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Detection Sensor",
                        subtitle: "Announce when a pin changes state",
                        current: session.detectionSensorConfig,
                        save: { value in await session.saveModule { $0.detectionSensor = value } }) { config in
            Section {
                Toggle("Enable detection sensor", isOn: config.enabled)
                FieldNote("Watches a GPIO pin and broadcasts a message when it triggers — a door switch, a PIR motion sensor, a water alarm.")
            }

            Section("Sensor") {
                TextField("Name", text: config.name, prompt: Text("Front gate"))
                FieldNote("Appears in the broadcast message, so name it after what it watches.")
                PinField(title: "Monitor pin", pin: config.monitorPin)
                Picker("Trigger on", selection: config.detectionTriggerType) {
                    ForEach(knownCases(ModuleConfig.DetectionSensorConfig.TriggerType.self), id: \.self) {
                        Text(humanizedName($0)).tag($0)
                    }
                }
                Toggle("Use the internal pull-up resistor", isOn: config.usePullup)
                FieldNote("Needed for a simple switch wired between the pin and ground.")
            }

            Section("Broadcasting") {
                IntervalPicker(title: "Minimum time between alerts", seconds: config.minimumBroadcastSecs,
                               offLabel: "Default (45 seconds)",
                               options: [30, 45, 60, 120, 300, 600])
                FieldNote("Stops a flapping sensor from flooding the mesh.")
                IntervalPicker(title: "Send current state every", seconds: config.stateBroadcastSecs,
                               offLabel: "Only on change",
                               options: [300, 900, 1800, 3600])
                Toggle("Include a bell character", isOn: config.sendBell)
                FieldNote("Makes receiving nodes with External Notification alert audibly.")
            }
        }
    }
}

// MARK: - Paxcounter

struct PaxcounterConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Paxcounter",
                        subtitle: "Count nearby WiFi and Bluetooth devices",
                        current: session.paxcounterConfig,
                        save: { value in await session.saveModule { $0.paxcounter = value } }) { config in
            Section {
                Toggle("Enable Paxcounter", isOn: config.enabled)
                FieldNote("Counts distinct WiFi and Bluetooth devices in range as a rough proxy for how many people are nearby. It counts devices, not identities, and does not store the addresses it sees.")
                FieldNote("Paxcounter takes over the ESP32 radio, so Bluetooth and WiFi connections to this node stop working while it is enabled.",
                          isWarning: config.wrappedValue.enabled)
            }

            Section("Reporting") {
                IntervalPicker(title: "Report every", seconds: config.paxcounterUpdateInterval,
                               offLabel: "Default", options: [300, 900, 1800, 3600])
            }

            Section("Sensitivity") {
                LabeledContent("WiFi signal threshold (dBm)") {
                    TextField("", value: config.wifiThreshold, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                LabeledContent("Bluetooth signal threshold (dBm)") {
                    TextField("", value: config.bleThreshold, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                FieldNote("Devices weaker than the threshold are ignored. A value closer to zero, such as −60, counts only devices very close by.")
            }
        }
    }
}

// MARK: - Status message

struct StatusMessageConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Status Message",
                        subtitle: "A short note other nodes see next to your name",
                        current: session.statusMessageConfig,
                        save: { value in await session.saveModule { $0.statusmessage = value } }) { config in
            Section {
                TextField("Status", text: config.nodeStatus, prompt: Text("Solar powered, on the hill"))
                FieldNote("Broadcast with your node information. Keep it short — it shares airtime with everything else.")
            }
        }
    }
}

// MARK: - Traffic management

struct TrafficManagementConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Traffic Management",
                        subtitle: "Suppress redundant traffic on a busy mesh",
                        current: session.trafficManagementConfig,
                        save: { value in await session.saveModule { $0.trafficManagement = value } }) { config in
            Section("Position") {
                IntervalPicker(title: "Minimum interval between positions",
                               seconds: config.positionMinIntervalSecs,
                               offLabel: "Default", options: [30, 60, 300, 900, 1800])
                FieldNote("Drops repeat positions from a node that reports more often than this.")
            }

            Section("Node Info") {
                Stepper("Answer node info directly within \(config.wrappedValue.nodeinfoDirectResponseMaxHops) hop\(config.wrappedValue.nodeinfoDirectResponseMaxHops == 1 ? "" : "s")",
                        value: config.nodeinfoDirectResponseMaxHops, in: 0...7)
                FieldNote("Replies to node info requests from the local cache instead of relaying them further.")
            }

            Section("Rate Limiting") {
                IntervalPicker(title: "Rate limit window", seconds: config.rateLimitWindowSecs,
                               offLabel: "Default", options: [10, 30, 60, 300])
                LabeledContent("Maximum packets per window") {
                    TextField("", value: config.rateLimitMaxPackets, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                LabeledContent("Unknown packet threshold") {
                    TextField("", value: config.unknownPacketThreshold, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                FieldNote("A node exceeding these limits has its packets dropped rather than relayed, which protects the mesh from a misbehaving device.")
            }
        }
    }
}

// MARK: - TAK

struct TAKConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "TAK",
                        subtitle: "Team Awareness Kit integration",
                        current: session.takConfig,
                        save: { value in await session.saveModule { $0.tak = value } }) { config in
            Section {
                Picker("Team", selection: config.team) {
                    ForEach(knownCases(Team.self), id: \.self) { Text(humanizedName($0)).tag($0) }
                }
                Picker("Role", selection: config.role) {
                    ForEach(knownCases(MemberRole.self), id: \.self) { Text(humanizedName($0)).tag($0) }
                }
                FieldNote("Used when this node feeds position and chat into an ATAK client. Set the device role to TAK or TAK Tracker in Device settings as well.")
            }
        }
    }
}

// MARK: - Mesh beacon

struct MeshBeaconConfigForm: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ConfigFormShell(title: "Mesh Beacon",
                        subtitle: "Advertise a channel to nodes not yet on your mesh",
                        current: session.meshBeaconConfig,
                        save: { value in await session.saveModule { $0.meshBeacon = value } }) { config in
            Section("Broadcast") {
                TextField("Message", text: config.broadcastMessage,
                          prompt: Text("Join the valley mesh"))
                IntervalPicker(title: "Broadcast every", seconds: config.broadcastIntervalSecs,
                               offLabel: "Off", options: [900, 1800, 3600, 7200, 21600, 43200])
                FieldNote("Beacons invite nearby radios onto a channel you offer. Because they go out on a well-known channel, anyone in range can see them.")
            }

            Section("Offered Channel") {
                TextField("Channel name", text: config.broadcastOfferChannel.name)
                Picker("Region", selection: config.broadcastOfferRegion) {
                    ForEach(Config.LoRaConfig.RegionCode.allCases.filter({ if case .UNRECOGNIZED = $0 { false } else { true } }), id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Preset", selection: config.broadcastOfferPreset) {
                    ForEach(Config.LoRaConfig.ModemPreset.allCases.filter({ if case .UNRECOGNIZED = $0 { false } else { true } }), id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                FieldNote("These are the settings a joining node will be told to use.")
            }

            Section("Beacon Channel") {
                TextField("Channel name", text: config.broadcastOnChannel.name)
                Picker("Region", selection: config.broadcastOnRegion) {
                    ForEach(Config.LoRaConfig.RegionCode.allCases.filter({ if case .UNRECOGNIZED = $0 { false } else { true } }), id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Preset", selection: config.broadcastOnPreset) {
                    ForEach(Config.LoRaConfig.ModemPreset.allCases.filter({ if case .UNRECOGNIZED = $0 { false } else { true } }), id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                FieldNote("Where the invitation itself is sent. This is usually a public default channel so unconfigured radios can hear it.")
            }
        }
    }
}
