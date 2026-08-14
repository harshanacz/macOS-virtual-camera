import Foundation

/// Identifiers shared between `Fuzzcam.app` and `FuzzcamExtension`.
///
/// These are compile-time constants on purpose: the app has to locate the
/// extension's device in the Core Media I/O HAL without any handshake, and the
/// extension has to publish a device the app will recognise. A stable UUID is
/// the contract between them.
public enum FuzzcamIdentifiers {

    /// Bundle identifier of the camera system extension.
    public static let extensionBundleID = "com.harshanacz.Fuzzcam.Extension"

    /// App Group container shared by both targets.
    ///
    /// On macOS an App Group used by a sandboxed process must be prefixed with
    /// the team identifier, so this must stay in sync with `DEVELOPMENT_TEAM`
    /// and with both `.entitlements` files.
    public static let appGroupID = "C37NWJLS6S.com.harshanacz.Fuzzcam"

    /// Darwin notification posted by the app after it writes new configuration.
    /// Darwin notifications cross the sandbox boundary; the payload itself
    /// travels through the App Group defaults.
    public static let configChangedNotification = "com.harshanacz.Fuzzcam.configChanged"

    /// Stable `CMIOExtensionDevice` identifier. The app matches on this to find
    /// its own virtual camera among every device in the HAL.
    public static let deviceUUID = UUID(uuidString: "1C7B7D6E-2A4F-4C63-9E1B-6F2A8D5C0A31")!

    /// Stable identifier of the `.source` stream (what other apps capture).
    public static let sourceStreamUUID = UUID(uuidString: "2D8C8E7F-3B50-4D74-AF2C-703B9E6D1B42")!

    /// Stable identifier of the `.sink` stream (what Fuzzcam.app writes into).
    public static let sinkStreamUUID = UUID(uuidString: "3E9D9F80-4C61-4E85-B03D-814CAF7E2C53")!
}
