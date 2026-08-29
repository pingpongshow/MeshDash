import Foundation
import IOKit
import IOKit.serial

/// Enumerates USB serial devices via the IORegistry so we can show real product
/// names ("Heltec V3") instead of raw `/dev/cu.usbserial-0001` paths.
public enum SerialPortScanner {
    public struct Port: Sendable, Hashable {
        public var path: String
        public var productName: String?
        public var vendorName: String?
        public var vendorID: Int?
        public var productID: Int?
        public var serialNumber: String?

        /// Best-effort human label for the port.
        public var displayName: String {
            if let productName, !productName.isEmpty { return productName }
            if let vendorName, !vendorName.isEmpty { return vendorName }
            return (path as NSString).lastPathComponent
        }

        /// USB bridges that show up on Meshtastic hardware. Used to sort likely
        /// radios to the top rather than to exclude anything.
        public var looksLikeRadio: Bool {
            guard let vendorID else { return false }
            return SerialPortScanner.knownVendorIDs.contains(vendorID)
        }
    }

    /// Silicon Labs CP210x, WCH CH340/CH9102, FTDI, Espressif native USB,
    /// Nordic/Adafruit nRF52, RaspberryPi RP2040 — the bridges used across the
    /// Meshtastic hardware lineup.
    static let knownVendorIDs: Set<Int> = [0x10C4, 0x1A86, 0x0403, 0x303A, 0x239A, 0x2E8A, 0x1915, 0x2886, 0x2341]

    public static func scan() -> [Port] {
        var ports: [Port] = []
        var iterator: io_iterator_t = 0

        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary? else { return [] }
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = string(service, kIOCalloutDeviceKey) else { continue }
            // Skip the always-present Bluetooth serial stubs, which are never radios.
            if path.contains("Bluetooth-Incoming") || path.contains("debug-console") { continue }

            var port = Port(path: path)
            port.productName = searchParents(service, key: "USB Product Name") ?? searchParents(service, key: "Product Name")
            port.vendorName = searchParents(service, key: "USB Vendor Name")
            port.serialNumber = searchParents(service, key: "USB Serial Number")
            port.vendorID = searchParentsInt(service, key: "idVendor")
            port.productID = searchParentsInt(service, key: "idProduct")
            ports.append(port)
        }

        return ports.sorted { lhs, rhs in
            if lhs.looksLikeRadio != rhs.looksLikeRadio { return lhs.looksLikeRadio }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    public static func discoveredDevices() -> [DiscoveredDevice] {
        scan().map { port in
            var detail = (port.path as NSString).lastPathComponent
            if let vendor = port.vendorName, !vendor.isEmpty { detail = "\(vendor) · \(detail)" }
            return DiscoveredDevice(address: .serial(path: port.path), name: port.displayName, detail: detail)
        }
    }

    // MARK: - IORegistry helpers

    private static func string(_ service: io_object_t, _ key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return raw.takeRetainedValue() as? String
    }

    /// Serial port nodes do not carry USB metadata themselves; it lives on an
    /// ancestor, so walk up the tree until we find it.
    private static func searchParents(_ service: io_object_t, key: String) -> String? {
        var current = service
        var depth = 0
        var owned = false
        while depth < 12 {
            if let value = string(current, key) {
                if owned { IOObjectRelease(current) }
                return value
            }
            var parent: io_object_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if owned { IOObjectRelease(current) }
            guard status == KERN_SUCCESS else { return nil }
            current = parent
            owned = true
            depth += 1
        }
        if owned { IOObjectRelease(current) }
        return nil
    }

    private static func searchParentsInt(_ service: io_object_t, key: String) -> Int? {
        var current = service
        var depth = 0
        var owned = false
        while depth < 12 {
            if let raw = IORegistryEntryCreateCFProperty(current, key as CFString, kCFAllocatorDefault, 0),
               let number = raw.takeRetainedValue() as? NSNumber {
                if owned { IOObjectRelease(current) }
                return number.intValue
            }
            var parent: io_object_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if owned { IOObjectRelease(current) }
            guard status == KERN_SUCCESS else { return nil }
            current = parent
            owned = true
            depth += 1
        }
        if owned { IOObjectRelease(current) }
        return nil
    }
}
