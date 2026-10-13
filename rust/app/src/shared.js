// Shared by both pages: the Tauri bridge, formatting, icons and a small DOM
// morph so re-rendering once a second keeps focus, typed text and hover.

const tauri = window.__TAURI__;
export const invoke = (cmd, args) => tauri.core.invoke(cmd, args);
export const listen = (name, cb) => tauri.event.listen(name, cb);

export const state = { snap: null };

/// Delivers the current snapshot now and after every `state` event.
export async function onState(cb) {
  await listen("state", (e) => { state.snap = e.payload; cb(e.payload); });
  const s = await invoke("get_status");
  if (!state.snap) { state.snap = s; cb(s); }
}

// MARK: Derived state

export function session(snap) { return snap?.status?.session || null; }
export function isActive(snap) { return !!snap?.status?.active; }
export function isReady(snap) { return !!snap?.readiness && snap.readiness.privilege && snap.readiness.recoveryArmed; }
export function needsSetup(snap) { return !!snap?.readiness && !isReady(snap); }
export function isWarm(level) { return level === "fair" || level === "serious" || level === "critical"; }

export function remaining(snap) {
  const s = session(snap);
  if (!s) return 0;
  return Math.max(0, (Date.parse(s.endsAt) - Date.now()) / 1000);
}

export function remainingFraction(snap) {
  const s = session(snap);
  if (!s) return 0;
  const total = (Date.parse(s.endsAt) - Date.parse(s.startedAt)) / 1000;
  return total > 0 ? Math.min(1, Math.max(0, remaining(snap) / total)) : 0;
}

export const THERMAL_WARNING = {
  fair: "Your computer is already warm. Closing the lid holds in more heat, so keep it on a hard, open surface.",
  serious: "Your computer is running hot. Closing the lid holds in more heat. Make sure it has open air around it, and consider waiting until it cools down.",
  critical: "Your computer is too hot to keep running with the lid closed. Let it cool down first.",
};

export const END_SUMMARY = {
  expired: "Time ran out.",
  stopped: "Stopped.",
  quit: "Lidless quit.",
  commandExited: "The wrapped command finished.",
  batteryFloor: "Battery fell below the safety floor.",
  thermalFloor: "The computer got too hot (critical thermal state).",
  batteryUnreadable: "The battery level could not be read twice in a row.",
  verificationFailed: "The system turned closed-lid sleep back on.",
  ownerTerminated: "The Lidless session process was terminated.",
  rebooted: "The computer restarted during the session.",
  ownerLost: "The Lidless process that owned the session stopped unexpectedly.",
  startFailed: "The session could not start.",
};

// MARK: Formatting

/// "1:02:03" or "2d 3:04:05".
export function clock(seconds) {
  let s = Math.max(0, Math.ceil(seconds));
  const d = Math.floor(s / 86400); s %= 86400;
  const h = Math.floor(s / 3600); s %= 3600;
  const m = Math.floor(s / 60); s %= 60;
  const hms = `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return d > 0 ? `${d}d ${hms}` : hms;
}

/// "1d 2h", "1h 30m", "45m", "30s".
export function fmtDuration(seconds) {
  let s = Math.max(0, Math.round(seconds));
  if (s === 0) return "0s";
  const d = Math.floor(s / 86400); s %= 86400;
  const h = Math.floor(s / 3600); s %= 3600;
  const m = Math.floor(s / 60); s %= 60;
  const parts = [];
  if (d) parts.push(`${d}d`);
  if (h) parts.push(`${h}h`);
  if (m) parts.push(`${m}m`);
  if (s && !d && !h) parts.push(`${s}s`);
  return parts.join(" ") || "0s";
}

const timeFmt = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
const dateTimeFmt = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
const dateFmt = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" });
const shortDateFmt = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });
const weekdayFmt = new Intl.DateTimeFormat(undefined, { weekday: "short" });
const hourFmt = new Intl.DateTimeFormat(undefined, { hour: "numeric" });
const relFmt = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

export function fmtTime(d) { return timeFmt.format(d); }
export function fmtDate(d) { return dateFmt.format(d); }
export function fmtShortDate(d) { return shortDateFmt.format(d); }
export function fmtWeekday(d) { return weekdayFmt.format(d); }
export function fmtHour(h) { const d = new Date(); d.setHours(h, 0, 0, 0); return hourFmt.format(d); }

export function isToday(d) {
  const n = new Date();
  return d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate();
}

/// "Until 17:30" today, "Until Oct 14, 09:00" otherwise.
export function fmtUntil(d) { return isToday(d) ? fmtTime(d) : dateTimeFmt.format(d); }

/// "2 hours ago", "yesterday", "in 3 minutes".
export function fmtRelative(d) {
  const diff = (d.getTime() - Date.now()) / 1000;
  const abs = Math.abs(diff);
  if (abs < 60) return relFmt.format(Math.round(diff), "second");
  if (abs < 3600) return relFmt.format(Math.round(diff / 60), "minute");
  if (abs < 86400) return relFmt.format(Math.round(diff / 3600), "hour");
  if (abs < 86400 * 30) return relFmt.format(Math.round(diff / 86400), "day");
  return relFmt.format(Math.round(diff / (86400 * 30)), "month");
}

export function capitalize(s) { return s ? s[0].toUpperCase() + s.slice(1) : s; }

export function escape(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

export function greeting() {
  const h = new Date().getHours();
  if (h >= 5 && h < 12) return "Good morning";
  if (h >= 12 && h < 17) return "Good afternoon";
  return "Good evening";
}

// MARK: Status helpers

export function batteryText(p) {
  if (!p?.hasBattery) return "Power adapter";
  const level = p.percent == null ? "Unknown" : `${p.percent}%`;
  return p.onBattery ? level : `${level}, charging`;
}
export function batteryLow(p) { return !!p?.hasBattery && p.onBattery && (p.percent ?? 100) < 20; }
export function batteryIcon(p) {
  if (!p?.hasBattery) return "plug";
  if (!p.onBattery) return "bolt";
  return "battery";
}

export function agentsText(agents) {
  if (!agents?.length) return "None running";
  const counts = {};
  for (const a of agents) counts[a.name] = (counts[a.name] || 0) + 1;
  return Object.keys(counts).sort().map((n) => (counts[n] > 1 ? `${n} ×${counts[n]}` : n)).join(", ");
}

// MARK: Icons (thin monochrome line icons, 24-unit grid)

const PATHS = {
  battery: '<rect x="2.5" y="7.5" width="16" height="9" rx="2"/><path d="M21.5 10.5v3"/>',
  batteryLevel: '<rect x="2.5" y="7.5" width="16" height="9" rx="2"/><path d="M21.5 10.5v3"/><rect class="lvl" x="4.5" y="9.5" width="12" height="5" rx="1" fill="currentColor" stroke="none"/>',
  bolt: '<path d="M13 2 4.5 13.5H11l-1 8.5 8.5-11.5H13z"/>',
  plug: '<path d="M9 2v5M15 2v5M6 7h12l-1 5a5 5 0 0 1-10 0zM12 17v5"/>',
  laptop: '<rect x="4" y="5" width="16" height="11" rx="1.5"/><path d="M2 19h20"/>',
  wifi: '<path d="M2 8.5a15 15 0 0 1 20 0M5.5 12a10 10 0 0 1 13 0M9 15.5a5 5 0 0 1 6 0"/><circle cx="12" cy="19" r="0.8" fill="currentColor"/>',
  wifiOff: '<path d="M2 8.5a15 15 0 0 1 20 0M5.5 12a10 10 0 0 1 13 0M9 15.5a5 5 0 0 1 6 0M3 3l18 18"/><circle cx="12" cy="19" r="0.8" fill="currentColor"/>',
  terminal: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/>',
  thermometer: '<path d="M10 14.5V5a2 2 0 1 1 4 0v9.5a3.5 3.5 0 1 1-4 0z"/><path d="M12 10v6"/>',
  thermometerHigh: '<path d="M10 14.5V5a2 2 0 1 1 4 0v9.5a3.5 3.5 0 1 1-4 0z"/><path d="M12 7v9" stroke-width="2.5"/>',
  leaf: '<path d="M4 20c0-9 5-14 16-16-1 11-6 16-15 16"/><path d="M4 20c3-5 7-8 11-11"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1"/>',
  help: '<circle cx="12" cy="12" r="9.5"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.4-1 1-1 1.7"/><circle cx="12" cy="17" r="0.7" fill="currentColor"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  alertCircle: '<circle cx="12" cy="12" r="9.5"/><path d="M12 7.5v5.5"/><circle cx="12" cy="16.5" r="0.7" fill="currentColor"/>',
  alertTriangle: '<path d="M12 3.5 2.5 20h19z"/><path d="M12 9.5v5"/><circle cx="12" cy="17.3" r="0.7" fill="currentColor"/>',
  checkCircle: '<circle cx="12" cy="12" r="9.5"/><path d="m8 12.5 2.5 2.5L16 9.5"/>',
  circle: '<circle cx="12" cy="12" r="9.5"/>',
  downloadCircle: '<circle cx="12" cy="12" r="9.5"/><path d="M12 7v9M8.5 12.5 12 16l3.5-3.5"/>',
  arrowUpRight: '<path d="M7 17 17 7M9 7h8v8"/>',
  timer: '<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2.5 1.5M10 2.5h4"/>',
  wind: '<path d="M3 8h11a2.5 2.5 0 1 0-2.5-2.5M3 12h16a2.5 2.5 0 1 1-2.5 2.5M3 16h9a2.5 2.5 0 1 1-2.5 2.5"/>',
  micOff: '<path d="M9 5a3 3 0 0 1 6 0v6M9 9v2a3 3 0 0 0 5 2.2M6 11a6 6 0 0 0 9.5 4.9M18 11a6 6 0 0 1-.5 2.4M12 17v4M3 3l18 18"/>',
  code: '<path d="m8 8-4 4 4 4M16 8l4 4-4 4M13.5 5l-3 14"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
  grid: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.5"/>',
  clock: '<circle cx="12" cy="12" r="9.5"/><path d="M12 7v5l3 2"/>',
  sliders: '<path d="M4 7h10M18 7h2M4 17h4M12 17h8M4 12h16"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
  shield: '<path d="M12 3 4.5 6v6c0 4.5 3 7.5 7.5 9 4.5-1.5 7.5-4.5 7.5-9V6z"/><path d="m9 12 2 2 4-4"/>',
  info: '<circle cx="12" cy="12" r="9.5"/><path d="M12 11v5.5"/><circle cx="12" cy="8" r="0.7" fill="currentColor"/>',
  minus: '<path d="M6 12h12"/>',
  plus: '<path d="M12 6v12M6 12h12"/>',
  download: '<path d="M12 4v11M7.5 11.5 12 16l4.5-4.5M4 20h16"/>',
  tray: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8"/>',
};

export function icon(name, extra = "") {
  const body = PATHS[name] || PATHS.circle;
  return `<svg class="icon ${extra}" viewBox="0 0 24 24" aria-hidden="true">${body}</svg>`;
}

/// Battery icon with a fill level.
export function batteryGlyph(p) {
  if (!p?.hasBattery) return icon("plug");
  if (!p.onBattery) return icon("bolt");
  const pct = Math.max(0, Math.min(100, p.percent ?? 0));
  const w = Math.max(1, Math.round(12 * pct / 100));
  return `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="7.5" width="16" height="9" rx="2"/><path d="M21.5 10.5v3"/><rect x="4.5" y="9.5" width="${w}" height="5" rx="1" fill="currentColor" stroke="none"/></svg>`;
}

// MARK: DOM morph

/// Updates `from` in place to match `to` (both elements), keeping nodes
/// where the tag matches so inputs, focus and hover survive a re-render.
export function morph(from, to) {
  if (from.nodeType === Node.TEXT_NODE) {
    if (from.nodeValue !== to.nodeValue) from.nodeValue = to.nodeValue;
    return;
  }
  // Attributes.
  for (const a of Array.from(from.attributes)) {
    if (!to.hasAttribute(a.name)) from.removeAttribute(a.name);
  }
  for (const a of Array.from(to.attributes)) {
    if (from.getAttribute(a.name) !== a.value) from.setAttribute(a.name, a.value);
  }
  if (from.tagName === "INPUT") {
    if (from.type === "checkbox") {
      if (from.checked !== to.checked) from.checked = to.checked;
    } else if (document.activeElement !== from && from.value !== to.value) {
      from.value = to.value;
    }
    if (from.disabled !== to.disabled) from.disabled = to.disabled;
  }
  if (from.tagName === "BUTTON" && from.disabled !== to.disabled) from.disabled = to.disabled;
  // Children.
  const a = Array.from(from.childNodes);
  const b = Array.from(to.childNodes);
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const x = a[i], y = b[i];
    if (!y) { from.removeChild(x); continue; }
    if (!x) { from.appendChild(y.cloneNode(true)); continue; }
    if (x.nodeType !== y.nodeType || (x.nodeType === Node.ELEMENT_NODE && (x.tagName !== y.tagName || x.getAttribute("data-key") !== y.getAttribute("data-key")))) {
      from.replaceChild(y.cloneNode(true), x);
      continue;
    }
    morph(x, y);
  }
}

/// Renders HTML into `root` through `morph`.
export function render(root, html) {
  const tmp = document.createElement(root.tagName);
  for (const a of root.attributes) tmp.setAttribute(a.name, a.value);
  tmp.innerHTML = html;
  morph(root, tmp);
}

/// Event delegation: `data-action` on any element, handlers by name.
export function bindActions(root, handlers) {
  root.addEventListener("click", (e) => {
    const el = e.target.closest("[data-action]");
    if (!el || el.disabled) return;
    const h = handlers[el.dataset.action];
    if (h) h(el, e);
  });
  root.addEventListener("change", (e) => {
    const el = e.target.closest("[data-change]");
    if (!el) return;
    const h = handlers[el.dataset.change];
    if (h) h(el, e);
  });
}

export async function copyText(text) {
  try { await navigator.clipboard.writeText(text); return true; } catch (_) {}
  const ta = document.createElement("textarea");
  ta.value = text;
  document.body.appendChild(ta);
  ta.select();
  const ok = document.execCommand("copy");
  ta.remove();
  return ok;
}
