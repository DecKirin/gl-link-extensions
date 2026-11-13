# GL-Link extensions

Everything for writing and sharing extensions for GL-Link, the iPhone and Mac app for GL.iNet
routers: the SDK, the guide, GL-Link's own extensions, and the marketplace's list.

An extension is a `.ext` package: a manifest and a JavaScript script that GL-Link runs, held
to the permissions its manifest asks for. It can read the routers GL-Link is paired with and
hand them to other software: another app on the device, a web service, a menu bar.

## Start

```sh
git clone https://github.com/DecKirin/gl-link-extensions
cd gl-link-extensions
swift run gllink-ext new Hello        # Hello.ext: a manifest, a script, types for your editor
swift run gllink-ext run Hello.ext    # runs it here, against sample routers; no app needed
swift run gllink-ext install Hello.ext  # opens it in GL-Link on this Mac
```

A Mac with Xcode's command line tools is needed: `gllink-ext` runs scripts in JavaScriptCore,
as the app does. `just install` puts `gllink-ext` in `/usr/local/bin`.

Then read [`docs/writing-extensions.md`](docs/writing-extensions.md).

## What's here

| | |
|---|---|
| [`docs/writing-extensions.md`](docs/writing-extensions.md) | The guide: the package, the manifest, permissions, the script API, testing, signing, sharing |
| [`docs/extensions.md`](docs/extensions.md) | The design: the two kinds of extension, trust, the marketplace, and the router side's protocol |
| [`extensions/`](extensions) | `Hello.ext`, the smallest whole extension, to read and to start from |
| `Sources/GLLinkExtensionTesting` | For your extension's own tests: fake routers and a fake network to run its real package against |
| [`gl-link-glassybattery`](https://github.com/DecKirin/gl-link-glassybattery) | A whole extension in a repository of its own, as yours would be: tests, signing, releases, its marketplace entry |
| `Sources/gllink-ext` | The tool: `new`, `check`, `run`, `keygen`, `build`, `verify`, `install`, `publish` |
| `Sources/GLLinkExtensionKit` | What the tool and the GL-Link apps both run: reading and checking packages, signatures, the packed `.glext` form, the script runtime, the marketplace's list |
| [`MARKETPLACE.md`](MARKETPLACE.md), `entries/`, `index.json` | The marketplace: its rules, one entry per shared extension, and the signed list the app reads |

## Sharing one

Sign it with your own key, release it in your own public GitHub repository, and send its
entry here:

```sh
gllink-ext keygen
gllink-ext publish Thing.ext     # then a pull request adding com.you.thing.json to entries/
```

The rules, and what GL-Link checks on the device, are in [`MARKETPLACE.md`](MARKETPLACE.md).

## Working on this repository

```sh
swift test          # the kit, and GL-Link's own extensions run in the real runtime
just check          # the tests, and gllink-ext check on every extension and entry
```

The GL-Link apps build `GLLinkExtensionKit` from this repository, so a change to the runtime
or to what a package may be is a change to the apps.
