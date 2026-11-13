import Foundation

/// What the app gives an extension: the routers, and secrets of its own. The runtime
/// (`ScriptExtension`) hands a script only the parts its manifest asks for.
@MainActor
public protocol ExtensionContext: AnyObject {
    /// The paired routers, sample data's left out.
    var routers: [RouterInfo] { get }
    /// Reads every router again, as a pull to refresh does. For when the app's own reading
    /// has stopped, as on the Mac with the window closed.
    func refresh() async
    /// The extension's secrets (tokens other apps gave it), kept in the Keychain.
    func loadSecrets() -> [String: String]
    func saveSecrets(_ secrets: [String: String])
}

/// A paired router, as an extension sees it.
public struct RouterInfo: Identifiable, Sendable, Equatable {
    /// The app's own id for the router; stays the same while it's paired.
    public var id: UUID
    /// The name the person gave it, e.g. "Mudi 7".
    public var name: String
    /// Nil until the router has answered once.
    public var model: RouterModel?
    /// Nil on routers without a battery, and until it's read.
    public var battery: BatteryReading?
    /// When the router last answered.
    public var updated: Date?

    public init(id: UUID, name: String, model: RouterModel?, battery: BatteryReading?, updated: Date?) {
        self.id = id
        self.name = name
        self.model = model
        self.battery = battery
        self.updated = updated
    }
}

public struct RouterModel: Sendable, Equatable {
    /// GL's firmware ID, e.g. "e5800".
    public var id: String
    /// e.g. "GL-E5800".
    public var code: String
    /// e.g. "Mudi 7".
    public var name: String
    /// The model's own symbol in GL-Link ("router.e5800"), drawn from GL's picture of it;
    /// nil for models without one.
    public var symbol: String?

    public init(id: String, code: String, name: String, symbol: String?) {
        self.id = id
        self.code = code
        self.name = name
        self.symbol = symbol
    }
}

public struct BatteryReading: Sendable, Equatable {
    /// 0–100.
    public var level: Int
    public var charging: Bool

    public init(level: Int, charging: Bool) {
        self.level = level
        self.charging = charging
    }
}
