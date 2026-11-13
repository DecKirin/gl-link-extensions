import Foundation

/// What `gllink-ext check` says about a package beyond "the app would refuse it": things that
/// run, but that an author would want to know before sharing it.
public struct ExtensionLint: Equatable, Sendable {
    public var warnings: [String] = []

    public init(_ package: ExtensionPackage) {
        let m = package.manifest
        if let data = try? Data(contentsOf: package.url.appendingPathComponent("manifest.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in object.keys.sorted() where !ExtensionManifest.known.contains(key) {
                warnings.append("manifest.json: “\(key)” isn’t a field GL-Link knows; it’s ignored")
            }
            if let permissions = object["permissions"] as? [String: Any] {
                let known: Set = ["routers", "network", "files", "lan", "internet", "listen", "devices", "read",
                                  "control", "notify", "export", "sms"]
                for key in permissions.keys.sorted() where !known.contains(key) {
                    warnings.append("manifest.json: “permissions.\(key)” isn’t a permission; it grants nothing")
                }
            }
        }
        if m.summary.isEmpty {
            warnings.append("manifest.json: no “summary”; it’s the sentence people read before installing")
        }
        for rule in m.permissions.network ?? [] {
            if let r = NetworkRule(rule), r.wildcard, !r.host.contains(".") {
                warnings.append("manifest.json: “\(rule)” reaches every site under .\(r.host); name the hosts it uses")
            }
        }
        if m.kind == .app, let script = try? package.script() {
            let uses: [(call: String, granted: Bool, permission: String)] = [
                ("gllink.routers(", m.permissions.routers != nil, "routers"),
                ("fetch(", m.permissions.network != nil, "network"),
                ("gllink.connect(", m.permissions.network != nil, "network"),
                ("gllink.readFile(", m.permissions.files != nil, "files"),
            ]
            for use in uses where !use.granted && script.contains(use.call) {
                warnings.append("\(m.main): calls \(use.call)…) with no “\(use.permission)” permission in the manifest; the call will fail")
            }
        }
        if m.repo == nil {
            warnings.append("manifest.json: no “repo”; the marketplace lists only extensions with public source on GitHub")
        }
    }
}
