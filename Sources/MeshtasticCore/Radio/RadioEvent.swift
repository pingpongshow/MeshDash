import Foundation
import MeshtasticProtobufs

/// Decoded traffic from the radio, in the order it arrived.
public enum RadioEvent: Sendable {
    case status(String)
    case linkUp
    /// The radio finished dumping its config and node database.
    case configComplete
    case myInfo(MyNodeInfo)
    case metadata(DeviceMetadata)
    case nodeInfo(NodeInfo)
    case config(Config)
    case moduleConfig(ModuleConfig)
    case deviceUIConfig(DeviceUIConfig)
    case channel(Channel)
    case packet(MeshPacket)
    case queueStatus(QueueStatus)
    case clientNotification(ClientNotification)
    case fileInfo(FileInfo)
    case mqttProxyMessage(MqttClientProxyMessage)
    case regionPresets(LoRaRegionPresetMap)
    case lockdownStatus(LockdownStatus)
    case xmodem(XModem)
    /// The radio rebooted out from under us; the node database is being re-sent.
    case rebooted
    case deviceLog(String)
    case logRecord(LogRecord)
    case decodeFailure(String)
    case disconnected(TransportError?)
}

public enum RadioConnectionState: Sendable, Equatable {
    case disconnected
    case connecting(String)
    /// Link is up; the radio is streaming its config and node database.
    case syncing(nodesReceived: Int)
    case connected
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .connecting, .syncing: true
        default: false
        }
    }
}
