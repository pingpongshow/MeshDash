import Foundation
import MeshtasticCore
import MeshtasticProtobufs
import Observation
import SwiftUI
import UserNotifications

/// Top-level sections in the sidebar.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case messages, nodes, map, telemetry, channels, gateway, configuration, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: "Messages"
        case .nodes: "Nodes"
        case .map: "Map"
        case .telemetry: "Telemetry"
        case .channels: "Channels"
        case .gateway: "Gateway"
        case .configuration: "Configuration"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbolName: String {
        switch self {
        case .messages: "bubble.left.and.bubble.right"
        case .nodes: "point.3.filled.connected.trianglepath.dotted"
        case .map: "map"
        case .telemetry: "chart.xyaxis.line"
        case .channels: "number"
        case .gateway: "server.rack"
        case .configuration: "slider.horizontal.3"
        case .diagnostics: "stethoscope"
        }
    }
}

/// App-wide state: the live session plus everything the UI needs that is not
/// part of the mesh itself (discovery, selection, preferences).
@MainActor
@Observable
final class AppModel {
    let session: MeshSession
    let bluetoothScanner = BluetoothScanner()
    let networkScanner = NetworkScanner()

    var sidebarSelection: SidebarSection? = .messages
    var selectedConversation: ConversationKey?
    var selectedNode: UInt32?
    var isShowingConnectSheet = false
    /// Set when the store could not be opened; the app still runs, without history.
    var storeFailure: String?

    // Preferences, mirrored into UserDefaults.
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    var reconnectOnLaunch: Bool {
        didSet { UserDefaults.standard.set(reconnectOnLaunch, forKey: "reconnectOnLaunch") }
    }
    var useMetricUnits: Bool {
        didSet { UserDefaults.standard.set(useMetricUnits, forKey: "useMetricUnits") }
    }
    var historyRetentionDays: Int {
        didSet {
            UserDefaults.standard.set(historyRetentionDays, forKey: "historyRetentionDays")
            session.historyRetentionDays = historyRetentionDays
        }
    }

    private var notificationsAuthorized = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "notificationsEnabled": true,
            "reconnectOnLaunch": true,
            "useMetricUnits": true,
            "historyRetentionDays": 90,
        ])
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        reconnectOnLaunch = defaults.bool(forKey: "reconnectOnLaunch")
        useMetricUnits = defaults.bool(forKey: "useMetricUnits")
        historyRetentionDays = defaults.integer(forKey: "historyRetentionDays")

        // A broken database must not stop the app from talking to a radio, so
        // fall back to an in-memory store and tell the user.
        var failure: String?
        var store: MeshStore?
        do {
            store = try MeshStore(fileURL: try MeshStore.defaultURL())
        } catch {
            failure = error.localizedDescription
        }
        if store == nil {
            // Fall back to a scratch database so the app still runs, then to an
            // unlinked temporary file if even that location is unwritable.
            let scratch = FileManager.default.temporaryDirectory
                .appending(path: "MeshDash-\(ProcessInfo.processInfo.processIdentifier).sqlite")
            store = try? MeshStore(fileURL: scratch)
        }
        guard let store else {
            // SQLite cannot open anything at all on this system; there is no
            // sensible way to continue.
            fatalError("MeshDash could not open a database: \(failure ?? "unknown error")")
        }
        self.session = MeshSession(store: store)
        self.storeFailure = failure
        self.session.historyRetentionDays = historyRetentionDays

        session.onIncomingMessage = { [weak self] message, sender in
            self?.postNotification(for: message, from: sender)
        }
    }

    // MARK: - Startup

    func start() async {
        bluetoothScanner.start()
        networkScanner.start()
        await requestNotificationAuthorization()

        if reconnectOnLaunch {
            let known = await session.knownDevices()
            if let last = known.first {
                await session.connect(to: last)
            } else {
                isShowingConnectSheet = true
            }
        } else {
            isShowingConnectSheet = true
        }
    }

    /// Everything discovery has turned up, deduplicated and grouped.
    func discoveredDevices(for kind: TransportKind) -> [DiscoveredDevice] {
        switch kind {
        case .bluetooth: bluetoothScanner.devices
        case .tcp: networkScanner.devices
        case .serial: SerialPortScanner.discoveredDevices()
        // Meshpoint gateways do not advertise themselves, so they are only ever
        // the ones the user has added by address.
        case .meshpoint: []
        }
    }

    func connect(to device: DiscoveredDevice) async {
        isShowingConnectSheet = false
        await session.connect(to: device)
    }

    // MARK: - Notifications

    private func requestNotificationAuthorization() async {
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        notificationsAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private func postNotification(for message: MeshMessage, from sender: MeshNode?) {
        guard notificationsEnabled, notificationsAuthorized else { return }
        // Muted nodes and muted channels should stay quiet.
        if sender?.isMuted == true { return }
        if case .channel(let index) = message.conversation,
           index < session.channels.count,
           session.channels[index].settings.hasModuleSettings,
           session.channels[index].settings.moduleSettings.isMuted {
            return
        }

        let content = UNMutableNotificationContent()
        switch message.conversation {
        case .channel(let index):
            content.title = session.channelName(index)
            content.subtitle = sender?.longName ?? session.name(of: message.fromNode)
        case .direct:
            content.title = sender?.longName ?? session.name(of: message.fromNode)
        }
        content.body = message.text
        content.sound = .default

        let request = UNNotificationRequest(identifier: String(message.id), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
