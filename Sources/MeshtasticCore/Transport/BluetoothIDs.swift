import CoreBluetooth

/// GATT identifiers from the firmware's `BluetoothCommon.h`.
public enum MeshtasticBLE {
    public nonisolated(unsafe) static let serviceUUID = CBUUID(string: "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
    public nonisolated(unsafe) static let toRadioUUID = CBUUID(string: "F75C76D2-129E-4DAD-A1DD-7866124401E7")
    public nonisolated(unsafe) static let fromRadioUUID = CBUUID(string: "2C55E69E-4993-11ED-B878-0242AC120002")
    public nonisolated(unsafe) static let fromNumUUID = CBUUID(string: "ED9DA18C-A800-4F66-A670-AA7547E34453")
    public nonisolated(unsafe) static let logRadioUUID = CBUUID(string: "5A3D6E49-06E6-4423-9944-E9DE8CDF9547")
    public nonisolated(unsafe) static let legacyLogRadioUUID = CBUUID(string: "6C6FD238-78FA-436B-AACF-15C5BE1EF2E2")

    public nonisolated(unsafe) static let allCharacteristics = [toRadioUUID, fromRadioUUID, fromNumUUID, logRadioUUID, legacyLogRadioUUID]
}
