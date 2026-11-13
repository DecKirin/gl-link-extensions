# Extensions

GL-Link's own extensions, as `.ext` packages. Open one with GL-Link to install it: on the Mac,
`swift run gllink-ext install extensions/Hello.ext`, or double-click it, or use Settings → App
Extensions → Add from a File. For an iPhone, pack it first: `just build` writes
`build/*.glext`, signed with your key (`swift run gllink-ext keygen`).

| Package | Kind | Runs on | What |
|---|---|---|---|
| [`Hello.ext`](Hello.ext) | app | iPhone, iPad, Mac | Each router's battery under its name in Settings, and a Read Now button. The smallest whole extension: the quick start in [`docs/writing-extensions.md`](../docs/writing-extensions.md) |
| [`GlassyBattery.ext`](GlassyBattery.ext) | app | Mac | Each router with a battery in [GlassyBattery](https://github.com/DecKirin/AirBattery): its level, charging, model and the model's own icon. Reset Connection signs in again |

- **To write one:** [`docs/writing-extensions.md`](../docs/writing-extensions.md). The tool is
  `gllink-ext`: `new`, `check`, `run`, `build`, `install`, `publish`.
- **To share one:** the marketplace, [`MARKETPLACE.md`](../MARKETPLACE.md).
- **The design**, router extensions included: [`docs/extensions.md`](../docs/extensions.md).
- **Tests:** both packages are run by this repository's tests (`swift test`).
- **GlassyBattery's icons:** `GlassyBattery.ext/icons/` is generated from the app's router
  symbols, by `just ext-icons` in GL-Link's own repository.
