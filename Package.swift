// swift-tools-version: 5.9
import PackageDescription

// GL-Link extensions (docs/extensions.md), in the open: what an author needs, and what the
// GL-Link apps themselves run.
// - GLLinkExtensionKit, in the apps: `.ext` packages read and checked (`ExtensionPackage`),
//   their signatures (`Signature`), the packed `.glext` form (`ExtensionArchive`), the
//   marketplace's list (`Catalog`), and scripts run in JavaScriptCore (`ScriptExtension`).
// - GLLinkExtensionTesting, for an extension's own tests: fake routers and a fake network to
//   run its real package against.
// - gllink-ext, the author's tool: new, check, run, build, install, publish. It's the same
//   code the app runs, so what it accepts, the app accepts. `swift run gllink-ext help`.
let package = Package(
    name: "GLLinkExtensionKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GLLinkExtensionKit", targets: ["GLLinkExtensionKit"]),
        .library(name: "GLLinkExtensionTesting", targets: ["GLLinkExtensionTesting"]),
        .executable(name: "gllink-ext", targets: ["gllink-ext"]),
    ],
    targets: [
        .target(name: "GLLinkExtensionKit"),
        .target(name: "GLLinkExtensionTesting", dependencies: ["GLLinkExtensionKit"]),
        .executableTarget(name: "gllink-ext", dependencies: ["GLLinkExtensionKit"]),
        .testTarget(name: "GLLinkExtensionKitTests", dependencies: ["GLLinkExtensionKit", "GLLinkExtensionTesting"]),
    ]
)
