// Soundcheck, in the page itself (the page's own JavaScript world, every frame).
//
// Two jobs:
//  - Calls: notices when the page takes a microphone (getUserMedia with audio) and when it lets
//    go, so Soundcheck can lower everything else while a Meet, Zoom or Discord tab is on a call.
//  - Volume: plays the page's sound at the level Soundcheck asks for, by scaling every <audio>
//    and <video> element's volume and putting a gain in front of every Web Audio output. The
//    page's own volume controls keep working; Soundcheck's level multiplies them.
//
// It talks to the extension's content script with window.postMessage (source "soundcheck-page"
// out, "soundcheck-ext" in).
(() => {
  if (window.__soundcheckPage) return;
  window.__soundcheckPage = true;

  const post = (message) => window.postMessage({ source: "soundcheck-page", ...message }, "*");

  // MARK: Calls

  const liveTracks = new Set();
  let wasOnCall = false;
  const reportCall = () => {
    for (const track of liveTracks) if (track.readyState !== "live") liveTracks.delete(track);
    const onCall = liveTracks.size > 0;
    if (onCall !== wasOnCall) {
      wasOnCall = onCall;
      post({ type: "call", active: onCall });
    }
  };
  const watchStream = (stream) => {
    try {
      for (const track of stream.getAudioTracks()) {
        liveTracks.add(track);
        track.addEventListener("ended", reportCall);
        const stop = track.stop.bind(track);
        track.stop = () => { stop(); reportCall(); };
      }
    } catch (_) {}
    reportCall();
    return stream;
  };
  const devices = navigator.mediaDevices;
  if (devices && devices.getUserMedia) {
    const getUserMedia = devices.getUserMedia.bind(devices);
    devices.getUserMedia = (constraints) => getUserMedia(constraints).then(watchStream);
  }
  // Tracks can end without an event (the page drops them); look now and then.
  setInterval(reportCall, 2000);

  // MARK: Volume

  let gain = 1; // what's applied now
  let ramp = null;
  const volumeOf = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "volume");
  const pageVolumes = new WeakMap(); // the volume the page set (or the element's own)
  const elements = new Set(); // WeakRefs to media elements we've seen
  const clamp = (value) => Math.min(Math.max(value, 0), 1);

  const pageVolume = (element) => {
    if (!pageVolumes.has(element)) pageVolumes.set(element, volumeOf.get.call(element));
    return pageVolumes.get(element);
  };
  const applyTo = (element) => {
    try { volumeOf.set.call(element, clamp(pageVolume(element) * gain)); } catch (_) {}
  };
  const remember = (element) => {
    if (!(element instanceof HTMLMediaElement)) return;
    for (const ref of elements) if (ref.deref() === element) { applyTo(element); return; }
    elements.add(new WeakRef(element));
    applyTo(element);
  };

  // The page reads and writes its own volume; the element plays it times Soundcheck's level.
  Object.defineProperty(HTMLMediaElement.prototype, "volume", {
    configurable: true,
    enumerable: true,
    get() { return pageVolume(this); },
    set(value) {
      volumeOf.set.call(this, value); // let the browser check it (it throws for out-of-range)
      pageVolumes.set(this, value);
      remember(this);
    },
  });
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    remember(this);
    return play.apply(this, args);
  };
  document.addEventListener("play", (event) => remember(event.target), true);

  // Web Audio: whatever connects to a context's speakers goes through a gain of ours instead.
  const contexts = new Set(); // WeakRefs to AudioContexts with a gain
  const gainOf = new WeakMap();
  const connect = AudioNode.prototype.connect;
  const disconnect = AudioNode.prototype.disconnect;
  const createGain = BaseAudioContext.prototype.createGain;
  const gainFor = (context) => {
    let node = gainOf.get(context);
    if (!node) {
      node = createGain.call(context);
      node.gain.value = gain;
      connect.call(node, context.destination);
      gainOf.set(context, node);
      contexts.add(new WeakRef(context));
    }
    return node;
  };
  const isSpeakers = (node) =>
    typeof AudioDestinationNode !== "undefined" && node instanceof AudioDestinationNode &&
    typeof AudioContext !== "undefined" && node.context instanceof AudioContext;
  AudioNode.prototype.connect = function (destination, ...rest) {
    if (isSpeakers(destination)) {
      connect.call(this, gainFor(destination.context), ...rest);
      return destination;
    }
    return connect.call(this, destination, ...rest);
  };
  AudioNode.prototype.disconnect = function (destination, ...rest) {
    if (destination !== undefined && isSpeakers(destination)) {
      return disconnect.call(this, gainFor(destination.context), ...rest);
    }
    return disconnect.call(this, destination, ...rest);
  };

  const applyAll = () => {
    for (const ref of elements) {
      const element = ref.deref();
      if (element) applyTo(element); else elements.delete(ref);
    }
    for (const element of document.querySelectorAll("audio, video")) remember(element);
    for (const ref of contexts) {
      const context = ref.deref();
      if (!context) { contexts.delete(ref); continue; }
      const node = gainOf.get(context);
      try { node.gain.setValueAtTime(gain, context.currentTime); } catch (_) { node.gain.value = gain; }
    }
  };

  // Changes fade, evenly in decibels (silence counts as -60 dB until the very end).
  const setGain = (target, seconds) => {
    if (ramp) { clearInterval(ramp); ramp = null; }
    target = clamp(target);
    if (!(seconds > 0) || Math.abs(target - gain) < 0.001) { gain = target; applyAll(); return; }
    const toDecibels = (value) => Math.max(20 * Math.log10(Math.max(value, 1e-6)), -60);
    const from = toDecibels(gain), to = toDecibels(target), began = performance.now();
    ramp = setInterval(() => {
      const t = Math.min((performance.now() - began) / (seconds * 1000), 1);
      const eased = t * t * (3 - 2 * t);
      gain = t >= 1 ? target : Math.pow(10, (from + (to - from) * eased) / 20);
      applyAll();
      if (t >= 1) { clearInterval(ramp); ramp = null; }
    }, 30);
  };

  // MARK: Playing (for browsers that don't say which tabs make sound)

  let wasPlaying = false;
  const reportPlaying = () => {
    let playing = false;
    for (const ref of elements) {
      const element = ref.deref();
      if (element && !element.paused && !element.muted && element.readyState > 2) { playing = true; break; }
    }
    if (!playing) {
      for (const ref of contexts) {
        const context = ref.deref();
        if (context && context.state === "running") { playing = true; break; }
      }
    }
    if (playing !== wasPlaying) {
      wasPlaying = playing;
      post({ type: "playing", active: playing });
    }
  };
  for (const name of ["playing", "pause", "ended", "volumechange", "emptied"]) {
    document.addEventListener(name, (event) => { remember(event.target); setTimeout(reportPlaying, 50); }, true);
  }
  setInterval(reportPlaying, 1500);

  window.addEventListener("message", (event) => {
    if (event.source !== window || !event.data || event.data.source !== "soundcheck-ext") return;
    if (event.data.type === "gain") setGain(Number(event.data.gain), Number(event.data.seconds) || 0);
  });
  post({ type: "ready" });
})();
