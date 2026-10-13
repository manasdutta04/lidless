// The tray panel: the only place a session starts.

import {
  invoke, onState, listen, state, session, isActive, isReady, needsSetup, isWarm,
  remaining, remainingFraction, clock, fmtDuration, fmtUntil, fmtRelative,
  escape, icon, batteryGlyph, batteryText, batteryLow, agentsText,
  THERMAL_WARNING, END_SUMMARY, render, bindActions,
} from "./shared.js";

const root = document.getElementById("panel");
const PRESETS = [["30m", 1800], ["1h", 3600], ["2h", 7200], ["4h", 14400], ["8h", 28800], ["12h", 43200]];
const EXTENSIONS = [["+15m", 900], ["+1h", 3600], ["+4h", 14400]];

let customText = "";

function view(snap) {
  if (!snap) return "";
  const active = isActive(snap);
  const parts = [header(active)];
  if (needsSetup(snap)) parts.push(setupCard(snap));
  if (snap.pendingStart != null) parts.push(ventilation(snap));
  else if (snap.busy) parts.push(`<div class="card"><div class="busy"><span class="spinner"></span><span>${escape(snap.busy)}</span></div></div>`);
  else if (active) parts.push(activeCard(snap));
  else parts.push(idle(snap));
  if (snap.error) parts.push(errorBanner(snap.error));
  parts.push(warnings(snap));
  if (snap.update?.state === "available") {
    parts.push(`<button class="update-strip" data-action="about">${icon("downloadCircle")}<span>Lidless ${escape(snap.update.release.version)} is available</span><span class="spacer"></span><span class="cta">Update</span></button>`);
  }
  parts.push(statusCard(snap));
  parts.push(footer());
  return parts.join("");
}

function header(active) {
  return `<div class="panel-header">
    <img src="brand.png" alt="">
    <span class="name">Lidless</span>
    <span class="pill ${active ? "on" : ""}"><span class="dot"></span>${active ? "Awake" : "Sleeps normally"}</span>
  </div>`;
}

function idle(snap) {
  const ready = isReady(snap);
  const warm = isWarm(snap.thermal);
  const le = snap.status?.lastEnd;
  return `<div class="idle">
    <div>
      <div class="headline">Close the lid, keep working.</div>
      <div class="subline">Choose how long your computer stays awake.</div>
    </div>
    <div class="presets">
      ${PRESETS.map(([l, s]) => `<button class="btn" data-action="start" data-seconds="${s}" ${ready ? "" : "disabled"}>${l}</button>`).join("")}
    </div>
    <form class="custom" data-key="custom">
      <input class="field" id="custom" placeholder="Custom, like 1h30m" value="${escape(customText)}" autocomplete="off" spellcheck="false" ${ready ? "" : "disabled"}>
      <button class="btn primary" type="submit" ${ready && customText.trim() ? "" : "disabled"}>Start</button>
    </form>
    <div class="reminder ${warm ? "warm" : ""}">${icon("thermometer")}<span>Keep it on a hard, ventilated surface. Never close it in a bag.</span></div>
    ${le ? `<div class="last-end">Last session ended ${escape(fmtRelative(new Date(le.at)))}. ${escape(END_SUMMARY[le.reason] || "")}</div>` : ""}
  </div>`;
}

function detailText(s) {
  const until = `Until ${fmtUntil(new Date(s.endsAt))}`;
  if (s.command) return `${until} · ${s.command.join(" ")}`;
  if (s.owner.kind === "cli") return `${until} · from Terminal`;
  if (s.owner.kind === "run") return `${until} · lidless run`;
  return until;
}

function activeCard(snap) {
  const s = session(snap);
  return `<div class="card" data-key="active">
    <div>
      <div class="awake-label">Awake for</div>
      <div class="countdown">${clock(remaining(snap))}</div>
      <div class="detail">${escape(detailText(s))}</div>
    </div>
    <div class="progress"><div style="width:${(remainingFraction(snap) * 100).toFixed(2)}%"></div></div>
    <div class="actions">
      ${EXTENSIONS.map(([l, s]) => `<button class="btn accent" data-action="extend" data-seconds="${s}">${l}</button>`).join("")}
      <button class="btn danger" data-action="stop">Stop</button>
    </div>
  </div>`;
}

function ventilation(snap) {
  const level = snap.thermal;
  const warm = isWarm(level);
  const body = THERMAL_WARNING[level] || "With the lid closed your computer keeps working and can get warm. Leave it on a hard, open surface like a desk, never on a bed or sofa, and never in a bag or sleeve.";
  return `<div class="card ${warm ? "warning-wash" : ""}" data-key="vent">
    <div class="vent ${warm ? "warm" : ""}">
      ${icon(level === "serious" || level === "critical" ? "thermometerHigh" : "thermometer")}
      <div>
        <h3>${warm ? "Your computer is warm" : "Keep it ventilated"}</h3>
        <p>${escape(body)}</p>
        <p class="note">Lidless ends the session by itself if your computer gets too hot.</p>
      </div>
    </div>
    <div class="actions">
      <button class="btn" data-action="cancel">Cancel</button>
      <button class="btn primary" data-action="confirm">Start ${fmtDuration(snap.pendingStart)}</button>
    </div>
  </div>`;
}

function setupCard(snap) {
  const r = snap.readiness;
  return `<div class="card wash setup-card" data-key="setup">
    <div>
      <h3>One-time setup</h3>
      <p>Lidless needs permission to switch one sleep setting, and a small helper that switches it back if anything goes wrong.</p>
    </div>
    <div class="checks">
      ${check("Sleep permission", r?.privilege)}
      ${check("Recovery helper", r?.recoveryArmed)}
    </div>
    ${snap.setupMessage ? `<p class="danger-text selectable" style="margin:0;font-size:12px">${escape(snap.setupMessage)}</p>` : ""}
    <div class="foot">
      <button class="btn quiet" data-action="help" style="margin-left:-8px">Learn more</button>
      <span class="spacer"></span>
      ${snap.setupRunning ? '<span class="spinner"></span>' : ""}
      <button class="btn primary" data-action="setup" ${snap.setupRunning ? "disabled" : ""}>Set Up…</button>
    </div>
  </div>`;
}

function check(title, ok) {
  const cls = ok == null ? "" : ok ? "ok" : "no";
  const glyph = ok == null ? '<span class="spinner"></span>' : icon(ok ? "checkCircle" : "circle");
  return `<div class="check ${cls}">${glyph}<span>${title}</span></div>`;
}

function errorBanner(text) {
  return `<div class="card danger-wash" data-key="error"><div class="banner danger">
    ${icon("alertCircle")}<span class="text selectable">${escape(text)}</span>
    <button class="btn quiet" data-action="dismiss" aria-label="Dismiss">${icon("x")}</button>
  </div></div>`;
}

function warnings(snap) {
  const list = (snap.status?.warnings || []).filter((w) => !w.startsWith("Lidless will not start"));
  if (!list.length) return "";
  return `<div class="card warning-wash" data-key="warnings" style="gap:8px">
    ${list.map((w) => `<div class="banner warning">${icon("alertTriangle")}<span class="text">${escape(w)}</span></div>`).join("")}
  </div>`;
}

function statusCard(snap) {
  const p = snap.status?.power;
  const rows = [];
  if (p) rows.push(row(batteryGlyph(p), "Battery", batteryText(p), batteryLow(p)));
  rows.push(row(icon("laptop"), "Lid", snap.status?.lidClosed === true ? "Closed" : "Open"));
  rows.push(row(icon(snap.online ? "wifi" : "wifiOff"), "Network", snap.online ? "Online" : "Offline", !snap.online));
  rows.push(row(icon("terminal"), "Agents", agentsText(snap.agents)));
  if (snap.lowPowerActive) rows.push(row(icon("leaf"), "Low power mode", "On while closed"));
  return `<div class="card tight" data-key="status">${rows.join('<div class="hairline"></div>')}</div>`;
}

function row(glyph, title, value, danger = false) {
  return `<div class="row">${glyph}<span class="title">${title}</span><span class="value ${danger ? "danger" : ""}">${escape(value)}</span></div>`;
}

function footer() {
  return `<div class="footer">
    <button class="btn quiet" data-action="settings">${icon("gear")} Settings</button>
    <button class="btn quiet" data-action="help">${icon("help")} Help</button>
    <span class="spacer"></span>
    <button class="btn quiet" data-action="quit">Quit</button>
  </div>`;
}

// MARK: Wiring

function paint() {
  render(root, view(state.snap));
}

bindActions(root, {
  start: (el) => invoke("start", { seconds: Number(el.dataset.seconds) }),
  extend: (el) => invoke("extend", { seconds: Number(el.dataset.seconds) }),
  stop: () => invoke("stop"),
  cancel: () => invoke("cancel_start"),
  confirm: () => invoke("confirm_start"),
  dismiss: () => invoke("dismiss_error"),
  setup: () => invoke("setup"),
  settings: () => invoke("open_window", { page: "settings" }),
  about: () => invoke("open_window", { page: "about" }),
  help: () => invoke("open_url", { url: "https://lidless.manasdutta.com/docs" }),
  quit: () => invoke("quit"),
});

root.addEventListener("input", (e) => {
  if (e.target.id === "custom") {
    customText = e.target.value;
    paint();
  }
});

root.addEventListener("submit", async (e) => {
  e.preventDefault();
  const raw = customText.trim();
  if (!raw) return;
  try {
    const seconds = await invoke("parse_duration", { raw });
    customText = "";
    paint();
    await invoke("start", { seconds });
  } catch (err) {
    state.snap = { ...state.snap, error: String(err) };
    paint();
  }
});

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") invoke("close_panel");
});

// The window follows the content height.
new ResizeObserver(() => {
  const h = Math.ceil(root.getBoundingClientRect().height);
  if (h > 0) invoke("resize_panel", { height: h });
}).observe(root);

listen("panel-will-open", () => { customText = ""; paint(); });
onState(paint);
