# Writing an extension

How to write a GL-Link extension: the package, the manifest, the script API, permissions,
testing and shipping. Why extensions are shaped this way is in
[`extensions.md`](extensions.md).

- [Pick a kind](#pick-a-kind)
- [The tool: gllink-ext](#the-tool-gllink-ext)
- [Quick start: an app extension in five minutes](#quick-start-an-app-extension-in-five-minutes)
- [The package](#the-package)
- [The manifest](#the-manifest)
- [Permissions](#permissions)
- [The script API](#the-script-api)
- [What the person sees](#what-the-person-sees)
- [Testing](#testing)
- [Shipping and updating](#shipping-and-updating)
- [A worked example: GlassyBattery](#a-worked-example-glassybattery)
- [Router extensions](#router-extensions)
- [Before you share one](#before-you-share-one)

## Pick a kind

| If it must… | Write a | Status |
|---|---|---|
| Keep working with no phone or Mac around; talk to devices on the router's network or USB; feed Home Assistant or Prometheus; show the same thing on every paired device | **Router extension** | Designed, not yet runnable ([below](#router-extensions)) |
| Hand GL-Link's routers to another app on this device; react to something only this device knows | **App extension** | Built: iPhone, iPad and Mac |

An app extension runs only while GL-Link runs on that device, and only that device has it. A
router extension runs on the router all the time, and every device paired with the router
shows it. When in doubt, ask "should my other devices see this too?". If yes, it's a router
extension.

## The tool: gllink-ext

`gllink-ext` makes, checks, runs, signs and shares extensions. It's built from the same code
as the app, so what it accepts, the app accepts.

- **From this repository:** `swift run gllink-ext <command>` (or `just ext <command>`).
  `just install` puts it in `/usr/local/bin`.
- **A Mac is needed:** it runs scripts in JavaScriptCore, as the app does.

| Command | Does |
|---|---|
| `new <Name>` | A new `Name.ext` that already runs: manifest, script, `gllink.d.ts` for your editor |
| `check <package>` | What GL-Link would refuse, and warnings: a misspelt field, a call the manifest gives no permission for, `*.com` |
| `run <Name.ext>` | Runs the script here in GL-Link's own runtime, against sample routers (or `--routers file.json`). Prints its status, rows, actions and log as they change; `a <id>` taps an action, `r` sends `routers` again, `q` quits. Its network and files are real, held to the manifest |
| `keygen` · `key` | Makes your publisher key (`~/.gllink-ext/key`); shows its public half and fingerprint |
| `build <Name.ext>` | Signs a copy and packs it: `Name-1.0.0.glext`. Your folder isn't changed |
| `verify <package>` | Whether it's whole, and who signed it |
| `install <package>` | Opens it in GL-Link on this Mac, which asks before installing |
| `publish <Name.ext>` | Builds it, attaches it to a release of your GitHub repository, and writes its marketplace entry |

A package is a `Name.ext` folder or a `.glext` file; `.` works inside the folder.

## Quick start: an app extension in five minutes

`gllink-ext new Hello` writes all of this, and `gllink-ext run Hello.ext` runs it without the
app. By hand:

`extensions/Hello.ext` in this repository is the smallest whole extension. It shows each
router's battery under its name in Settings, with a button that reads the routers again.

**1. Make the package:** a folder whose name ends in `.ext`.

```
Hello.ext/
  manifest.json
  main.js
```

**2. `manifest.json`:**

```json
{
  "id": "com.deckirin.gllink.hello",
  "kind": "app",
  "name": "Hello",
  "version": "1.0.0",
  "summary": "Each router’s battery, under its name in Settings: the smallest whole extension.",
  "symbol": "hand.wave.fill",
  "platforms": ["ios", "macos"],
  "host_api": 1,
  "main": "main.js",
  "permissions": {
    "routers": ["battery"]
  }
}
```

**3. `main.js`:**

```js
"use strict";

function show() {
  const routers = gllink.routers().filter((r) => r.battery);
  gllink.show(
    routers.map((r) => ({
      title: r.name,
      value: `${r.battery.level}%${r.battery.charging ? " ⚡︎" : ""}`,
    })),
  );
  gllink.status(
    routers.length === 0 ? "No router with a battery is answering."
      : routers.length === 1 ? "Watching 1 battery."
      : `Watching ${routers.length} batteries.`,
  );
}

gllink.actions([{ id: "read", title: "Read Now" }]);

gllink.on("action", async (id) => {
  if (id !== "read") return;
  gllink.status("Reading…");
  await gllink.refresh();
  show();
});

gllink.on("routers", show);

show();
```

**4. Install it:**
- **Mac:** `gllink-ext install Hello.ext`; or double-click `Hello.ext` in Finder; or use
  Settings → App Extensions → Add from a File.
- **iPhone or iPad:** `gllink-ext build Hello.ext --unsigned` (or signed, once you have a
  key), send `Hello-1.0.0.glext` to the device by AirDrop or Files, and open it with
  GL-Link. This path is built but not yet tried on a device.

GL-Link shows what the extension can do ("Read your routers' names and batteries"), says
it isn't signed, and asks first.

**5. See it:** Settings → This Mac (or This iPhone) → App Extensions. Hello is switched on,
says "Watching 1 battery.", lists each router's battery, and has a Read Now button.

**6. Change it:** edit, raise `version`, and open the package again. GL-Link offers an update
and keeps its switch as it was.

## The package

A `.ext` is a folder that Finder and Files show as one file (GL-Link declares the type
`com.deckirin.gllink.extension`).

```
Name.ext/
  manifest.json        required
  main.js              an app extension's script (the manifest's "main")
  anything else        resources: the script reads them with gllink.resource
```

- **To send one, pack it:** `gllink-ext build Name.ext` makes `Name-1.0.0.glext`, one file
  (a zip of the folder's files) that GL-Link opens on the iPhone and the Mac. A zip made by
  Finder's Compress or `zip -r`, renamed to `.glext`, is read too.
- **What a package may hold:** ordinary files, up to 16 MB and 2,000 of them, named with
  letters, digits, spaces and `._@+-`. No links. Dot files (`.git`, `.DS_Store`) are left
  out of the signature, the `.glext` and the installed copy, so they can sit in your folder.
- **`signature.json`** is written by `gllink-ext build` into the packed copy. Don't write or
  commit one yourself.
- **Installing copies it in.** The copy lives in GL-Link's own storage
  (`Application Support/Extensions/<id>.ext`). Changing the original afterwards does nothing
  until it's opened again.
- **If a Mac shows a `.ext` as a plain folder:** Launch Services hasn't registered GL-Link's
  type yet, for example right after a development build. Run
  `lsregister -f /Applications/GLLink.app`, using the `lsregister` in
  `/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/`.

## The manifest

`manifest.json`, at the root of the package.

| Field | Kind | Required | What |
|---|---|:-:|---|
| `id` | both | ● | Reverse DNS in lowercase, such as `com.example.thing`. It never changes: it's how an update finds the installed copy, and where its secrets are kept |
| `kind` | both | | `"app"` or `"router"`. Left out, it's `app` |
| `name` | both | ● | 1–40 characters, shown in Settings |
| `version` | both | ● | Numbers with dots, one to four of them: `1.2.0`. Compared number by number (1.10 is after 1.9), to tell an update; shown in the update question ("from 1.0.0 to 1.1.0") |
| `author` | both | | Who wrote it, as you'd like to be named. The marketplace shows it; left out, it's your GitHub name |
| `repo` | both | | Its public source: `https://github.com/you/repo`. Needed to share it in the marketplace |
| `summary` | both | | One sentence, shown under it in Settings |
| `symbol` | both | | An SF Symbol for its icon in Settings. Default `puzzlepiece.extension.fill` |
| `host_api` | both | ● | The extension API it was written for: `1`. A newer number than the app knows is refused ("needs a newer GL-Link") |
| `platforms` | app | ● | `["ios"]`, `["macos"]` or both. `ios` covers iPhone and iPad |
| `main` | app | | Its script, a `.js` file inside the package. Default `main.js` |
| `requires.router` | app | | Router extensions it reads from, by id: `{"router": ["com.example.starlink"]}`. Shown under Details |
| `exec` | router | ● | Its program's file name, in `bin/<target>/` |
| `memory_mb` | router | | Its memory limit. Default 32 |
| `config` | router | | A settings form the apps draw ([`extensions.md`](extensions.md#config-and-secrets)) |
| `permissions` | both | | What it may reach ([below](#permissions)). Left out: nothing |

A manifest that's wrong is refused when the package is opened, with the reason: "“id” must be
reverse DNS in lowercase…", "“main” must be a .js file inside the package".

## Permissions

An extension reaches only what its manifest names. The person sees each permission in words
before installing, and again when an update asks for more.

### App extensions

| Permission | Lets it | Shown as |
|---|---|---|
| `routers: ["battery", "model"]` | `gllink.routers()`, `gllink.refresh()` and the `routers` event. Names and ids come with either | "Read your routers' names, batteries and models" |
| `network: ["127.0.0.1", "192.168.8.1:9443", "*.example.com"]` | `fetch` and `gllink.connect` to those hosts: any port without one, that port with one, any subdomain with `*.`. http, https, ws and wss only | "Connect to other apps on this device (127.0.0.1)", "Connect to *.example.com" |
| `files: ["~/Library/…/file.json"]` | `gllink.readFile` of exactly those files, `~` being the person's home folder. On the Mac, GL-Link's sandbox must allow the file too: today only GlassyBattery's `bridge.json` | "Read ~/Library/…/file.json" |

**Needs no permission:**
- its own secrets;
- its own package's files (`gllink.resource`);
- its status, rows and actions.

**Not on offer to an app extension:**
- texts, settings, and changing the routers;
- other apps' files;
- anything else on the device.

### Router extensions

`lan`, `internet`, `listen`, `devices`, `read`, `control`, `notify`, `export` and `sms`; see
[`extensions.md`](extensions.md#permissions). The app already reads and words them ("Connect
to 192.168.100.1:9200 on the router's network", "See everything GL-Link knows").

## The script API

### The environment

- **JavaScriptCore.** Modern JavaScript: `async`/`await`, classes, `Map`, `Set`, `JSON`,
  template strings. Use `"use strict"`.
- **Not a browser, not Node:** no DOM, `window`, `require`, `process`, `localStorage`, `btoa`
  or `TextEncoder`. For binary data use `gllink.resource(path, "base64")`.
- **One script, one context.**
  - **On:** the top level runs once when the extension is turned on, and when the app starts
    with it on.
  - **Off or removed:** the context is dropped whole, with its timers and sockets. Nothing
    survives except its secrets.
- **The app's main thread.** Calls return quickly and work happens in promises. Don't spin in
  loops; use timers.
- **Errors.** A thrown error, or a rejected promise in an event handler, goes to its log.

### Calls

**`gllink.routers()`** → array. Needs `routers`. Each router:

```js
{
  id: "6F1C…",               // GL-Link's id for the router on this device
  name: "Mudi 7",            // as the person named it
  updated: 1794510732000,    // ms since 1970 when it last answered, or null
  battery: { level: 85, charging: true },   // with "battery", on routers with one
  model: { id: "e5800", code: "GL-E5800", name: "Mudi 7",
           symbol: "router.e5800" },         // with "model"; symbol may be null
}
```

Sample-data routers are never included.

**`gllink.on(event, fn)`:** call `fn` on:

| Event | When | `fn` gets |
|---|---|---|
| `"routers"` | What it can see of the routers changed: a level, a name, one added or removed, or just a router answering (`updated`). That can be every few seconds while the app is connected, so compare before doing anything costly. Only with the `routers` permission | nothing |
| `"action"` | One of its actions was tapped, and confirmed if it asks | the action's `id` |
| `"stop"` | It's being turned off or removed; close what you opened | nothing |

**`gllink.refresh()`** → promise. Reads every router again. On the Mac with the window closed
the app stops reading routers by itself, so an extension that sends readings elsewhere should
refresh when they get old (GlassyBattery does past 90 s).

**`gllink.status(text)`:** the line under its name in Settings. Keep it a short sentence about
now ("Showing Mudi 7 in GlassyBattery.", "Waiting for you to approve GL-Link in
GlassyBattery."). Up to 200 characters.

**`gllink.show([{title, value}])`:** rows under it in Settings, up to 20. Replaces the last
ones.

**`gllink.actions([{id, title, role?, confirm?}])`:** buttons under it, up to 8. Replaces the
last ones.
- `role: "destructive"` draws one in red.
- `confirm` is a sentence asked before it runs: say what will happen ("Your routers leave
  GlassyBattery for a moment, then come back.").
- Titles are short verbs in title case: "Reset Connection", "Read Now".

**`gllink.secrets.get(key)`** → string or null. **`gllink.secrets.set(key, value)`:** `null`
removes the secret. Kept in the Keychain, one item per extension, and deleted when it's
removed. Use them for tokens other apps give it.

**`gllink.resource(path, encoding?)`** → string or null. A file inside its own package, up to
1 MB: as text, or base64 with `"base64"`. Paths outside the package give null.

**`gllink.readFile(path)`** → string or null. A file named in `files`.

**`fetch(url, {method, headers, body})`** → promise of `{status, ok, text(), json()}`.
- **Hosts:** only those in `network`. Any other host rejects, and is logged.
- **Redirects** to a host in `network` are followed. To any other host they aren't: you get
  the 3xx answer itself.
- **Bodies:** text only (send JSON as a string), and responses are read as text.
- **Timeout:** 10 seconds.
- **No response headers.**

**`gllink.connect(url)`** → a socket. A WebSocket to a host in `network`:
- `socket.send(text)` → promise;
- `socket.close()`;
- `socket.onmessage = (e) => e.data`, text frames;
- `socket.onclose = (e) => e.reason`.

A socket to a host it may not reach closes at once. Each closes when the extension stops.

**`setTimeout`, `setInterval`, `clearTimeout`, `clearInterval`:** as usual.
**`console.log`, `.info`, `.warn`, `.error`:** to its log.

**`gllink.app`** → `{platform: "macos" | "ios", bundleID, version}`.

### Patterns

- **Start from `show()`, call it on `routers`.** Draw from the current state each time rather
  than patching what was drawn.
- **Reconnect with backoff.** A server can go away: try again after 2 s, doubling to a minute.
  Give each socket its own handlers that check it's still the current one, so a socket
  closed on purpose can't tear down its replacement (see GlassyBattery's `connect`).
- **Respect "no".** When another app blocks or removes yours, stop and say so in the status.
  Offer an action to try again, rather than retrying on your own.

## What the person sees

Settings → App Extensions shows, for each extension:
- its icon, name and status line, with its switch;
- the rows it shows, then its actions;
- under **Details**: its version, its kind, where it runs, what it needs on the router, what
  it can do, and the last 12 lines of its log;
- **Remove…**.

**Writing for it:** GL-Link's own copy is plain and short, and says what's true now. Prefer
"Showing Mudi 7 in GlassyBattery." to "Connected successfully!".

## Testing

**With the tool:** `gllink-ext run Name.ext` runs the script in the app's runtime, with no app
and no router: its status, rows, actions and log print as they change.

```
$ gllink-ext run Hello.ext
status   Watching 1 battery.
row      Mudi 7: 85% ⚡︎
action   read: Read Now
a read
status   Reading…
```

`--routers routers.json` gives it other routers:
`[{"name": "Mudi 7", "battery": {"level": 12, "charging": false}, "model": {"id": "e5800", "code": "GL-E5800", "name": "Mudi 7", "symbol": "router.e5800"}}]`.
It really connects to what its manifest allows: run GlassyBattery's that way and a sample
router shows up in GlassyBattery until you quit.

**In the app:** the Log under Details shows what it printed and every error, including a
`fetch` or `connect` refused for want of a permission.

**Automated:** run the package's own script with the real runtime and fake routers and
network, in this repository's tests (`swift test`).
- `ScriptExtension(package:context:network:)` runs a package.
- `FakeContext` supplies the routers and keeps the secrets.
- `FakeNetwork` answers `fetch` and hands out sockets that record what's sent and answer from
  a closure.
- `HelloTests` runs the quick start above.
- `GlassyBatteryTests` runs GlassyBattery against a fake BatteryBridge: registering, icons,
  updates, Reset Connection.

```swift
let ext = ScriptExtension(package: try ExtensionPackage(at: url), context: context, network: fake)
ext.start()
XCTAssertEqual(ext.status, "Watching 1 battery.")
ext.perform(ext.actions.first { $0.id == "read" }!)
```

## Shipping and updating

- **Keep `id`.** A new `id` is a different extension: its settings and secrets don't follow.
- **Raise `version`** with every change people will install. The update question shows both
  versions.
- **Updating** replaces the package and keeps its switch, and the extension restarts on the
  new script.
- **More permissions** are shown again, before the update, marked "(new)".

### Signing

```sh
gllink-ext keygen          # once. ~/.gllink-ext/key; the public half is printed
gllink-ext build Thing.ext # Thing-1.0.0.glext, signed
```

- **Your key is you, to GL-Link.** People who install a signed extension only ever get its
  updates from the same key. Back the key up; never commit or share it. Whoever has it can
  publish as you, and without it you can't update what you've shared: people would have to
  remove your extension and install it again.
- **In CI,** put the key's text in `GLLINK_EXT_KEY`; `--key <file>` names another file.
- **Signing changes nothing about what it can do.** It says who the package is from, and
  that no file was changed since. Unsigned packages install too, with a plain warning, which
  is how you run your own while writing it.

### Sharing it in the marketplace

The marketplace is a list in a public repository
([`DecKirin/gl-link-extensions`](https://github.com/DecKirin/gl-link-extensions)); the app
shows it under Settings → App Extensions → Browse Extensions. It holds no code: each entry
points at a release in the extension's own repository. Its rules are in
[`extensions.md`](extensions.md#the-marketplace).

1. **Put the source in a public GitHub repository,** and name it in the manifest:
   `"repo": "https://github.com/you/your-repo"`.
2. **`gllink-ext publish Thing.ext`:** signs and packs it, makes the release `Thing-1.0.0`
   in your repository with `Thing-1.0.0.glext` attached (through GitHub's `gh`), and writes
   `com.you.thing.json`, its entry. `--dry-run` stops before the release.
3. **Open a pull request** on the marketplace's repository adding that file to `entries/`.
   Its check downloads your release as anyone would, and compares the file's SHA-256, its
   signature and its manifest with the entry.
4. **Merged,** it's in the list: people Get it, and see who it's by and where its source is.

**To update:** raise `version`, `gllink-ext publish` again, and send the new entry. Installed
copies show "Update to 1.1.0".

GL-Link's own are in `extensions/` in this repository; `just build` packs them.

## A worked example: GlassyBattery

`extensions/GlassyBattery.ext` puts each router with a battery in
[GlassyBattery](https://github.com/DecKirin/AirBattery), a Mac menu bar app, through its
BatteryBridge API. Its parts, in `main.js`:

| Part | What it shows |
|---|---|
| `findServer` | Reads where the other app listens from a file it names in `files`, then checks its health with `fetch` |
| `signIn` | Registers once, keeping the token in `gllink.secrets` |
| `connect` | One WebSocket, with handlers bound to that socket; reconnects with backoff |
| `uploadIcons` | Reads `icons/router.<id>.svg` from its own package with `gllink.resource(…, "base64")` and uploads each |
| `devices`, `push` | Turns `gllink.routers()` into the other app's devices; sends only what changed, and everything every 2 minutes |
| `reset` | Its **Reset Connection** action: forget the token, sign in again |
| `gllink.on("stop")` | Closes the stream, which takes the routers out of GlassyBattery at once |

Its icons are made from GL-Link's router symbols by `just ext-icons`.

## Router extensions

**Status:** designed; gllinkd doesn't run them yet. What exists today:
- **The manifest:** `"kind": "router"`, with `exec` and router permissions. The app reads it,
  words its permissions, and refuses to install it in the app.
- **Each router's settings page** lists the router's extensions from `GET /v1/ext`. Every
  paired device shows the same list. Today's gllinkd answers 404, shown as "Not on This
  Router Yet".

What one will be:
- **A program:** native, built for both router CPUs (`aarch64-unknown-linux-musl`,
  `armv7-unknown-linux-musleabihf`) and placed in `bin/<target>/<exec>`.
- **How it runs:** gllinkd starts it as its own user, and they talk JSON-RPC 2.0 over stdin
  and stdout, one message per line.
- **What it publishes:** devices and entities, the readings and controls, and cards. Every
  app draws those natively, on every device paired with the router.

The protocol, the entity and card models, permissions and their enforcement, and the Rust
crate (`gllink-ext`) are specified in [`extensions.md`](extensions.md#router-extensions-running-on-the-router).
Write against that spec. Until gllinkd's host is built, `gllinkd ext dev` is not there to run
one.

## Before you share one

- [ ] `gllink-ext check` says OK, with no warnings you don't mean.
- [ ] `id` is yours, in reverse DNS, and won't change.
- [ ] `permissions` names only what it uses: a host, not `*.com`; the file, not a folder.
- [ ] Its status line says what's true now, and every disruptive action has `confirm`.
- [ ] It closes what it opened on `stop`, and reconnects with backoff, not in a loop.
- [ ] It stops when another app says no, and offers an action to try again.
- [ ] A test runs it against a fake of whatever it talks to.
- [ ] It's signed with your key, which is backed up; `repo` names its public source.
