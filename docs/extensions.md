# Extensions

Extensions add to GL-Link what GL-Link doesn't do by itself:

- **Device integrations:** read and control the things around the router, such as a Starlink
  dish, a smart plug, a solar charge controller on USB, or a GPS puck.
- **Exporters:** carry GL-Link's information to other software, such as Home Assistant,
  Prometheus, a webhook, Shortcuts or GlassyBattery.

This is the design: why extensions are shaped as they are, and how they work inside. To write
one, see [`writing-extensions.md`](writing-extensions.md).

**Status (2026-11-13):**
- **Sharing is built:** a packed single-file form (`.glext`), publisher signatures, the
  author's tool (`gllink-ext`) and the marketplace's list, with Browse Extensions in the
  apps ([Trust](#trust-who-its-from), [The marketplace](#the-marketplace),
  [The SDK](#the-sdk)). Checked by tests and by the tool on this Mac; the marketplace's
  public repository isn't made yet, so the app's list has nothing to read.
- **App extensions are built.** The iPhone and Mac apps install, run, turn off and remove
  `.ext` packages. Tried on the Mac; on iOS the pages are checked in the simulator, and
  installing from Files is not yet tried on a device. The first one, **GlassyBattery** for the Mac, is built and verified
  ([below](#the-first-app-extension-glassybattery)).
- **Router extensions are designed, not built.** Each router's settings page asks the router
  for its extensions (`GET /v1/ext`) and, from today's gllinkd, says it doesn't run any yet.
- Facts about the Mudi 7 below were read from the router on fw 4.10.0 (OpenWrt 23.05.4). The
  rest is marked **to check** in [Phase 0](#plan).

## Two kinds

An extension is one of two kinds, by **where its code runs**, and so who sees it:

| | Router extension | App extension |
|---|---|---|
| Runs | On a router, in its own process under gllinkd, all the time | In GL-Link on one iPhone or Mac, while the app runs |
| Who sees it | Every phone and Mac paired with that router | Only the device it's installed on |
| Code | A native program, any language, JSON-RPC over stdin and stdout | JavaScript, in JavaScriptCore |
| Reaches | The router's data and controls, devices on its networks, its USB ports | What the app knows of the routers, and local things: other apps on the device, files it may read |
| Shows on clients | Declared cards and entities, which every app draws natively | Its own section in Settings → App Extensions, and what it hands to other local apps |
| Installed | Once per router, by a device with the `ext:admin` scope | Per device, by opening a `.ext` |
| Permissions enforced by | gllinkd, and a firewall rule per extension user | The app's runtime, on every call |
| Trust bar | High: the router holds the texts and the network | Lower: confined to one app's sandbox |
| Examples | Starlink, smart plugs, a UPS on USB, Home Assistant (MQTT), Prometheus, webhooks | GlassyBattery, a Focus filter, a menu bar meter |

Two rules keep them apart:

1. **A router extension never depends on an app.** It publishes devices, entities and cards,
   and every client draws them. With no app open it keeps collecting, and automations keep
   acting on it.
2. **An app extension never runs on the router or talks to another device.** It reads through
   the router's API, as the app does.

Where they meet: an app extension can read what router extensions publish, through the entity
bus, and say so in `requires`. GlassyBattery exports the routers' own batteries today. Once a
router extension publishes a power bank on the router's USB port as a `battery` entity,
GlassyBattery can export every battery GL-Link knows, with nothing new on the router side.

In the apps the split follows Settings' own:

- **App extensions:** under This Mac or This iPhone → App Extensions.
- **Router extensions:** on each router's page → Router Extensions.

Each page says which kind it lists, and points to the other.

| Extension | Kind | Router | iOS | macOS |
|---|---|:-:|:-:|:-:|
| Starlink: speed, obstruction, stow | router | ● collects, controls | card (declared) | card (declared) |
| Smart plugs (Shelly, Tasmota) on the router's Wi-Fi | router | ● | card (declared) | card (declared) |
| Victron solar or battery over USB serial | router | ● | card (declared) | card (declared) |
| Home Assistant (MQTT, with discovery) | router | ● exports | — | — |
| Prometheus `/metrics` · webhook on events | router | ● exports | — | — |
| **GlassyBattery**: router batteries in another Mac app (built) | app | — | — | ● |
| Sleep Focus turns the router's Wi-Fi off | app | — | ● | — |
| Data left in the menu bar, per SIM | app | — | — | ● |

"Card (declared)": the router extension describes the card as data, and the app draws it. No
iOS or macOS code is needed.

## Decisions

1. **Two kinds, kept separate** ([above](#two-kinds)). One package holding both halves would
   hide that the router half affects every device and the app half one. A pair that belongs
   together shares an id and says so with `requires`.
2. **Router extensions carry what must always run.** The router is always on, and it's on the
   same network as the dish, the plug and the USB port. An iPhone app can't run in the
   background.
3. **One data model for everything: devices and their entities.** An entity is a reading, a
   switch, a choice, a number or a button. The router's own data is published the same way,
   by a built-in provider. Cards, exporters, Shortcuts and, later, automations then work for
   every extension without knowing it exists. An exporter written once exports a dish it has
   never heard of.
4. **Router extensions' cards are data, not code.** One declares a card, the entities it shows
   and a detail page. The iPhone and the Mac draw it natively in Overview's own style, in the
   unfolded Duo's columns and the Mac's menu bar panel too.
5. **A router extension is its own process, in any language.** It talks to gllinkd over stdin
   and stdout with JSON-RPC. A crash takes down the extension, never the daemon. That's the
   shape of LSP and MCP: easy to write, easy to test on a laptop.
6. **An app extension is a script, not compiled in.** iOS runs no native code the app wasn't
   signed with. JavaScriptCore runs on both platforms, and the script sees only `gllink`.
7. **Permissions are declared, shown, and enforced.** The manifest lists what an extension may
   reach. The app shows the list before install. The host of each kind checks every call
   against it.

## Anatomy

```
 ┌──────────────────────────── router ───────────────────────────────┐
 │  gllinkd                                                          │
 │  ┌──────────────┐  JSON-RPC   ┌───────────────────────────────┐   │       ┌─────────────┐
 │  │ ext host     │◀──stdio────▶│ router extension (own process,│───┼─LAN──▶│ the dish    │
 │  │  supervisor  │             │ own user, any language)       │   │       └─────────────┘
 │  │  entity bus ◀┼── router provider (battery, SIMs, Wi-Fi …)    │   │
 │  │  history     │             └───────────────────────────────┘   │
 │  │  cards       │──▶ exporter router extensions (MQTT, Prometheus) ┼──▶ Home Assistant …
 │  └──────┬───────┘                                                 │
 │         │ /v1/ext/* + ext.* events (the API apps already use)     │
 └─────────┼─────────────────────────────────────────────────────────┘
           │ LAN · home network · tailnet
   ┌───────┴────────┐
   ▼                ▼
 iPhone app       Mac app
  declared cards    declared cards        ← every router extension, on every device
  app extensions    app extensions        ← .ext scripts, this device only
  Shortcuts         Shortcuts, menu bar      (GlassyBattery → GlassyBattery's BatteryBridge)
```

### The manifest

Both kinds are `.ext` packages with a `manifest.json`; `kind` says which. The full reference is
in [`writing-extensions.md`](writing-extensions.md#the-manifest).

```json
{
  "id": "com.example.starlink",
  "kind": "router",
  "name": "Starlink",
  "version": "1.2.0",
  "summary": "Your dish's speed and obstructions, and stow, from the router it feeds.",
  "symbol": "dot.radiowaves.up.forward",
  "host_api": 1,
  "exec": "starlink",
  "memory_mb": 24,
  "permissions": { "lan": ["192.168.100.1:9200"], "read": ["wan"], "notify": true },
  "config": [{ "key": "stow_on_battery", "type": "bool", "title": "Stow When the Router Is on Battery", "default": false }]
}
```

- **`exec`:** `bin/<target>/starlink`, picked by the router's CPU.
- **`memory_mb`:** its limit; the default is 32.
- **`config`:** a settings form the apps draw.

An app extension names `platforms` and `main` (its script) in place of `exec`, and can name the
router extensions it reads from: `"requires": {"router": ["com.example.starlink"]}`.

## The data model

Shared by every part. It's defined once, in `gllink-core` (`ext` module), and mirrored in
`GLLinkKit`. JSON fixtures in `fixtures/ext/` are decoded by both test suites, so the two can't
drift.

### Devices and entities

A **device** is a thing an extension talks to: `{id, name, model?, maker?, symbol?, via:
lan|usb|ble|cloud|router}`. A device can appear and disappear while the extension runs, for
example a plug found on the LAN.

An **entity** is one fact or one control on a device. Its full name is
`<extension>/<device>/<entity>`, for example `com.example.starlink/dish/downlink`. Within its
own extension it's just `dish/downlink`.

| Kind | Value | Can be changed | Examples |
|---|---|:-:|---|
| `sensor` | number or text | — | Download speed, temperature, "Connected" |
| `binary` | true / false | — | Obstructed, plugged in, motion |
| `switch` | true / false | ● `set` | A plug, the dish's heater |
| `select` | one of `options` | ● `set` | Power-save mode: off / overnight / always |
| `number` | number in `min…max` by `step` | ● `set` | A charge limit |
| `button` | none | ● `press` | Reboot the dish, stow it |

Every entity has `name`, an `available` flag and `updated` (when its value was last set).
These fields are optional:

- **`unit`:** one of a fixed list (`%`, `°C`, `W`, `V`, `A`, `Wh`, `bit/s`, `B`, `dBm`, `dB`,
  `s`, `ms`). The apps format it with `Measurement`: 182000000 bit/s shows as "182 Mbit/s".
  Any other unit is shown as written.
- **`class`:** what kind of fact it is (`battery`, `power`, `energy`, `temperature`,
  `signal`, `data_rate`, `data`, `duration`, `connectivity`, `problem`). Cards and exporters
  use it. Home Assistant's `device_class` is mapped from it.
- **`min` and `max`:** let a sensor fill a meter card.
- **`precision`:** how many decimals to show.
- **`history: true`:** keep this entity's readings for charts (see [History](#storage-and-history)).
- **`confirm`:** a sentence the apps ask before a `set` or `press`, such as "Stow the dish?
  It stops the internet until it's back up."
- **`attrs`:** any small JSON, passed along to exporters as it is.

A declaration:

```json
{"id": "dish/downlink", "kind": "sensor", "name": "Download", "unit": "bit/s",
 "class": "data_rate", "precision": 0, "history": true}
```

### The router's own entities

A built-in provider, `router`, publishes what gllinkd already collects. It maps `Live` to
entities whenever a collector reports. The typed API the app uses today stays as it is.

| Entity | Kind | From |
|---|---|---|
| `router/battery/level`, `…/charging`, `…/temp` | sensor, binary, sensor | battery collector |
| `router/sim1/signal`, `…/operator`, `…/used`, `…/limit`, `…/active` | sensor…, binary | cellular collector (one device per slot) |
| `router/internet/online`, `…/source` | binary, sensor | uplinks |
| `router/wifi/on`, `router/wifi/uplink_ssid`, `…/uplink_signal` | switch, sensor, sensor | wifi collector; `set` goes through `wifi::set_power` |
| `router/system/cpu`, `…/memory`, `…/clients`, `…/uptime` | sensor | system collector |
| `router/sms/unread` | sensor | the store. Only the count: texts never go on the bus |

A `set` on a router entity goes through the same handler as the app's own call. To the
automation engine it is "someone else changing a held part", and the automation pauses as it
would for a person.

## Router extensions: running on the router

### Running

- **One process per extension:** started by gllinkd, which reads its stdout as protocol and
  keeps its stderr as the extension's log (the last 200 lines, in memory). Extensions are
  restarted with gllinkd.
- **Its own user:** `glx-<n>`, a uid from 7100 up, made at install, never root. **To check:**
  where `/etc/passwd` entries go on GL firmware, and that a firmware upgrade keeps them.
  `/etc/gl-link/` is kept: it's in `/etc/sysupgrade.conf`.
- **Limits:**
  - **Memory:** a cgroup with `memory.max` from `memory_mb`. **To check:** the cgroup2 mount
    on fw 4.10. Fallback: `RLIMIT_AS`.
  - **CPU:** `nice 10`.
  - **Extra isolation:** `ujail` (present on the Mudi) where it works with a static binary: a
    read-only view of the filesystem, plus its own directory.
- **Crashes:** restarted after 1 s, doubling to 5 min. After 5 crashes in 10 minutes it's
  stopped, and the apps show "Stopped: it kept quitting" with its log.
- **Liveness:** gllinkd pings every 30 s. No answer within 10 s counts as a crash.

### The protocol

JSON-RPC 2.0, one message per line on stdin and stdout.

**From gllinkd to the extension:**

| Message | Kind | What |
|---|---|---|
| `initialize {host_api, router: {model, caps, firmware, name}, config, permissions}` | request | First message. Replied to with `{name, version}` |
| `entity.set {entity, value}` · `entity.press {entity}` | request | From an app, Shortcuts, an exporter or an automation. Reply within 10 s, `{}` or an error whose `message` the app shows |
| `config.changed {config}` | notification | The settings form was saved |
| `router.event {topic, data}` | notification | Something it subscribed to happened |
| `bus.changed {changes}` | notification | Exporters: entities changed, any extension's included |
| `ping` · `shutdown` | request / notification | Liveness; 5 s to exit before SIGKILL |

**From the extension to gllinkd:**

| Message | Kind | What |
|---|---|---|
| `devices.declare [Device]` · `devices.remove [id]` | notification | Its devices, as found |
| `entities.declare [Entity]` · `entities.remove [id]` | notification | Their entities |
| `state {entity: value, …}` | notification | New values; several at once. Coalesced by gllinkd |
| `available {entity: bool, …}` | notification | A device stopped or started answering |
| `cards.declare [Card]` · `cards.remove [id]` | notification | Its cards ([Cards](#cards)) |
| `alert {title, body, level}` | notification | Needs `notify`. Goes to open apps and through Bark as alerts do. At most 1 a minute |
| `router.get {area}` | request | Needs `read` for that area: `system`, `battery`, `cellular`, `wifi`, `wan`, `clients` |
| `router.subscribe {topics}` | request | Router events of areas it can read |
| `router.set {entity, value}` | request | Needs `control` for that part. Same path as the app's call |
| `bus.subscribe {match}` · `bus.read {match}` | request | Needs `export`. Every entity, with a glob such as `router/sim*/**` |
| `store.get {key}` · `store.set {key, value}` | request | Its own small key–value store, 64 KB |

A first exchange:

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"host_api":1,"router":{"model":"GL-E5800",…},"config":{"stow_on_battery":false},…}}
← {"jsonrpc":"2.0","id":1,"result":{"name":"Starlink","version":"1.2.0"}}
← {"jsonrpc":"2.0","method":"devices.declare","params":[{"id":"dish","name":"Starlink Dish","via":"lan"}]}
← {"jsonrpc":"2.0","method":"entities.declare","params":[{"id":"dish/downlink","kind":"sensor",…},{"id":"dish/stow","kind":"button","confirm":"Stow the dish? …"}]}
← {"jsonrpc":"2.0","method":"state","params":{"dish/downlink":182000000,"dish/obstructed":false}}
→ {"jsonrpc":"2.0","id":7,"method":"entity.press","params":{"entity":"dish/stow"}}
← {"jsonrpc":"2.0","id":7,"result":{}}
```

### Permissions

| Permission | Lets it | Enforced by |
|---|---|---|
| `lan = [host[:port] or CIDR]` | Connect to these on the router's own networks | A rule in gllinkd's own nftables table, matching the extension's uid (`meta skuid`). **To check** on fw4 |
| `internet = [host[:port]]` | Connect to these hosts out on the internet | The same rule, with addresses filled in by dnsmasq-full's `nftset=` as the names resolve. **To check** |
| `listen = port` | Accept connections on `br-lan` only, e.g. a Prometheus scrape | An input rule for that port on the LAN |
| `devices = ["tty:ttyUSB*", "usb:0403:6001"]` | Open these device nodes | Ownership set on hotplug (`/etc/hotplug.d`) |
| `read = [areas]` | Router data through `router.get` and `router.subscribe` | gllinkd |
| `control = [parts]` | Router changes through `router.set` | gllinkd |
| `notify` | Raise alerts | gllinkd, rate-limited |
| `export` | Read every entity of every extension and the router | gllinkd. Shown as "Can see everything GL-Link knows" |
| `sms` | Read texts (`router.get {area: "sms"}`) | gllinkd. Never granted without a separate confirmation |

An extension with none of the network permissions can reach nothing:

- **Loopback:** blocked for its uid. That covers GL's `/rpc` and gllinkd's API.
- **ubus:** **to check** that the ubus socket refuses non-root users.

Extensions talk to the router only through gllinkd, which checks every request.

### Config and secrets

The manifest's `config` fields have a `type`:

- `text`, `secret`, `number`, `bool`, `choice` (with `options`).
- `host`: an address on the LAN, which the app can offer from connected devices.

The apps draw the form natively. Values are kept in `/etc/gl-link/ext/<id>/config.json`.
`secret` fields are sealed with the router key, the way Bark keys are. They are sent to the
extension, never back to an app: the form shows "Set" and a Change button.

### Storage and history

- **Files:**
  - Code: `/etc/gl-link/ext/<id>/`. It's under `/etc/gl-link/`, which firmware upgrades
    keep.
  - Working files: `/tmp/gl-link/ext/<id>/`, in memory.
- **History:** for entities with `history: true`, gllinkd keeps:
  - one reading a minute for 24 hours;
  - one an hour (minimum, mean, maximum) for 30 days.

  Writes are batched every 5 minutes to spare the flash. The apps use it for sparklines and
  charts. It's capped at 20 entities per extension.
- **Updates to the apps:** coalesced to at most one `ext.state` event a second, sent only
  while an app is listening (`has_listeners`), as telemetry is today.

### Cost

A small Rust extension idles at a few MB of memory; gllinkd itself is 11.6 MB. The Mudi has
1.6 GB of RAM and a 2.9 GB overlay with 2.5 GB free. Other GL routers have 512 MB of RAM and
less flash, hence the 32 MB default limit and a 16 MB package limit.

## Cards

A router extension declares its cards, and the apps draw them as they draw their own:
- the same tile, glass, sizes and editing;
- the zoom into a detail page;
- the Duo's columns and the Mac's menu bar panel.

An app extension will be able to declare cards from its script too, through the same card model,
shown on its own device only.

```json
{
  "id": "dish",
  "title": "Starlink",
  "symbol": "dot.radiowaves.up.forward",
  "style": "value",
  "value": "dish/downlink",
  "detail": "dish/state",
  "tint": {"entity": "dish/obstructed", "true": "orange"},
  "page": [
    {"title": "Speed", "rows": ["dish/downlink", "dish/uplink", "dish/latency"]},
    {"title": "Dish", "rows": ["dish/heater", "dish/stow", "dish/reboot"]}
  ],
  "shown": true
}
```

| Style | Shows | Like the app's |
|---|---|---|
| `value` | One entity, large, and a line of detail | Uptime, Firmware |
| `meter` | A sensor with `min` and `max`, filling the card | Battery, CPU, a SIM's data |
| `switch` | A switch entity's state as a word; the switch itself in the page | Router Wi-Fi |
| `state` | A text or binary sensor as a word, tinted | Connection, Internet |
| `chart` | A sparkline of an entity with history | New: none of the app's cards has one yet |

- **Detail page:** opened by a tap, and zooms out of the card. It's built from the
  sections in `page`. Each row is drawn by its entity's kind:
  - a sensor as a value;
  - a switch as a toggle;
  - a select as a picker;
  - a number as a stepper or slider;
  - a button as a button, asking `confirm` first.

  Below the rows the page shows the extension's name, its settings, and "Last updated".
- **Tints:** only `green`, `orange`, `red`, `accent` and `secondary`, so an extension's card
  looks like the rest.
- **Symbols:** SF Symbols by name. An unknown name falls back to `puzzlepiece.extension`.
- **Names:** a card's `CardID` is `<extension id>.<card id>`, for example
  `com.example.starlink.dish`. `CardID` already reserves that form for cards from elsewhere.
  An extension's cards are another `CardSource` (`ExtensionCards`) beside `RouterCards` in
  `RouterCards.pool`. `CardLayout` places, hides and remembers them with no change.
- **Defaults:** cards declared `shown` go at the end of the dashboard on install; the others
  wait in the pool.
- **Offline:** a card whose entities are unavailable shows its last value, dimmed, with
  "Not answering". If the extension stopped, it says so.

## App extensions: `.ext` scripts in the apps

An extension in the apps is a **`.ext` package**: a folder that Finder and Files show as one
file, holding a manifest and a JavaScript script. The app installs it, runs it, turns it off
and removes it while it runs. Nothing is compiled into the app.

- **Why JavaScript:** iOS runs no native code that wasn't in the signed app, and the Mac
  app's sandbox and library validation refuse a plug-in signed by anyone else. JavaScriptCore
  is part of both systems, and it runs a script with no access to anything except what the
  app hands it. One package format then works on the iPhone and the Mac alike.
- **What a script reaches:** nothing directly, not even the network. It has only the
  `gllink` object, and the app checks every call against the manifest.

```
GlassyBattery.ext/
  manifest.json
  main.js
  icons/router.e5800.svg …     resources it reads with gllink.resource
  signature.json               once it's signed: who published it, over every file
```

To travel, the folder is packed into one file, **`GlassyBattery-1.2.0.glext`**: a zip of
those files. A folder can't be downloaded, attached or shared from an iPhone as one thing; a
`.glext` can, and the apps open either.

```json
{
  "id": "com.deckirin.gllink.glassybattery",
  "kind": "app",
  "name": "GlassyBattery",
  "version": "1.2.0",
  "summary": "Shows your routers' batteries in GlassyBattery: its menu bar, widgets and your other Macs.",
  "symbol": "battery.75percent",
  "author": "DecKirin",
  "repo": "https://github.com/DecKirin/gl-link-extensions",
  "platforms": ["macos"],
  "host_api": 1,
  "main": "main.js",
  "permissions": {
    "routers": ["battery", "model"],
    "network": ["127.0.0.1"],
    "files": ["~/Library/Application Support/GlassyBattery/bridge.json"]
  }
}
```

- **`kind`:** `app`. A package without `kind` is an app extension, as every package was
  before kinds were named.
- **`platforms`:** `ios`, `macos`, or both. A package for the other platform installs nowhere
  else, and says which one it's for.
- **`permissions`:** all it can reach.
  - `routers`: what of the routers it reads, `battery` and `model`. Names and ids come with
    either.
  - `network`: the hosts it may reach over HTTP and WebSocket (`127.0.0.1`,
    `192.168.8.1:9443`, `*.example.com`).
  - `files`: the files it may read. On the Mac, the app's sandbox must allow them too.
  - Secrets need no permission: each extension has its own Keychain item.

### What a script can call

| Call | Does |
|---|---|
| `gllink.routers()` | `[{id, name, updated, battery?: {level, charging}, model?: {id, code, name, symbol}}]`, as far as `routers` allows. `symbol` is the model's own symbol in GL-Link, such as `router.e5800`, or null |
| `gllink.on("routers", fn)` · `gllink.on("stop", fn)` | Something about the routers changed; it's being turned off or removed |
| `gllink.refresh()` | A promise: the routers read again |
| `gllink.status(text)` · `gllink.show([{title, value}])` | The line under its name in Settings → App Extensions, and rows under it |
| `gllink.readFile(path)` | A file named in `files`, as text, or null |
| `gllink.resource(path, "base64"?)` | A file inside its own package (up to 1 MB), as text or base64, or null. Nothing outside the package |
| `gllink.actions([{id, title, role?, confirm?}])` · `gllink.on("action", fn)` | Buttons under it in Settings → App Extensions (up to 8). `role: "destructive"` draws one red; `confirm` is asked first. A tap calls `fn(id)` |
| `gllink.secrets.get(key)` · `.set(key, value or null)` | Its own secrets |
| `gllink.connect(url)` | A WebSocket to a host in `network`: `send(text)`, `close()`, `onmessage`, `onclose` |
| `fetch(url, {method, headers, body})` | HTTP to a host in `network`: `{status, ok, text(), json()}` |
| `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval`, `console` | As usual. `console` goes to its log, under Details |
| `gllink.app` | `{platform, bundleID, version}` |

### Installing, turning off, removing

- **Install:**
  - Get one from Settings → App Extensions → Browse Extensions
    ([the marketplace](#the-marketplace)); or open a `.glext` or a `.ext` from Finder, Files
    or a share; or use Add from a File.
  - The app checks the package first: its manifest, its files (no links, nothing outside
    it, 16 MB at most) and its signature. Then it asks, showing what the extension will be
    able to do ("Read your routers' names, batteries and models", "Connect to other apps on
    this device (127.0.0.1)") and who it's from ([Trust](#trust-who-its-from)). On the Mac
    the question is an alert of its own, so it shows whether or not a window is open.
  - Its files are then copied into the app's own storage
    (`Application Support/Extensions/<id>.ext`), checked again there, and it's turned on.
  - Installing a package with an id that's already installed is an update. It keeps its
    switch as it was, and the question marks what it asks for anew: "(new)".
  - **A signed extension is only updated by its own publisher.** The update gets the
    installed one's secrets and its switch, so the same id isn't enough: a package signed
    with another key, or not signed, is refused until the installed one is removed.
- **At launch,** each installed package is read and checked again. One whose files no longer
  match its signature isn't run; the page says so, with Remove.
- **On and off:**
  - A switch in Settings → App Extensions.
  - Off stops the script and drops its whole JavaScript context, with its timers and
    sockets; on starts it fresh.
  - Extensions that are on start with the app.
- **Remove:**
  - A button on its section, with a confirmation.
  - It stops, and its package, its switch and its secrets are deleted.
- **What the page shows:**
  - For each extension: its name, its status line and its rows.
  - Under Details: its version, its platforms, what it can do, and the last of its log.

The type is declared in `project.yml` (`com.deckirin.gllink.extension`, `.ext`, a package)
for both apps. The code:
- This repository's Swift package, `GLLinkExtensionKit`, which the apps build in:
  - `ExtensionPackage` reads and checks a package; `Signature`, who signed it.
  - `ExtensionArchive` packs and unpacks a `.glext`; `Catalog` is the marketplace's list.
  - `ScriptExtension` runs one.
  - `gllink-ext`, the author's tool, is the same package's executable.
  - Tests in `swift test` there, including the real `GlassyBattery.ext` against a fake
    BatteryBridge.
- In the apps (GL-Link's own repository): `ExtensionHost` installs, runs and removes;
  `ExtensionCatalog` reads the marketplace and downloads from it; `ExtensionsView` and
  `ExtensionCatalogView` are the Settings pages.

A `.glext` has its own type too (`com.deckirin.gllink.extension-archive`).

### The first app extension: GlassyBattery

`extensions/GlassyBattery.ext`, for the Mac.

[GlassyBattery](https://github.com/DecKirin/AirBattery) lists the batteries around a Mac in
its menu bar, widgets and CLI, and shares them with other Macs. Its **BatteryBridge** API
(`docs/BatteryBridge.md` there) lets another app on the same Mac add devices. This extension
puts each router with a battery there. It's an app extension: it reads what the app already has, and needs nothing on the router.

| What | Sent as |
|---|---|
| The battery | `level` and `charging`, from the router's battery reading |
| The router's name | `name`. Two routers with one name get a number. A name another device has gets " (GL-Link)" |
| The model | `model`: "GL-E5800", or "Mudi 7 · GL-E5800" for a router called something else |
| The icon | `customIcon`: the model's own icon, which it uploads first (`PUT /v1/icons/router.e5800`, an SVG). `icon: "wifi.router.fill"` and `type: "generic"` are what GlassyBattery draws where that can't be |

- **Connecting:**
  - It finds the server from `bridge.json`, falling back to the default ports. Reading that
    file also needs a `home-relative-path` read exception in the Mac app's sandbox.
  - It registers once, keeps the token in its secrets, and keeps one stream open with
    `onDisconnect: remove`. Quitting GL-Link, or turning the extension off or removing it,
    takes the routers out of GlassyBattery at once.
- **Freshness:**
  - Only a reading under 5 minutes old is sent. A router GL-Link can't reach goes quiet, and
    GlassyBattery marks it, then drops it.
  - Current routers are sent again every 2 minutes.
  - With the window closed, when the app stops reading, it asks for a fresh read.
- **Answers it acts on:**
  - **Approval pending** is shown as such.
  - **Token reset:** it registers again.
  - **Blocked or removed** in GlassyBattery: it stops, rather than undo the person's choice.
- **The model's icon:**
  - Each model GL-Link has a symbol for (`RouterSymbols.xcassets`) has a plain SVG in the
    package, `icons/router.<id>.svg`. `just ext-icons` (`tools/ext-router-icons.swift`)
    makes them from the symbols.
  - A symbol is an SF Symbols template, every weight on one artboard, which another app would
    draw whole. The tool keeps one glyph, Regular at Medium scale.
  - On each connection the script uploads the icon of every model with a battery, then sends
    those routers with `customIcon`. GlassyBattery keeps the icons per app, and the widget
    draws them too.
  - A GlassyBattery from before custom icons answers `no_such_route`; the routers then show
    `wifi.router.fill`.
- **Reset Connection:** the demo of an extension's own action (`gllink.actions`).
  - It asks first.
  - It forgets the token and signs in again. GlassyBattery replaces GL-Link's token, as it's
    the same app, rather than listing it twice.
  - It uploads the icons again and sends every router again.
  - It's also the way back after GL-Link was removed in GlassyBattery.
  - A socket closed by the reset can't end the connection that replaced it: each socket's
    events count only while it's the current one.
- **Verified** on this Mac with GlassyBattery 1.13.4 and the Mudi 7:
  - **Installed** by opening the `.ext`, and listed at 100 % and charging, as the router
    itself reported.
  - **Off and on** from its switch: out of GlassyBattery at once, then back.
  - **Removed:** gone from GlassyBattery, its package and switch deleted. Opening the
    `.ext` again installed it again.
  - **Relaunched:** the app started it again by itself.
  - **Custom icon**, against GlassyBattery rebuilt with custom icons (15:07):
    - `router.e5800.svg` was uploaded to its icon folder for GL-Link.
    - The device came with `customIcon: router.e5800`.
    - The dropdown draws the Mudi 7's own icon, with "GL-E5800" under its name.
  - **Reset Connection:** the confirmation showed the extension's own text. GlassyBattery's
    registration was rewritten at that moment, still one entry for GL-Link, and Mudi 7 was
    listed again straight after.
  - **Update** from 1.0.0 to 1.1.0 by opening the new `.ext`, which kept its switch on.

## Exporting

Exporting is a router extension with the `export` permission: it reads the bus and writes
elsewhere. GL-Link's own exporters are built on the same SDK as everyone else's, so the SDK
gets exercised:

| Exporter | Out | Notes |
|---|---|---|
| **MQTT** | A broker the owner names (`internet` or `lan` permission for it) | Home Assistant discovery: each entity becomes a HA entity under one device per GL-Link device. Switches, selects, numbers and buttons take commands back through `entity.set` and `entity.press`. Mosquitto isn't on GL firmware, so the broker is Home Assistant's own, or one on the LAN |
| **Prometheus** | `GET /metrics` on `br-lan` (`listen`) | Numeric entities as gauges, `class` as a label. A bearer token from its settings |
| **Webhook** | `POST` JSON to a URL | On chosen entities crossing a line, and on alerts. HMAC-signed |
| **InfluxDB** (later) | Line protocol | For long history off the router |

What exporters never send:
- **Texts:** they aren't on the bus. An exporter needs `sms` for those, which is confirmed
  separately.
- **Secrets, tokens or the router password.**

On the iPhone and Mac, generic App Intents cover every entity, built into the app once:

- **Get Router Value:** an `AppEntity` query over entities.
- **Set Router Value** and **Press Router Button.**
- **Router Changed:** an automation trigger, where Shortcuts allows one.

Shortcuts can then use a dish or a plug the moment its extension is installed. A configurable
**Router Value** widget and a **Router Switch** Control Center control follow the same way.

## Installing and managing

Both kinds are `.ext` packages. Where one goes depends on its `kind`.

### App extensions

The app opens a `.ext` from Finder, Files or a share, or from Settings → App Extensions → Add
App Extension. It checks the manifest and asks before installing; see
[App extensions](#app-extensions-ext-scripts-in-the-apps). A router extension opened this way
is refused, with a pointer to the router's page.

### Router extensions (to build)

**Package:** the same `.ext` folder, with:
- `manifest.json` with `"kind": "router"` and `exec`;
- `bin/aarch64-unknown-linux-musl/<exec>` and `bin/armv7-unknown-linux-musleabihf/<exec>`, the
  two CPUs gllinkd builds for;
- optionally a `README.md` the app can show.

It travels packed, as a `.glext`, since a folder can't be uploaded as is; and signed, as an
app extension is ([Trust](#trust-who-its-from)).

**Ways to install:**
- **In the app:** a router's page → Router Extensions → Add. The app checks the manifest,
  asks, and uploads the package to the router (`POST /v1/ext`, `ext:admin`). It will also
  offer a built-in list: first-party extensions it carries, as it carries gllinkd.
- **From a laptop:** `gllinkd ext install ./x.ext`.

**Before install,** the app shows:
- the name, version and size;
- the SHA-256;
- each permission in words. "Connect to 192.168.100.1 on the router's network" reads
  differently from "See everything GL-Link knows".

`sms` and `export` get their own confirmation.

**Updating** shows only what changed. New permissions are asked for again; fewer, or the
same, update straight away.

**Settings → a router → Router Extensions** lists each one, the same on every device:
- its state: Running, Stopped, Kept Quitting, or Off;
- its status line;
- its permissions, under Details.

**Still to build:** turning one off, its settings and log, and Remove (which deletes its
code, settings, history, user and firewall rules). The list and its states are built, against
`GET /v1/ext`. A gllinkd without extensions answers 404, which the page shows as "Not on This
Router Yet".

**Trust:** a router extension is signed and listed the same way as an app extension
([below](#trust-who-its-from)); gllinkd will check the signature as the apps do. `sms` and
`export` keep their own confirmation whoever published it.

## Trust: who it's from

Permissions say what an extension can reach. A signature says who it's from, and that it
arrived whole. Neither says the code is good: an extension is still held to its manifest,
whoever wrote it.

### Signatures

A publisher has one ed25519 key (`gllink-ext keygen`), kept on their own machine. Signing
adds `signature.json` to the package:

```json
{"v": 1,
 "key": "<the publisher's public key, base64>",
 "files": {"main.js": "<sha256>", "manifest.json": "<sha256>"},
 "signature": "<ed25519, base64>"}
```

What's signed is a text listing every file in the package, sorted, each with its SHA-256,
under the line `gllink-ext-signature-v1`. The app rebuilds that text from the files that are
there, so a changed, added or removed file breaks the signature. `files` is only there to
say which one ("“main.js” is different").

- **Inside the package, not beside it.** The signature holds for the folder and the `.glext`
  alike, survives being zipped again, and stays with the installed copy, which is checked at
  every launch.
- **Every file, by its content.** Not the zip's bytes, which differ between tools.
- **Names are plain:** letters, digits, spaces and `._@+-`, so a package reads the same on
  every system. Links aren't allowed; dot files (`.git`, `.DS_Store`) are never signed,
  packed or installed.

### What the person is told

| The package | The question says | An update is taken from |
|---|---|---|
| Listed in the marketplace, signed by the key it lists | "From the GL-Link marketplace, by *author*. Its source is public: *repo*." | That publisher only |
| Signed, by a key GL-Link doesn't know | "Signed by a publisher GL-Link doesn't know (*fingerprint*). Install it only if you trust where it came from." | That key only |
| Not signed | "Not signed: nothing says who made it. Install it only if you wrote it, or trust where it came from." | Anything: it's an author's own |

- **The key is pinned by installing.** There's no list of trusted publishers to manage: the
  first install of an id fixes its key, and removing it frees the id.
- **A fingerprint** is 16 hex digits of the key's SHA-256, short enough to compare by eye or
  read out: `C59B 2884 D975 2577`.
- **Unsigned packages still install,** with the plain warning. An author runs their own
  work that way, and `gllink-ext install` uses it.

## The marketplace

Where extensions are shared, by me and by anyone: a list in a public repository, and
Browse Extensions in the apps.

- **Where:** this repository, `DecKirin/gl-link-extensions`. GL-Link's own is private, and
  so can't serve the list itself. See [`MARKETPLACE.md`](../MARKETPLACE.md).
- **What it holds:** no code. One entry per extension, pointing at the extension's own public
  repository on GitHub.

```
entries/com.example.thing.json   an extension: added by pull request
index.json                       every entry in one file, which the app reads
index.json.sig                   the marketplace key's signature of index.json
```

An entry:

```json
{"id": "com.example.thing", "kind": "app", "name": "Thing", "version": "1.2.0",
 "summary": "…", "symbol": "bolt.fill", "platforms": ["ios", "macos"], "host_api": 1,
 "author": "Someone",
 "repo": "https://github.com/someone/gl-link-thing",
 "download": "https://github.com/someone/gl-link-thing/releases/download/Thing-1.2.0/Thing-1.2.0.glext",
 "sha256": "…", "size": 20480,
 "key": "<the publisher's public key>",
 "permissions": {"routers": ["battery"]}}
```

### The rules

1. **The source is public on GitHub.** `repo` is a GitHub repository, and the package's
   manifest names the same one.
2. **The file is a release of that repository:** `download` starts with
   `<repo>/releases/download/` and ends in `.glext`. The check fetches it with no
   credentials, so a private repository fails.
3. **It's signed by the entry's `key`,** and so is every later version. A pull request that
   changes an id's key fails, and needs a maintainer.
4. **The entry is what the package says:** id, version, platforms and permissions. The
   permissions are shown in the list, before anything is downloaded.
5. **A change comes with a higher version.**

The app applies 1, 2 and the shape of every entry itself when it reads the list, and 3 and 4
to what it downloads.

### From author to device

```
author                        marketplace repository                 device
──────                        ──────────────────────                 ──────
gllink-ext publish
  signs, packs  ─────────────▶ (release in the author's own repository)
  writes the entry ──PR──────▶ check: download, SHA-256, signature,
                               manifest, key unchanged
                               merge → index.json, signed with
                               the marketplace key  ───────────────▶ Browse Extensions:
                                                                      index signed by the marketplace?
                                                                      Get → download from the release
                                                                      SHA-256 = the entry's?
                                                                      signed by the entry's key?
                                                                      manifest = the entry's?
                                                                      then asks, as for any extension
```

- **The marketplace key** signs the list. Its public half is in the app
  (`Catalog.marketplaceKey`); a list signed by anyone else, or changed after signing, is
  refused. The private half is a secret of the marketplace repository's signing job, which
  runs on `main` only, never for a pull request.
- **Updates:** Settings → App Extensions shows "Update to 1.3.0" under an installed
  extension when the list has a newer version from the same publisher.
- **What listing means:** who published it, and that its source can be read. Not that anyone
  reviewed it. The app's own checks, and the permissions, are what hold an extension.
- **Removing an entry** stops it being listed; installed copies stay until their owners
  remove them. There's no remote kill switch: the app never changes what's installed without
  being asked.

## API

New routes, all under the existing token check:

| Call | Scope |
|---|---|
| `GET /v1/ext` → the router extensions installed (below) | `read` |
| `GET /v1/ext/entities` · `GET /v1/ext/cards` (the router provider's included) | `read` |
| `GET /v1/ext/{id}/history/{entity}?range=1d\|30d` | `read` |
| `POST /v1/ext/{id}/entities/{entity}` `{value}` or `{press: true}` | `ext:control` |
| `POST /v1/ext/{id}/state` (phone-made entities) | `ext:control` |
| `POST /v1/ext` (upload a `.glext`) · `PUT /v1/ext/{id}/config` · `POST /v1/ext/{id}/enable` · `/disable` · `DELETE /v1/ext/{id}` · `GET /v1/ext/{id}/log` | `ext:admin` |

`GET /v1/ext` is what the apps already read (`RouterExtension` in GLLinkKit). Each element:

```json
{"id": "com.example.starlink", "name": "Starlink", "version": "1.0.0",
 "summary": "Your dish's speed and obstructions…", "symbol": "dot.radiowaves.up.forward",
 "state": "running", "status": "Online · 182 Mbit/s",
 "permissions": ["Connect to 192.168.100.1:9200 on the router’s network", "Send you alerts"]}
```

- `state` is `running`, `stopped`, `crashed` or `off`; an unknown one shows as Unknown.
- `permissions` are in words, made by the router, so every app shows the same.

- **Events:**
  - `ext.state`: values, coalesced.
  - `ext.changed`: devices, entities or cards declared or removed.
  - `ext.status`: started, stopped, crashed.

  Older apps already skip events they don't know (`Event.unknown`).
- **Scopes:** new pairings get `ext:control` and `ext:admin`. Migration 0011 grants them to
  devices paired before, as 0007–0009 did for theirs.
- **Health:** `/v1/health` gains `ext_api`. Until then the apps read `GET /v1/ext`, and a
  404 means a daemon without extensions ("Not on This Router Yet").

## The SDK

What an extension author gets:

| Piece | For |
|---|---|
| **Protocol spec** and JSON Schemas for the manifest, entities and cards | Any language |
| **`gllink-ext`**, a Rust crate in `crates/` | Router extensions. Typed model from `gllink-core`, the JSON-RPC loop, helpers for `state`, `set` and `press`. Builds a static musl binary for both CPUs |
| **`gllink-ext.uc`**, a ucode module | Small router extensions with no build step. ucode ships with OpenWrt 23.05 and has JSON built in (`/usr/bin/ucode` is on the Mudi) |
| **`gllink-ext`** (built) | The author's tool, for both kinds of package: `new`, `check`, `run`, `keygen`, `build`, `verify`, `install`, `publish`, and `market check` / `market index` for the marketplace. It's an executable of `GLLinkExtensionKit`, so it checks, signs and runs with the code the app uses. `swift run gllink-ext help` |
| **`gllink.d.ts`** (built) | The script API as TypeScript declarations, for completion and checking in an editor. `gllink-ext new` writes it beside the script |
| **`gllinkd ext check`** | A router extension's binaries for both CPUs, beyond what `gllink-ext check` says of the package |
| **`gllinkd ext dev ./ext`** | Runs a router extension against `gl-mock` on the laptop (`just mock`, `just dev`); the app connects as usual and draws its cards |
| **`just ext-new <name>`** | A new extension from a template, with its Rust crate, manifest and a declared card |
| **`.ext` app extensions** | A manifest and a JavaScript script, run by `GLLinkExtensionKit` |
| **`examples/ext-counter`** | The smallest whole extension: a counter, a button that resets it, a card |

A router extension in Rust:

```rust
use gllink_ext::{Card, Entity, Extension, Host, Value};

struct Dish { client: DishClient }

impl Extension for Dish {
    async fn start(&mut self, host: &Host) -> anyhow::Result<()> {
        host.device("dish", "Starlink Dish").await?;
        host.declare([
            Entity::sensor("dish/downlink", "Download").unit("bit/s").class("data_rate").history(),
            Entity::binary("dish/obstructed", "Obstructed").class("problem"),
            Entity::button("dish/stow", "Stow").confirm("Stow the dish? The internet stops until it's back up."),
        ]).await?;
        host.card(Card::value("dish", "Starlink", "dish/downlink").tint_when("dish/obstructed", "orange")).await?;
        loop {
            let s = self.client.status().await?;
            host.state([("dish/downlink", Value::from(s.downlink_bps)),
                        ("dish/obstructed", Value::from(s.obstructed))]).await?;
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
    }

    async fn press(&mut self, _host: &Host, entity: &str) -> anyhow::Result<()> {
        match entity {
            "dish/stow" => self.client.stow().await,
            _ => anyhow::bail!("no such button"),
        }
    }
}

gllink_ext::main!(Dish { client: DishClient::new("192.168.100.1:9200") });
```

**Versions.** `host_api` is a whole number. gllinkd runs extensions written for its own number
or below. The protocol only grows: new messages and new optional fields. An extension written
for a newer host shows "Needs a newer router" and doesn't start.

## Threats

| Threat | Answer |
|---|---|
| An extension reads texts | Texts aren't on the bus. `sms` is its own permission, confirmed separately, and shown on the extension's page while granted |
| An extension sends data out | Network permissions name the hosts; a firewall rule for its uid stops the rest. `export` is worded as what it is |
| An extension changes the router behind gllinkd's back | Not root. Loopback is blocked, so GL's `/rpc` and gllinkd's API are out of reach. ubus to check. Router changes only through `router.set`, under `control` |
| An extension slows the router or fills its flash | Memory cgroup, `nice`, coalesced updates, capped history, a 16 MB package and a 64 KB store. Crash backoff |
| A card that looks like part of GL-Link, to trick | Cards are drawn by the app from data. The detail page always names the extension. Tints are limited to the set above |
| A tampered package | Signed packages are checked against every file's hash, at install and at every launch. From the marketplace, the download must also match the entry's SHA-256 |
| An update from someone else, to take over an installed extension's secrets | The publisher's key is pinned at install: an update with another key, or none, is refused |
| A fake list, or a real one changed on the way | The list is signed by the marketplace key the app carries |
| A listed extension swapped for another file after it was checked | The entry fixes the SHA-256 and the publisher's key; the release's file must match both on the device |
| A listed extension whose source nobody can read | `download` can only be a release of the entry's public GitHub repository, fetched without credentials |
| A package that points outside itself | No links, no `..`, plain file names; a `.glext` is unpacked only into its own folder, and bounded in size before it's unpacked |
| An app extension that reaches further than it said | Its script has only `gllink`; every call is checked against the manifest the person agreed to. No direct network, files or system APIs. A redirect to a host the manifest doesn't name isn't followed |
| A stolen publisher key | Out of GL-Link's hands: whoever has it can publish as that publisher. The marketplace can remove the entry; a new key means a new install |

## Considered and passed over

| Option | Why not |
|---|---|
| **WebAssembly in gllinkd** (wasmtime, wasmi) | wasmtime would multiply gllinkd's 5.8 MB, and an interpreter is slow. A device integration needs sockets, serial ports and USB, which WASI barely covers yet. Strong sandbox, wrong tradeoff for now. It can come later as a second runtime behind the same protocol |
| **Lua or ucode inside gllinkd** | In-process: a crash or a busy loop takes the daemon, and texts and pairing with it. One language |
| **GL's own plugins** (`gl-sdk4-plugins`, opkg) | Root code outside GL-Link's control, with no entities, cards or permissions. An extension can still be packaged as an `.ipk` later, for people who prefer opkg |
| **Native app plug-ins** (a Swift bundle loaded at run time) | Not possible on iOS, and on the Mac only for plug-ins signed by the app's own team, against the sandbox. `.ext` scripts in JavaScriptCore run on both, confined to `gllink` |
| **App extensions compiled into the app** | The first version of GlassyBattery. Nothing could be added or removed without a new build of the app |
| **Web views for cards** | Not native, heavy, and they don't follow Liquid Glass, Dynamic Type or the Duo layout. They'd also let an extension draw anything |
| **Home Assistant as the hub** | Needs a server. GL-Link works with just a router and a phone; HA is one place to export to |
| **Signing the `.glext` file itself** (a detached `.sig`, minisign-style) | The signature would be lost on unpacking, so the installed copy couldn't be checked again, and a folder couldn't be signed at all. Hashing the files inside works for both forms |
| **Apple's code signing, or notarization, for packages** | Needs a paid developer account per author, and says nothing a script package needs said. An ed25519 key costs nothing and works for router extensions too |
| **A list of trusted publishers in the app** | More to manage than it's worth: pinning the key at install gives the property that matters (updates come from whoever you installed from) with no settings |
| **The marketplace hosting the files** | It would become the thing to trust and to pay for. Entries pointing at each author's own public release keep the source and the file together, in the open |
| **Commands as free-form RPC** | Buttons, switches, selects and numbers cover device control. They can be exported, drawn and automated generically, and a free-form call can't. A `button` covers one-off actions |

## Plan

**Phase 0: check on the Mudi.** All reversible, each with your go-ahead before it changes
anything on the router:
- an nftables rule with `meta skuid` in a table of gllinkd's own;
- dnsmasq-full's `nftset=`;
- `ujail` with a static binary;
- a memory cgroup;
- adding a user, and whether a firmware upgrade keeps it;
- the ubus socket's permissions for a non-root user;
- the memory of a small Rust extension.

**Phase 1: the core.**
- **Model:** `gllink-core::ext`, with fixtures.
- **gllinkd's host:** supervisor, protocol, bus, router provider, cards, config, history.
- **API:** `/v1/ext/*` and the `ext.*` events.
- **SDK:** `gllink-ext` and `examples/ext-counter`; `gllinkd ext install / check / dev`.
- **Apps:** declared cards (`ExtensionCards`) with their detail pages, and Settings →
  Extensions.
- **Verified:** the counter on the Mudi, its card on the iPhone and the Mac.

**Phase 2: exporting.** MQTT with Home Assistant discovery, Prometheus and webhook, as
first-party extensions. Shortcuts' generic intents. Verified against a real Home Assistant.

**Phase 3: further.**
- **Automations:** entity triggers ("above", "below", "is") and actions (`set`, `press`).
  Router extensions join the arbiters through `automation::setting`'s generic `Setting`.
- **Widgets:** the Router Value widget and the Router Switch control.
- **App extensions:** declared cards from `.ext` scripts, and Shortcuts actions they can offer.
- **The ucode module.**

**Phase 4: the first device integration.** One real device, end to end, to prove the SDK
against hardware rather than a counter.

## Open questions

- **Which device first?** It should be one you have. Starlink, a smart plug, and USB serial
  (Victron) each test a different path: LAN gRPC, LAN HTTP, a device node.
- **The marketplace key** must be this repository's `MARKETPLACE_KEY` secret before the
  first entry is merged.
- **Review:** listing checks who and where, not what the code does. Whether a "reviewed"
  mark, given by hand, is worth having once there are outside authors.
- **Home Assistant:** whether you run it, and where its broker is. That decides whether the
  MQTT exporter needs `lan` or `internet`.
