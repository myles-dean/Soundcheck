// Soundcheck, in the extension's own world in each frame: passes messages between the page
// script (page.js) and the extension's background, and in Safari puts page.js into the page
// (Chrome-based browsers run it there themselves, from the manifest).
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  const isSafari = api.runtime.getURL("").startsWith("safari-web-extension:");

  if (isSafari && !document.documentElement.hasAttribute("data-soundcheck")) {
    document.documentElement.setAttribute("data-soundcheck", "");
    const script = document.createElement("script");
    script.src = api.runtime.getURL("page.js");
    script.onload = () => script.remove();
    (document.head || document.documentElement).appendChild(script);
  }

  const send = (message) => {
    try { api.runtime.sendMessage(message)?.catch?.(() => {}); } catch (_) {}
  };

  window.addEventListener("message", (event) => {
    if (event.source !== window || !event.data || event.data.source !== "soundcheck-page") return;
    const { type, active } = event.data;
    if (type === "call" || type === "playing") send({ kind: type, active: !!active });
    // A page that (re)loaded asks for its level again.
    if (type === "ready") send({ kind: "ready" });
  });

  api.runtime.onMessage.addListener((message) => {
    if (message && message.kind === "gain") {
      window.postMessage({ source: "soundcheck-ext", type: "gain", gain: message.gain, seconds: message.seconds || 0 }, "*");
    }
  });

  // The page's icon, for browsers that don't hand it over (the top frame only).
  if (window === window.top) {
    const findIcon = () => {
      const link = [...document.querySelectorAll("link[rel~='icon'], link[rel='shortcut icon'], link[rel='apple-touch-icon']")]
        .find((element) => element.href);
      return link ? link.href : new URL("/favicon.ico", location.href).href;
    };
    const reportIcon = () => send({ kind: "icon", href: findIcon() });
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", reportIcon, { once: true });
    else reportIcon();
  }
})();
