// Soundcheck's browser extension, in the background: keeps Soundcheck told which tabs are
// playing or on a call (with their titles and icons), and carries out what Soundcheck asks for
// each tab (its level, mute, and lowering it while another tab is on a call).
//
// Chrome-based browsers (Dia, Chrome, Edge, Brave, Arc) talk to Soundcheck through a native
// messaging port that stays open; Safari asks Soundcheck's Safari extension now and then.
const api = globalThis.browser ?? globalThis.chrome;
const isSafari = api.runtime.getURL("").startsWith("safari-web-extension:");
const HOST = "com.mylesdean.soundcheck";

// Per tab: frames on a call or playing, the icon, and what Soundcheck has set.
const tabs = new Map();
const tabState = (id) => {
  if (!tabs.has(id)) tabs.set(id, { calls: new Set(), playing: new Set(), iconHref: null, lastHeard: 0, level: 1, duck: 1, muted: false });
  return tabs.get(id);
};
const iconsSent = new Map(); // tab ID → the icon URL Soundcheck has
const iconData = new Map(); // icon URL → data: URL
const RECENT = 30_000; // a tab that played in the last 30 s stays listed

// MARK: Talking to Soundcheck

let port = null;
let nextPoll = 1;
let connected = false;

const handle = (reply) => {
  if (!reply || typeof reply !== "object") return;
  connected = true;
  if (reply.resend) { iconsSent.clear(); schedule(); }
  for (const command of reply.commands ?? []) apply(command);
  if (typeof reply.poll === "number") nextPoll = reply.poll;
};

const connect = () => {
  if (isSafari || port) return;
  try {
    port = api.runtime.connectNative(HOST);
  } catch (_) { port = null; setTimeout(connect, 10_000); return; }
  port.onMessage.addListener(handle);
  port.onDisconnect.addListener(() => {
    port = null;
    connected = false;
    setTimeout(connect, 10_000); // Soundcheck isn't installed yet, or its helper ended
  });
  iconsSent.clear();
  schedule();
};

const send = async (message) => {
  if (isSafari) {
    try { handle(await api.runtime.sendNativeMessage(HOST, message)); } catch (_) { connected = false; }
  } else if (port) {
    try { port.postMessage(message); } catch (_) {}
  }
};

// MARK: What's playing

const hostOf = (url) => {
  try { return new URL(url).hostname.replace(/^www\./, ""); } catch (_) { return ""; }
};

const toDataURL = async (url) => {
  if (!url) return null;
  if (url.startsWith("data:")) return url;
  if (iconData.has(url)) return iconData.get(url);
  try {
    const response = await fetch(url);
    if (!response.ok) return null;
    const type = response.headers.get("content-type") || "image/png";
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length > 200_000) return null;
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    const data = `data:${type};base64,${btoa(binary)}`;
    iconData.set(url, data);
    return data;
  } catch (_) { return null; }
};

// Chrome-based browsers hand over their own copy of a page's icon; Safari's comes from the page.
const iconURL = (tab, state) => {
  if (!isSafari && tab.url && /^https?:/.test(tab.url)) {
    return api.runtime.getURL(`/_favicon/?pageUrl=${encodeURIComponent(tab.url)}&size=32`);
  }
  return tab.favIconUrl || state.iconHref || (tab.url && /^https?:/.test(tab.url) ? new URL("/favicon.ico", tab.url).href : null);
};

const snapshot = async () => {
  const now = Date.now();
  const list = [];
  for (const tab of await api.tabs.query({})) {
    const state = tabState(tab.id);
    const playing = !!tab.audible || state.playing.size > 0;
    if (playing) state.lastHeard = now;
    const call = state.calls.size > 0;
    const muted = !!(tab.mutedInfo && tab.mutedInfo.muted) || state.muted;
    const recent = now - state.lastHeard < RECENT;
    if (!playing && !call && !recent && state.level === 1 && !muted) continue;
    const entry = { id: tab.id, title: tab.title || hostOf(tab.url), host: hostOf(tab.url), playing, call, muted };
    const url = iconURL(tab, state);
    if (url && iconsSent.get(tab.id) !== url) {
      const data = await toDataURL(url);
      if (data) { entry.icon = data; iconsSent.set(tab.id, url); }
    }
    list.push(entry);
  }
  return list;
};

let timer = null;
const schedule = () => {
  if (timer) return;
  timer = setTimeout(async () => {
    timer = null;
    await send({ type: "state", tabs: await snapshot() });
  }, 150);
};

// MARK: Doing what Soundcheck asks

const pushGain = (id, seconds = 0) => {
  const state = tabState(id);
  // Safari can't mute a tab from an extension, so muted is a level of zero there.
  const gain = isSafari && state.muted ? 0 : state.level * state.duck;
  try { api.tabs.sendMessage(id, { kind: "gain", gain, seconds })?.catch?.(() => {}); } catch (_) {}
};

const apply = (command) => {
  const id = command.tab;
  if (typeof id !== "number") return;
  const state = tabState(id);
  switch (command.type) {
    case "level":
      state.level = Math.min(Math.max(Number(command.gain), 0), 1);
      pushGain(id);
      break;
    case "duck":
      state.duck = Math.min(Math.max(Number(command.gain), 0), 1);
      pushGain(id, Number(command.seconds) || 0);
      break;
    case "mute":
      state.muted = !!command.muted;
      if (isSafari) pushGain(id, 0.15);
      else { try { api.tabs.update(id, { muted: state.muted }); } catch (_) {} }
      break;
  }
  schedule();
};

// MARK: Listening

api.runtime.onMessage.addListener((message, sender) => {
  const tab = sender && sender.tab;
  if (!tab || typeof tab.id !== "number") return;
  const state = tabState(tab.id);
  const frame = sender.frameId ?? 0;
  if (message.kind === "call") { message.active ? state.calls.add(frame) : state.calls.delete(frame); schedule(); }
  if (message.kind === "playing") { message.active ? state.playing.add(frame) : state.playing.delete(frame); schedule(); }
  if (message.kind === "icon") { if (state.iconHref !== message.href) { state.iconHref = message.href; iconsSent.delete(tab.id); schedule(); } }
  // A page (re)loaded: give it its level again.
  if (message.kind === "ready" && (state.level !== 1 || state.duck !== 1 || (isSafari && state.muted))) pushGain(tab.id);
});

api.tabs.onUpdated.addListener((id, change) => {
  if ("audible" in change || "title" in change || "mutedInfo" in change || "favIconUrl" in change) schedule();
  if (change.status === "loading") { const state = tabState(id); state.calls.clear(); state.playing.clear(); }
});
api.tabs.onRemoved.addListener((id) => { tabs.delete(id); iconsSent.delete(id); schedule(); });

// Checking in keeps Soundcheck's list fresh (and, in Safari, is how its requests arrive).
const tick = async () => {
  if (isSafari) {
    await send({ type: "poll" });
    setTimeout(tick, Math.max(nextPoll, 0.1) * 1000);
  } else {
    if (port) send({ type: "poll" });
    setTimeout(tick, 3000);
  }
};

connect();
schedule();
tick();
