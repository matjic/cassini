import Foundation

/// BLE / GATT topology for the ring (spec §3.1). UUIDs are functional
/// interoperability facts; only the first 32-bit block varies between the
/// service and its two characteristics.
public enum RingGATT {
    /// Advertised service UUID; scan-filter on this.
    public static let service = "98ED0001-A541-11E4-B6A0-0002A5D5C51B"
    /// Write / write-without-response characteristic.
    public static let write = "98ED0002-A541-11E4-B6A0-0002A5D5C51B"
    /// Notify (+ read) characteristic.
    public static let notify = "98ED0003-A541-11E4-B6A0-0002A5D5C51B"

    /// Pre-pairing advertised name prefix (factory-reset ring: "Oura <serial>").
    public static let unpairedNamePrefix = "Oura "
    /// Post-pairing advertised name.
    public static let pairedName = "Oura Ring 4"
}
