import Foundation
import MeshtasticProtobufs

/// Which node an admin command targets.
public struct AdminTarget: Sendable, Hashable {
    /// The node number to address.
    public var nodeNum: UInt32
    /// True when this is the radio we are physically connected to, which does
    /// not require a session passkey.
    public var isLocal: Bool
    public var channelIndex: Int

    public init(nodeNum: UInt32, isLocal: Bool, channelIndex: Int = 0) {
        self.nodeNum = nodeNum
        self.isLocal = isLocal
        self.channelIndex = channelIndex
    }
}

public enum AdminError: Error, LocalizedError {
    case passkeyRequired(UInt32)

    public var errorDescription: String? {
        switch self {
        case .passkeyRequired:
            "This node has not issued an admin session yet. Read one of its settings first to start a session."
        }
    }
}

public extension MeshRadio {

    /// Sends an admin message, attaching the session passkey when the target is
    /// a remote node.
    @discardableResult
    func sendAdmin(_ message: AdminMessage,
                   to target: AdminTarget,
                   wantResponse: Bool,
                   requiresSession: Bool = false) async throws -> UInt32 {
        var message = message
        if !target.isLocal {
            if let passkey = passkey(for: target.nodeNum) {
                message.sessionPasskey = passkey
            } else if requiresSession {
                throw AdminError.passkeyRequired(target.nodeNum)
            }
        }

        var data = DataMessage()
        data.portnum = .adminApp
        data.payload = try message.serializedData()
        data.wantResponse = wantResponse
        // Admin traffic must outrank chatter so config changes land promptly.
        return try await send(data,
                              options: SendOptions(destination: target.nodeNum,
                                                   channelIndex: target.channelIndex,
                                                   wantAck: true,
                                                   priority: .reliable))
    }

    private func admin(_ build: (inout AdminMessage) -> Void) -> AdminMessage {
        var message = AdminMessage()
        build(&message)
        return message
    }

    // MARK: - Reading settings

    @discardableResult
    func requestConfig(_ type: AdminMessage.ConfigType, from target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.getConfigRequest = type }, to: target, wantResponse: true)
    }

    @discardableResult
    func requestModuleConfig(_ type: AdminMessage.ModuleConfigType, from target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.getModuleConfigRequest = type }, to: target, wantResponse: true)
    }

    @discardableResult
    func requestOwner(from target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.getOwnerRequest = true }, to: target, wantResponse: true)
    }

    @discardableResult
    func requestChannel(index: Int, from target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.getChannelRequest = UInt32(index + 1) }, to: target, wantResponse: true)
    }

    @discardableResult
    func requestDeviceMetadata(from target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.getDeviceMetadataRequest = true }, to: target, wantResponse: true)
    }

    @discardableResult
    func requestConnectionStatus(from target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.getDeviceConnectionStatusRequest = true }, to: target, wantResponse: true)
    }

    @discardableResult
    func requestCannedMessages(from target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.getCannedMessageModuleMessagesRequest = true }, to: target, wantResponse: true)
    }

    @discardableResult
    func requestRingtone(from target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.getRingtoneRequest = true }, to: target, wantResponse: true)
    }

    @discardableResult
    func requestRemoteHardwarePins(from target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.getNodeRemoteHardwarePinsRequest = true }, to: target, wantResponse: true)
    }

    @discardableResult
    func requestUIConfig(from target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.getUiConfigRequest = true }, to: target, wantResponse: true)
    }

    // MARK: - Writing settings

    /// The firmware batches writes between begin/commit so it reboots once
    /// instead of after every field.
    func beginEditSettings(on target: AdminTarget) async throws {
        try await sendAdmin(admin { $0.beginEditSettings = true }, to: target, wantResponse: false)
    }

    func commitEditSettings(on target: AdminTarget) async throws {
        try await sendAdmin(admin { $0.commitEditSettings = true }, to: target, wantResponse: false)
    }

    @discardableResult
    func setConfig(_ config: Config, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.setConfig = config }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func setModuleConfig(_ config: ModuleConfig, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.setModuleConfig = config }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func setOwner(_ user: User, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.setOwner = user }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func setChannel(_ channel: Channel, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.setChannel = channel }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func setCannedMessages(_ messages: String, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.setCannedMessageModuleMessages = messages }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func setRingtone(_ ringtone: String, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.setRingtoneMessage = ringtone }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func setFixedPosition(_ position: Position, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.setFixedPosition = position }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func removeFixedPosition(on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.removeFixedPosition = true }, to: target, wantResponse: false, requiresSession: true)
    }

    /// Pushes the Mac's clock to the radio, which is how a GPS-less node learns the time.
    @discardableResult
    func setTime(_ date: Date = Date(), on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.setTimeOnly = UInt32(date.timeIntervalSince1970) }, to: target, wantResponse: false)
    }

    @discardableResult
    func setHamMode(_ parameters: HamParameters, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.setHamMode = parameters }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func storeUIConfig(_ config: DeviceUIConfig, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.storeUiConfig = config }, to: target, wantResponse: false)
    }

    // MARK: - Node database management

    @discardableResult
    func setFavorite(_ node: UInt32, isFavorite: Bool, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin {
            if isFavorite { $0.setFavoriteNode = node } else { $0.removeFavoriteNode = node }
        }, to: target, wantResponse: false)
    }

    @discardableResult
    func setIgnored(_ node: UInt32, isIgnored: Bool, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin {
            if isIgnored { $0.setIgnoredNode = node } else { $0.removeIgnoredNode = node }
        }, to: target, wantResponse: false)
    }

    @discardableResult
    func toggleMuted(_ node: UInt32, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.toggleMutedNode = node }, to: target, wantResponse: false)
    }

    @discardableResult
    func removeNode(_ node: UInt32, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.removeByNodenum = node }, to: target, wantResponse: false)
    }

    @discardableResult
    func addContact(_ contact: SharedContact, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.addContact = contact }, to: target, wantResponse: false)
    }

    // MARK: - Device lifecycle

    @discardableResult
    func reboot(afterSeconds seconds: Int32 = 5, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.rebootSeconds = seconds }, to: target, wantResponse: false)
    }

    @discardableResult
    func rebootToOTA(afterSeconds seconds: Int32 = 5, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.rebootOtaSeconds = seconds }, to: target, wantResponse: false)
    }

    @discardableResult
    func shutdown(afterSeconds seconds: Int32 = 5, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.shutdownSeconds = seconds }, to: target, wantResponse: false)
    }

    /// Wipes settings but keeps the node database.
    @discardableResult
    func factoryResetConfig(on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.factoryResetConfig = 1 }, to: target, wantResponse: false, requiresSession: true)
    }

    /// Wipes settings *and* the BLE bond and node database.
    @discardableResult
    func factoryResetDevice(on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.factoryResetDevice = 1 }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func resetNodeDatabase(on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.nodedbReset = true }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func enterDFUMode(on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.enterDfuModeRequest = true }, to: target, wantResponse: false, requiresSession: true)
    }

    // MARK: - Preference backups

    @discardableResult
    func backupPreferences(to location: AdminMessage.BackupLocation, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.backupPreferences = location }, to: target, wantResponse: false)
    }

    @discardableResult
    func restorePreferences(from location: AdminMessage.BackupLocation, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.restorePreferences = location }, to: target, wantResponse: false, requiresSession: true)
    }

    @discardableResult
    func removeBackupPreferences(at location: AdminMessage.BackupLocation, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.removeBackupPreferences = location }, to: target, wantResponse: false, requiresSession: true)
    }

    // MARK: - Remote input

    /// Drives the device's own UI, so a headless node can be navigated remotely.
    @discardableResult
    func sendInputEvent(_ event: AdminMessage.InputEvent, on target: AdminTarget) async throws -> UInt32 {
        try await sendAdmin(admin { $0.sendInputEvent = event }, to: target, wantResponse: false)
    }
}
