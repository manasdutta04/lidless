// The desktop window: overview, history, settings, setup, about. Read-only
// for sessions; those start from the tray panel.

import {
  invoke, onState, listen, state, session, isActive, needsSetup, isWarm,
  remaining, remainingFraction, clock, fmtDuration, fmtUntil, fmtRelative, fmtTime, fmtDate, fmtShortDate, fmtWeekday, fmtHour,
  escape, icon, greeting, capitalize, END_SUMMARY, render, bindActions, copyText,
} from "./shared.js";

const sidebar = document.getElementById("sidebar");
const content = document.getElementById("content");

const PAGES = [
  ["overview", "Overview", "grid"],
  ["history", "History", "clock"],
  ["settings", "Settings", "sliders"],
  ["setup", "Setup", "shield"],
  ["about", "About & Updates", "info"],
];

const ui = {
  page: "overview",
  stats: null,
  history: [],
  historyVersion: -1,
  tipIndex: 0,
  copiedAt: 0,
};

// MARK: Sidebar

function sidebarView(snap) {
  const active = isActive(snap);
  const release = snap?.update?.release?.version;
  const showUpdate = snap?.update?.state === "available";
  return `
    <div class="brand"><img src="brand.png" alt=""><span>Lidless</span></div>
    <nav class="nav">
      ${PAGES.map(([id, title, glyph]) => `<button class="${ui.page === id ? "selected" : ""}" data-action="nav" data-page="${id}">
        ${icon(glyph)}<span class="label">${title}</span>${id === "setup" && needsSetup(snap) ? '<span class="badge"></span>' : ""}
      </button>`).join("")}
    </nav>
    <div class="spacer"></div>
    ${showUpdate ? `<button class="update-btn" data-action="nav" data-page="about">${icon("downloadCircle")}<span>Update to ${escape(release)}</span></button>` : ""}
    <div class="status ${active ? "on" : ""}"><span class="dot"></span><span>${active ? `Awake · ${clock(remaining(snap))}` : "Sleeps normally"}</span></div>`;
}

// MARK: Overview

const DECORATIVE = ["wind", "wifi", "bolt", "terminal", "micOff", "thermometer", "plug"];
const SPOTS = [[-14, 22, 0], [92, 34, 1], [196, 14, 2], [40, 118, 3], [146, 104, 4], [-6, 196, 5], [98, 186, 6]];

function tips(snap) {
  const list = [];
  const c = snap.config || {};
  const p = snap.status?.power;
  if (isWarm(snap.thermal)) {
    list.push({ glyph: "thermometer", title: "Your computer is warm right now", body: "Give it open air before closing the lid: a desk, not a bed, sofa or lap.", timely: true });
  }
  if (!snap.online) {
    list.push({ glyph: "wifi", title: "You're offline", body: "Connect to a network before closing the lid, so remote control and SSH can reach your agent.", timely: true });
  }
  if (p?.hasBattery && p.onBattery && p.percent != null && p.percent < 50) {
    list.push({ glyph: "plug", title: "Plug in for a long session", body: `You're at ${p.percent}%. Low power mode starts below ${c.lowPowerBelowPercent}%, and the session ends below ${c.endBelowPercent}% to protect the battery.`, action: "settings", actionTitle: "Battery Settings", timely: true });
  }
  if (!isActive(snap) && snap.agents?.length) {
    list.push({ glyph: "terminal", title: `${snap.agents[0].name} is running`, body: "Start a session from the Lidless tray icon before you close the lid, and it keeps working.", action: "panel", actionTitle: "Open Tray Panel", timely: true });
  }
  list.push(
    { glyph: "wind", title: "Keep it ventilated", body: "Closed-lid work holds in heat. Use a hard, open surface, and never close the computer in a bag or sleeve.", action: "link", url: "https://github.com/manasdutta04/lidless#readme", actionTitle: "Learn More" },
    { glyph: "terminal", title: "Wrap your agent in one command", body: "Run lidless run -- claude and your computer stays awake exactly as long as the agent runs, then sleeps normally.", action: "copy", text: "lidless run -- claude", actionTitle: "Copy Command" },
    { glyph: "wifi", title: "Stay connected", body: "Remote control and SSH need a network. Lidless warns you if the connection drops while the lid is closed.", action: "settings", actionTitle: "Notification Settings" },
    { glyph: "bolt", title: "Plug in for overnight work", body: "On the power adapter the battery limits don't apply, so a session can run as long as you set." },
    { glyph: "micOff", title: "Some microphones turn off with the lid", body: "Many laptops disconnect the built-in mic when closed. Use a headset or an external mic for voice tools." },
  );
  const seen = new Set();
  return list.filter((t) => !seen.has(t.title) && seen.add(t.title));
}

function hero(snap) {
  const list = tips(snap);
  if (!list.length) return "";
  const index = ui.tipIndex % list.length;
  const tip = list[index];
  const copied = tip.action === "copy" && Date.now() - ui.copiedAt < 2500;
  const action = tip.action
    ? `<button class="btn hero" data-action="tip" data-kind="${tip.action}" data-url="${escape(tip.url || "")}" data-text="${escape(tip.text || "")}">${copied ? "Copied" : escape(tip.actionTitle)}</button>`
    : "";
  return `<div class="hero" data-key="hero">
    <div class="cluster">
      ${SPOTS.map(([x, y, i]) => `<span class="orb ${DECORATIVE[i] === tip.glyph ? "on" : ""}" style="right:${x}px;top:${y}px">${icon(DECORATIVE[i])}</span>`).join("")}
    </div>
    <div class="body">
      <div class="label ${tip.timely ? "now" : ""}">${tip.timely ? '<span class="dot"></span>Right now' : `Tip ${index + 1} of ${list.length}`}</div>
      <h3>${escape(tip.title)}</h3>
      <p>${escape(tip.body)}</p>
      <div class="foot">
        ${action}
        ${list.length > 1 ? '<button class="next" data-action="next-tip">Next tip</button>' : ""}
        <div class="dots">${list.map((_, i) => `<i class="${i === index ? "on" : ""}" data-action="tip-index" data-index="${i}"></i>`).join("")}</div>
      </div>
    </div>
  </div>`;
}

function overview(snap) {
  const s = session(snap);
  const line = s
    ? `Your computer is staying awake with the lid closed until ${fmtUntil(new Date(s.endsAt))}.`
    : "Your computer sleeps normally. Start a session from the tray icon whenever an agent has work to do.";
  return `<div class="page">
    <div class="page-header"><h1>${greeting()}</h1><p class="${s ? "on" : ""}">${escape(line)}</p></div>
    ${hero(snap)}
    ${needsSetup(snap) ? setupCard(snap) : ""}
    ${s ? live(snap) : ""}
    ${statsSection(snap)}
    ${heatmap()}
    ${weekChart()}
    ${hourChart()}
  </div>`;
}

function live(snap) {
  return `<div class="card wash" data-key="live" style="gap:10px">
    <div class="live">
      <div><div class="lbl">Awake</div><div class="countdown">${clock(remaining(snap))}</div></div>
      <span class="spacer"></span>
      <button class="btn" data-action="panel">Open tray panel</button>
    </div>
    <div class="progress"><div style="width:${(remainingFraction(snap) * 100).toFixed(2)}%"></div></div>
    <div class="faint" style="font-size:11.5px">Extend or stop the session from the tray panel.</div>
  </div>`;
}

function statsSection() {
  const st = ui.stats?.stats;
  const since = st?.firstSession ? `Since ${fmtDate(new Date(st.firstSession))}` : "";
  let body;
  if (!st || st.sessions === 0) {
    body = `<div class="card"><div class="muted" style="font-size:12.5px">Your stats appear here after your first session: time awake, hours with the lid closed, and more. Start one from the Lidless icon in the tray.</div></div>`;
  } else {
    const f = fmtDuration;
    const plural = (n, w) => `${n} ${w}${n === 1 ? "" : "s"}`;
    body = `<div class="tiles">
      ${tile(f(st.totalAwakeSeconds), "Time awake", `across ${plural(st.sessions, "session")}`)}
      ${tile(f(st.closedLidSeconds), "With the lid closed", "your agents kept working")}
      ${tile(f(st.thisWeekSeconds), "This week", "last 7 days")}
      ${tile(f(st.longestSeconds), "Longest session", `average ${f(st.averageSeconds)}`)}
      ${tile(String(st.sessions), "Sessions", st.commandSessions > 0 ? `${st.commandSessions} wrapped a command` : "from the tray or Terminal")}
      ${tile(st.cleanRestorePercent == null ? "—" : `${st.cleanRestorePercent}%`, "Restored cleanly", st.endedBySafety > 0 ? `${st.endedBySafety} ended by safety limits` : "sleep settings put back")}
    </div>`;
  }
  return `<div class="section"><div class="head"><h2>Your Lidless</h2><span>${since}</span></div>${body}</div>`;
}

function tile(v, l, d) {
  return `<div class="tile"><div class="v">${escape(v)}</div><div class="l">${l}</div><div class="d">${escape(d)}</div></div>`;
}

function heatmap() {
  const days = ui.stats?.daily || [];
  const max = Math.max(1, ...days.map((d) => d.awakeSeconds));
  const first = days[0] ? new Date(days[0].start) : new Date();
  // Weeks start on Monday.
  const lead = (first.getDay() + 6) % 7;
  const cells = Array(lead).fill(null).concat(days);
  const activeDays = days.filter((d) => d.awakeSeconds > 0).length;
  const labels = ["", "Tue", "", "Thu", "", "Sat", ""];
  return `<div class="section">
    <div class="head"><h2>Activity</h2><span>${activeDays} active day${activeDays === 1 ? "" : "s"} in the last 12 weeks</span></div>
    <div class="card" style="gap:10px">
      <div class="heat">
        <div class="days">${labels.map((l) => `<span>${l}</span>`).join("")}</div>
        <div class="grid">${cells.map((d) => {
          if (!d) return '<div class="cell none"></div>';
          const sec = d.awakeSeconds;
          const alpha = sec > 0 ? 0.25 + 0.75 * Math.sqrt(sec / max) : 0;
          const style = sec > 0 ? `style="background:color-mix(in srgb, var(--accent) ${(alpha * 100).toFixed(0)}%, var(--sunken))"` : "";
          return `<div class="cell" ${style} title="${fmtShortDate(new Date(d.start))}: ${sec > 0 ? fmtDuration(sec) : "no sessions"}"></div>`;
        }).join("")}</div>
      </div>
      <div class="legend"><span>Less</span>${[0, 0.25, 0.5, 0.75, 1].map((l) => `<i style="${l ? `background:color-mix(in srgb, var(--accent) ${Math.round((0.2 + 0.8 * l) * 100)}%, var(--sunken))` : ""}"></i>`).join("")}<span>More</span></div>
    </div>
  </div>`;
}

function weekChart() {
  const days = ui.stats?.stats?.lastSevenDays || [];
  const max = Math.max(1, ...days.map((d) => d.awakeSeconds));
  return `<div class="section"><h2>This week</h2><div class="card"><div class="week">
    ${days.map((d, i) => {
      const today = i === days.length - 1;
      const h = Math.max(4, 84 * d.awakeSeconds / max);
      return `<div class="col">
        <span class="n">${d.awakeSeconds > 0 ? escape(fmtDuration(d.awakeSeconds).split(" ")[0]) : ""}</span>
        <div class="bar ${d.awakeSeconds > 0 ? (today ? "today" : "on") : ""}" style="height:${h}px"></div>
        <span class="d ${today ? "today" : ""}">${fmtWeekday(new Date(d.start))}</span>
      </div>`;
    }).join("")}
  </div></div></div>`;
}

function hourChart() {
  const hours = ui.stats?.hours || Array(24).fill(0);
  const max = Math.max(1, ...hours);
  const peak = hours.indexOf(Math.max(...hours));
  const any = hours.some((h) => h > 0);
  return `<div class="section">
    <div class="head"><h2>When your computer works</h2><span>${any ? `Busiest around ${fmtHour(peak)}` : ""}</span></div>
    <div class="card" style="gap:6px">
      <div class="hours">${hours.map((h, i) => `<i class="${h > 0 ? (i === peak ? "peak" : "on") : ""}" style="height:${Math.max(3, 60 * h / max)}px" title="${fmtHour(i)}: ${h > 0 ? fmtDuration(h) : "none"}"></i>`).join("")}</div>
      <div class="hour-labels">${[0, 6, 12, 18, 23].map((h) => `<span>${fmtHour(h)}</span>`).join("")}</div>
    </div>
  </div>`;
}

// MARK: History

function historyPage() {
  const list = ui.history.slice(0, 100);
  const sub = list.length ? `Your last ${list.length} sessions, newest first.` : "Sessions you run will be listed here.";
  return `<div class="page" style="gap:22px">
    <div class="page-header"><h1>History</h1><p>${sub}</p></div>
    ${list.length ? `<div class="card history">${list.map(historyRow).join("")}</div>` : ""}
  </div>`;
}

function historyRow(e) {
  const started = new Date(e.startedAt);
  const dur = (Date.parse(e.endedAt) - Date.parse(e.startedAt)) / 1000;
  const source = e.owner === "app" ? "Tray" : e.owner === "cli" ? "Terminal" : "lidless run";
  const glyph = { batteryFloor: "battery", batteryUnreadable: "battery", thermalFloor: "thermometerHigh", commandExited: "terminal", expired: "timer" }[e.reason]
    || (e.restoreComplete ? "checkCircle" : "alertCircle");
  return `<div class="hrow" data-key="${e.id}">
    ${icon(glyph, e.restoreComplete ? "" : "bad")}
    <div class="main"><div class="t">${capitalize(fmtRelative(started))} · ${fmtTime(started)}</div><div class="s">${source} · ${escape(END_SUMMARY[e.reason] || e.reason)}</div></div>
    <div class="right"><div class="t">${fmtDuration(Math.max(0, dur))}</div>${e.closedLidSeconds > 0 ? `<div class="s">${fmtDuration(e.closedLidSeconds)} lid closed</div>` : ""}</div>
  </div>`;
}

// MARK: Settings

function toggle(label, key, checked, change = "config") {
  return `<label class="setting"><span class="label">${label}</span><input type="checkbox" class="switch" data-change="${change}" data-key="${key}" ${checked ? "checked" : ""}></label>`;
}

function stepper(label, key, value, text, step, min, max) {
  return `<div class="setting"><span class="label">${label}</span><span class="val">${escape(text)}</span>
    <span class="stepper">
      <button data-action="step" data-key="${key}" data-delta="${-step}" data-min="${min}" data-max="${max}" aria-label="Less">${icon("minus")}</button><span></span>
      <button data-action="step" data-key="${key}" data-delta="${step}" data-min="${min}" data-max="${max}" aria-label="More">${icon("plus")}</button>
    </span></div>`;
}

const HAIR = '<div class="hairline"></div>';

function settingsPage(snap) {
  const c = snap.config;
  const macPreview = snap.platform === "fake";
  const days = Math.round(c.maxDurationSeconds / 86400);
  const runHours = Math.round(c.runDefaultDurationSeconds / 3600);
  return `<div class="page compact">
    <div class="page-header"><h1>Settings</h1><p>Changes apply right away, and to every new session.</p></div>
    ${section("While the lid is closed", [
      toggle("Turn the display off", "sleepDisplayOnLidClose", c.sleepDisplayOnLidClose),
      toggle("Use low power mode on battery", "lowPowerOnLidClose", c.lowPowerOnLidClose),
    ])}
    ${section("Safety", [
      stepper("Low power mode below", "lowPowerBelowPercent", c.lowPowerBelowPercent, `${c.lowPowerBelowPercent}%`, 5, 5, 100),
      stepper("End the session below", "endBelowPercent", c.endBelowPercent, c.endBelowPercent === 0 ? "Never" : `${c.endBelowPercent}%`, 5, 0, 50),
      toggle("End on critical temperature", "thermalRules", c.thermalRules),
    ], "Battery rules apply on battery power only. A session also ends if the battery level cannot be read twice in a row.")}
    ${section("Sessions", [
      stepper("Longest session", "maxDurationSeconds", c.maxDurationSeconds, `${days} day${days === 1 ? "" : "s"}`, 86400, 86400, 30 * 86400),
      stepper("Default for lidless run", "runDefaultDurationSeconds", c.runDefaultDurationSeconds, `${runHours} hour${runHours === 1 ? "" : "s"}`, 3600, 3600, c.maxDurationSeconds),
      stepper("Verify after", "verifySettleSeconds", c.verifySettleSeconds, `${Math.round(c.verifySettleSeconds)} s`, 1, 0, 30),
    ], "After switching the closed-lid setting on, Lidless reads it back and refuses to continue if the system reverted it.")}
    ${section("General", [
      toggle("Open at login", "autostart", snap.autostart, "autostart"),
      macPreview ? toggle("Show in the Dock", "showInDock", c.showInDock) : null,
      toggle("Show the awake state in the tray icon", "animateMenuBarIcon", c.animateMenuBarIcon),
    ])}
    ${section("Notifications", [
      toggle("Session started and ended", "notifications", c.notifications),
      toggle("Warn when the network drops", "warnOnNetworkLoss", c.warnOnNetworkLoss),
    ])}
  </div>`;
}

function section(title, rows, footnote) {
  const items = rows.filter(Boolean);
  return `<div class="section"><h2>${title}</h2><div class="card">${items.join(HAIR)}</div>${footnote ? `<div class="footnote">${footnote}</div>` : ""}</div>`;
}

// MARK: Setup

function setupCard(snap) {
  const r = snap.readiness;
  return `<div class="card wash setup-card" data-key="setup">
    <div><h3>One-time setup</h3><p>Lidless needs permission to switch one sleep setting, and a small helper that switches it back if anything goes wrong.</p></div>
    <div class="checks">${checkLine("Sleep permission", r?.privilege)}${checkLine("Recovery helper", r?.recoveryArmed)}</div>
    ${snap.setupMessage ? `<p class="danger-text selectable" style="margin:0;font-size:12px">${escape(snap.setupMessage)}</p>` : ""}
    <div class="foot"><span class="spacer"></span>${snap.setupRunning ? '<span class="spinner"></span>' : ""}<button class="btn primary" data-action="setup" ${snap.setupRunning ? "disabled" : ""}>Set Up…</button></div>
  </div>`;
}

function checkLine(title, ok) {
  const cls = ok == null ? "" : ok ? "ok" : "no";
  const glyph = ok == null ? '<span class="spinner"></span>' : icon(ok ? "checkCircle" : "circle");
  return `<div class="check ${cls}">${glyph}<span>${title}</span></div>`;
}

function statusRow(title, ok, detail) {
  const stateText = ok == null ? "Checking…" : ok ? "Ready" : "Not set up";
  return `<div class="status-row">${checkLine("", ok)}<div class="main"><div class="t">${title}</div><div class="s">${escape(detail)}</div></div><span class="state ${ok == null ? "" : ok ? "ok" : "no"}">${stateText}</span></div>`;
}

function setupPage(snap) {
  const r = snap.readiness;
  const need = needsSetup(snap);
  const active = isActive(snap);
  const ops = snap.privilegedOperations || [];
  return `<div class="page compact">
    <div class="page-header"><h1>Setup</h1><p>${need ? "One step left: allow Lidless to switch one sleep setting." : "Everything Lidless needs is installed and working."}</p></div>
    <div class="section"><h2>Status</h2><div class="card">
      ${statusRow("Sleep permission", r?.privilege, "Lets Lidless change the closed-lid setting without asking for a password every time.")}
      ${HAIR}
      ${statusRow("Recovery helper", r?.recoveryArmed, r?.recoveryDetail || "Checks every minute and puts settings back if Lidless stops unexpectedly.")}
      ${snap.setupMessage ? `${HAIR}<div class="muted selectable" style="font-size:12px">${escape(snap.setupMessage)}</div>` : ""}
      <div class="button-row">
        <button class="btn ${need ? "primary" : ""}" data-action="setup" ${snap.setupRunning ? "disabled" : ""}>${need ? "Set Up…" : "Run Setup Again"}</button>
        <button class="btn" data-action="log">Open Log</button>
        ${snap.setupRunning ? '<span class="spinner"></span>' : ""}
      </div>
    </div></div>
    <div class="section"><h2>What runs as administrator</h2><div class="card">
      <div class="code-list">${ops.length ? ops.map((o) => `<span class="selectable">${escape(o)}</span>`).join("") : '<span class="faint">Nothing on this platform.</span>'}</div>
    </div><div class="footnote">Nothing else ever runs with elevated rights.</div></div>
    <div class="section"><h2>Remove Lidless</h2><div class="card">
      <div class="setting">
        <span class="label ${active ? "faint" : ""}">${active ? "Stop the current session first." : "Uninstall the permission and helper"}</span>
        <button class="btn danger" data-action="uninstall" ${snap.setupRunning || active ? "disabled" : ""}>Uninstall…</button>
      </div>
    </div><div class="footnote">Restores your sleep settings, then removes the permission and the recovery helper. Afterwards, uninstall the app itself.</div></div>
  </div>`;
}

// MARK: About

function aboutPage(snap) {
  const u = snap.update || { state: "idle" };
  const v = snap.version;
  let title, detail, controls;
  switch (u.state) {
    case "checking": title = "Checking for updates…"; detail = "Asking GitHub for the latest release."; controls = '<span class="spinner"></span>'; break;
    case "upToDate": title = "You're up to date"; detail = `Lidless ${u.version} is the newest version.`; controls = check(); break;
    case "noReleases": title = "You're on the latest build"; detail = "No newer release has been published yet."; controls = check(); break;
    case "available": title = `Lidless ${u.release.version} is available`; detail = `You have ${v}.`; controls = `<button class="btn" data-action="link" data-url="${escape(u.release.pageUrl)}">Release Notes</button><button class="btn primary" data-action="download">Download</button>`; break;
    case "downloading": title = `Downloading Lidless ${u.release.version}…`; detail = "Saving the installer to your Downloads folder."; controls = '<span class="spinner"></span>'; break;
    case "downloaded": title = `Lidless ${u.release.version} downloaded`; detail = "Quit Lidless, run the installer, then open Lidless again."; controls = '<button class="btn" data-action="reveal">Show in folder</button>'; break;
    case "failed": title = "Couldn't check for updates"; detail = u.message; controls = check(); break;
    default: title = `Lidless ${v}`; detail = "Check GitHub for a newer version."; controls = check();
  }
  function check() { return '<button class="btn" data-action="check-updates">Check Now</button>'; }
  return `<div class="page compact">
    <div class="about-head"><img src="brand.png" alt=""><div><h1>Lidless</h1><div class="v">Version ${escape(v)}</div><div class="tag">Close the lid. Your agent keeps working.</div></div></div>
    <div class="section"><h2>Updates</h2><div class="card">
      <div class="update-row"><div class="main"><div class="t">${escape(title)}</div><div class="s">${escape(detail)}</div></div><div class="button-row">${controls}</div></div>
      ${HAIR}
      ${toggle("Check for updates automatically", "checkForUpdates", snap.config.checkForUpdates)}
    </div></div>
    <div class="section"><h2>Links</h2><div class="card">
      ${link("GitHub", "Source code, issues and releases", "https://github.com/manasdutta04/lidless")}${HAIR}
      ${link("Report an issue", "Tell us what went wrong", "https://github.com/manasdutta04/lidless/issues/new")}${HAIR}
      ${link("All releases", "Release notes and downloads", "https://github.com/manasdutta04/lidless/releases")}
    </div></div>
    <div class="fine">Free and open source under the MIT License. No accounts, no telemetry. The only network request Lidless makes is the update check above.</div>
  </div>`;
}

function link(title, detail, url) {
  return `<button class="link-row" data-action="link" data-url="${url}"><div class="main"><div class="t">${title}</div><div class="s">${detail}</div></div>${icon("arrowUpRight")}</button>`;
}

// MARK: Wiring

function paint() {
  const snap = state.snap;
  if (!snap) return;
  render(sidebar, sidebarView(snap));
  const page = { overview, history: historyPage, settings: settingsPage, setup: setupPage, about: aboutPage }[ui.page] || overview;
  render(content, page(snap));
}

async function reloadHistory() {
  const [stats, history] = await Promise.all([invoke("get_stats"), invoke("get_history")]);
  ui.stats = stats;
  ui.history = history;
  paint();
}

function navigate(page) {
  if (!PAGES.some(([id]) => id === page)) page = "overview";
  ui.page = page;
  content.scrollTop = 0;
  paint();
}

async function saveConfig(key, value) {
  const config = { ...state.snap.config, [key]: value };
  state.snap = { ...state.snap, config };
  paint();
  try { await invoke("set_config", { config }); } catch (e) { console.error(e); }
}

const handlers = {
  nav: (el) => navigate(el.dataset.page),
  panel: () => invoke("open_panel"),
  setup: () => invoke("setup"),
  uninstall: () => { if (confirm("Remove the sleep permission and the recovery helper? Lidless will not be able to keep this computer awake until you set it up again.")) invoke("uninstall"); },
  log: () => invoke("open_log"),
  link: (el) => invoke("open_url", { url: el.dataset.url }),
  "check-updates": () => invoke("check_updates"),
  download: () => invoke("download_update"),
  reveal: () => invoke("reveal_download"),
  "next-tip": () => { ui.tipIndex += 1; paint(); },
  "tip-index": (el) => { ui.tipIndex = Number(el.dataset.index); paint(); },
  tip: async (el) => {
    switch (el.dataset.kind) {
      case "panel": invoke("open_panel"); break;
      case "settings": navigate("settings"); break;
      case "link": invoke("open_url", { url: el.dataset.url }); break;
      case "copy": if (await copyText(el.dataset.text)) { ui.copiedAt = Date.now(); paint(); } break;
    }
  },
  step: (el) => {
    const key = el.dataset.key;
    const cur = Number(state.snap.config[key]);
    const next = Math.min(Number(el.dataset.max), Math.max(Number(el.dataset.min), cur + Number(el.dataset.delta)));
    if (next !== cur) saveConfig(key, next);
  },
  config: (el) => saveConfig(el.dataset.key, el.checked),
  autostart: (el) => invoke("set_autostart", { enabled: el.checked }).catch((e) => console.error(e)),
};
bindActions(sidebar, handlers);
bindActions(content, handlers);

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") invoke("hide_window");
});

listen("navigate", (e) => navigate(e.payload));

setInterval(() => { ui.tipIndex += 1; if (ui.page === "overview") paint(); }, 12000);

onState((snap) => {
  if (snap.historyVersion !== ui.historyVersion) {
    ui.historyVersion = snap.historyVersion;
    reloadHistory();
  }
  paint();
});
