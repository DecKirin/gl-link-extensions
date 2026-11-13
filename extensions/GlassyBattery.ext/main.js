// GlassyBattery: each router with a battery, in GlassyBattery's menu bar, widgets and CLI,
// and on your other Macs through its Nearcast. Through BatteryBridge, GlassyBattery's API for
// other apps on the same Mac (GlassyBattery/docs/BatteryBridge.md), over one stream that stays
// open while this runs. When it closes (GL-Link quit, or this was turned off or removed),
// GlassyBattery drops the routers at once.

"use strict";

const BRIDGE_FILE = "~/Library/Application Support/GlassyBattery/bridge.json";
const FALLBACK = { url: "http://127.0.0.1:48620", streamURL: "ws://127.0.0.1:48621" };
/// A reading counts as current this long. After that the router isn't sent again, so
/// GlassyBattery marks it, then drops it, as it does any device that stops reporting.
const FRESH_MS = 5 * 60 * 1000;
/// How often current routers are sent again, so GlassyBattery doesn't mark them as not
/// reporting (after 10 minutes) or drop them (after 20).
const KEEP_ALIVE_MS = 2 * 60 * 1000;
/// How old a reading may be before the routers are read again, as with the window closed.
const READ_EVERY_MS = 90 * 1000;
/// The SF Symbol GlassyBattery draws where it has no icon of the model's own.
const ROUTER_SYMBOL = "wifi.router.fill";

let socket = null;
/// Where BatteryBridge is, and GL-Link's token there, while connected.
let server = null;
let token = null;
let ready = false;
let stopped = false;
let retryTimer = null;
let keepAliveTimer = null;
let backoff = 2000;
let nextRef = 0;
/// What was last sent for each router, by id.
let sent = {};
/// Routers whose name GlassyBattery has for another device: sent as "Name (GL-Link)".
const renamed = new Set();
/// Upserts waiting for their answer: ref → router id.
const inFlight = {};
/// The models' own icons (icons/router.<id>.svg in this package) uploaded to GlassyBattery,
/// and those tried; by symbol name, which is also the icon's name there.
const uploaded = new Set();
const tried = new Set();
/// False once GlassyBattery turns out to predate custom icons (`/v1/icons`).
let customIcons = true;

// MARK: - What GlassyBattery lists

/// The routers to list: those with a current battery reading. Two with the same name get a
/// number, since GlassyBattery lists devices by name.
function devices(routers, now) {
  const taken = new Set();
  const out = [];
  for (const r of routers) {
    if (!r.battery || r.updated == null || now - r.updated >= FRESH_MS) continue;
    const base = r.name.trim().slice(0, 50) || (r.model ? r.model.name : "Router");
    let name = base;
    for (let n = 2; taken.has(name); n++) name = `${base} ${n}`;
    taken.add(name);
    if (renamed.has(r.id)) name = `${name} (GL-Link)`;
    const device = {
      id: r.id,
      name,
      // GlassyBattery draws the first it can: the model's own icon, uploaded (`customIcon`);
      // a router symbol (`icon`); the generic device.
      type: "generic",
      icon: ROUTER_SYMBOL,
      level: Math.min(Math.max(Math.round(r.battery.level), 0), 100),
      charging: !!r.battery.charging,
    };
    const symbol = r.model && r.model.symbol;
    if (symbol && uploaded.has(symbol)) device.customIcon = symbol;
    // The model's code, with its name too when the router is called something else.
    if (r.model) device.model = r.model.name === base ? r.model.code : `${r.model.name} · ${r.model.code}`;
    out.push(device);
  }
  return out;
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function push(force) {
  if (!ready || !socket) return;
  const routers = gllink.routers();
  const list = devices(routers, Date.now());
  const messages = [];
  for (const d of list) {
    if (!force && same(sent[d.id], d)) continue;
    const ref = String(++nextRef);
    inFlight[ref] = d.id;
    sent[d.id] = d;
    messages.push({ op: "upsert", ref, device: d });
  }
  // Routers removed from GL-Link, or without a battery now. One that's only gone quiet stays,
  // for GlassyBattery to age out.
  const known = new Set(routers.filter((r) => r.battery).map((r) => r.id));
  for (const id of Object.keys(sent)) {
    if (known.has(id)) continue;
    delete sent[id];
    messages.push({ op: "remove", ref: String(++nextRef), id });
  }
  (async () => {
    for (const m of messages) await socket.send(JSON.stringify(m));
  })().catch((e) => console.warn("send:", String(e)));
  show();
}

function show() {
  const listed = Object.values(sent).sort((a, b) => a.name.localeCompare(b.name));
  gllink.show(listed.map((d) => ({ title: d.name, value: `${d.level}%${d.charging ? " ⚡︎" : ""}` })));
  gllink.status(
    listed.length === 0 ? "Connected. No router with a battery is answering."
      : listed.length === 1 ? `Showing ${listed[0].name} in GlassyBattery.`
      : `Showing ${listed.length} routers in GlassyBattery.`,
  );
}

// MARK: - Icons

/// Uploads the icon of each model with a battery that GL-Link has a symbol for, once per
/// connection; then routers using one are sent again with it. A GlassyBattery without custom
/// icons answers no_such_route, and the routers keep the SF Symbol.
let uploading = false;
async function uploadIcons() {
  if (!customIcons || !server || !token || uploading) return;
  uploading = true;
  let added = false;
  try {
    for (const r of gllink.routers()) {
      const symbol = r.battery && r.model && r.model.symbol;
      if (!symbol || uploaded.has(symbol) || tried.has(symbol)) continue;
      tried.add(symbol);
      const data = gllink.resource(`icons/${symbol}.svg`, "base64");
      if (!data) continue;
      const res = await fetch(`${server.url}/v1/icons/${symbol}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ format: "svg", data }),
      });
      if (res.ok) {
        uploaded.add(symbol);
        added = true;
        continue;
      }
      const body = await res.json().catch(() => ({}));
      const code = body.error ? body.error.code : String(res.status);
      if (code === "no_such_route") {
        customIcons = false;
        console.log("This GlassyBattery has no custom icons: routers show the router symbol.");
        break;
      }
      console.warn(`icon ${symbol}:`, code);
    }
  } finally {
    uploading = false;
  }
  if (added) push(false);
}

// MARK: - Connecting

async function healthy(url) {
  try {
    const r = await fetch(`${url}/v1/health`);
    return r.status === 200 && (await r.json()).api === 1;
  } catch {
    return false;
  }
}

/// Where BatteryBridge listens: its file, else its default ports.
async function findServer() {
  const text = gllink.readFile(BRIDGE_FILE);
  if (text) {
    try {
      const f = JSON.parse(text);
      if (f.api === 1 && (await healthy(f.url))) return f;
    } catch {}
  }
  return (await healthy(FALLBACK.url)) ? FALLBACK : null;
}

/// The token, registering GL-Link the first time. Null when GlassyBattery has blocked it.
async function signIn(server) {
  const saved = gllink.secrets.get("token");
  if (saved) return saved;
  const r = await fetch(`${server.url}/v1/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: "GL-Link", bundleID: gllink.app.bundleID }),
  });
  const body = await r.json().catch(() => ({}));
  if (r.ok && body.token) {
    gllink.secrets.set("token", body.token);
    return body.token;
  }
  if (body.error && body.error.code === "blocked") return null;
  throw new Error(`registering: ${r.status} ${body.error ? body.error.code : ""}`);
}

async function connect() {
  retryTimer = null;
  if (stopped) return;
  const found = await findServer();
  if (!found) {
    gllink.status("Open GlassyBattery, and turn on BatteryBridge in its Settings.");
    return retry(15000);
  }
  const t = await signIn(found);
  if (!t) {
    gllink.status("GL-Link is blocked in GlassyBattery’s BatteryBridge settings.");
    return retry(60000);
  }
  server = found;
  token = t;
  // Each socket answers only while it's the current one: one closed by a reset mustn't end
  // the connection that replaced it.
  const s = gllink.connect(found.streamURL);
  socket = s;
  s.onmessage = (e) => {
    if (socket === s) handle(JSON.parse(e.data));
  };
  s.onclose = () => {
    if (socket !== s) return;
    closed();
    if (!stopped && retryTimer == null) {
      gllink.status("Lost GlassyBattery; trying again…");
      retry(backoff);
      backoff = Math.min(backoff * 2, 60000);
    }
  };
  await s.send(JSON.stringify({ op: "hello", token: t, onDisconnect: "remove", ref: "hello" }));
}

function handle(event) {
  switch (event.event) {
    case "ready":
      ready = true;
      backoff = 2000;
      sent = {};
      // Icons again on every connection: GlassyBattery forgets them when GL-Link is removed there.
      uploaded.clear();
      tried.clear();
      readIfStale()
        .then(uploadIcons)
        .catch((e) => console.warn("icons:", String(e)))
        .then(() => push(true));
      keepAliveTimer = setInterval(() => readIfStale().then(() => push(true)), KEEP_ALIVE_MS);
      break;
    case "pending":
      gllink.status("Waiting for you to approve GL-Link in GlassyBattery.");
      break;
    case "revoked":
      // The token was reset in GlassyBattery: a new one, on the next try.
      gllink.secrets.set("token", null);
      restart(1000);
      break;
    case "blocked":
      gllink.status("GL-Link is blocked in GlassyBattery’s BatteryBridge settings.");
      restart(60000);
      break;
    case "removed":
      // Registering again would undo what the person just did; Reset Connection does it.
      gllink.secrets.set("token", null);
      stopped = true;
      close();
      gllink.show([]);
      gllink.status("Removed in GlassyBattery. Reset Connection adds GL-Link again.");
      break;
    case "ack":
      delete inFlight[event.ref];
      break;
    case "error": {
      const id = inFlight[event.ref];
      delete inFlight[event.ref];
      const code = event.error ? event.error.code : "";
      if (code === "name_taken" && id && !renamed.has(id)) {
        // Another device has the router's name.
        renamed.add(id);
        delete sent[id];
        push(false);
      } else if (["unauthorized", "hello_timeout", "hello_required"].includes(code)) {
        gllink.secrets.set("token", null);
        restart(1000);
      } else {
        console.warn("BatteryBridge:", code, event.error ? event.error.message : "");
      }
      break;
    }
  }
}

/// Reads the routers again when one with a battery hasn't been heard from for a while.
async function readIfStale() {
  const now = Date.now();
  if (gllink.routers().some((r) => r.battery && (r.updated == null || now - r.updated > READ_EVERY_MS))) {
    await gllink.refresh();
  }
}

function closed() {
  socket = null;
  server = null;
  token = null;
  ready = false;
  sent = {};
  if (keepAliveTimer) clearInterval(keepAliveTimer);
  keepAliveTimer = null;
}

function close() {
  const s = socket;
  closed();
  if (s) s.close();
}

function restart(ms) {
  close();
  retry(ms);
}

function retry(ms) {
  if (stopped || retryTimer != null) return;
  retryTimer = setTimeout(() => connect().catch(failed), ms);
}

function failed(e) {
  console.warn(String(e));
  close();
  gllink.status("Lost GlassyBattery; trying again…");
  retry(backoff);
  backoff = Math.min(backoff * 2, 60000);
}

// MARK: - Reset Connection

/// Signs in to GlassyBattery afresh: a new token (GlassyBattery replaces GL-Link's old one, as
/// it's the same app), the icons uploaded again, every router sent again. For when GlassyBattery
/// was reinstalled, its token reset, or GL-Link was removed there.
function reset() {
  gllink.secrets.set("token", null);
  renamed.clear();
  customIcons = true;
  stopped = false;
  backoff = 2000;
  if (retryTimer != null) clearTimeout(retryTimer);
  retryTimer = null;
  close();
  gllink.show([]);
  gllink.status("Resetting the connection…");
  connect().catch(failed);
}

gllink.actions([
  {
    id: "reset",
    title: "Reset Connection",
    confirm: "GL-Link signs in to GlassyBattery again, with a new token. Your routers leave GlassyBattery for a moment, then come back.",
  },
]);
gllink.on("action", (id) => {
  if (id === "reset") reset();
});

gllink.on("routers", () => {
  push(false);
  // A model not seen before: its icon.
  if (ready) uploadIcons().catch((e) => console.warn("icons:", String(e)));
});
gllink.on("stop", () => {
  stopped = true;
  close();
});

gllink.status("Looking for GlassyBattery…");
connect().catch(failed);
