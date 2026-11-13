// Hello: each router's battery as a row under it in Settings → App Extensions, and a button
// that reads the routers again. The quick start in docs/writing-extensions.md.

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
