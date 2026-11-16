<p align="center">
  <img src="docs/icon.png" width="256" height="256" alt="Soundcheck app icon: three white mixer faders on a blue rounded square">
</p>

<h1 align="center">Soundcheck</h1>

<p align="center">
  <b>The Sound menu your Mac should have had.</b><br>
  Every speaker, app and microphone on your Mac, from one speaker in the menu bar: a volume and an EQ
  for each app, several speakers at once, AirPlay to HomePods in sync, and a microphone that mixes.<br>
  Free and open source, made for macOS 26 Tahoe.
</p>

<p align="center">
  <a href="https://github.com/myles-dean/Soundcheck/releases/latest/download/Soundcheck.dmg"><b>⬇︎ Download Soundcheck (DMG)</b></a>
  &nbsp;·&nbsp; <a href="#features">Features</a>
  &nbsp;·&nbsp; <a href="#what-makes-it-different">What makes it different</a>
  &nbsp;·&nbsp; <a href="#install">Install</a>
  &nbsp;·&nbsp; <a href="#faq">FAQ</a>
</p>

<p align="center">
  <img alt="macOS 26 Tahoe or later" src="https://img.shields.io/badge/macOS-26%20Tahoe%2B-111111?logo=apple&logoColor=white">
  <img alt="Written in Swift" src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-f05138?logo=swift&logoColor=white">
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-34c759">
  <a href="https://github.com/myles-dean/Soundcheck/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/myles-dean/Soundcheck?label=release"></a>
</p>

<p align="center">
  <a href="https://ko-fi.com/mylesdean_"><img alt="Buy me a coffee on Ko-fi" src="https://img.shields.io/badge/Buy%20me%20a%20coffee-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white"></a>
</p>

---

**Soundcheck** replaces the Sound icon in your Mac's menu bar. Apple's Sound menu plays through one
speaker at a time, has one volume for everything, and leaves your microphone in System Settings.
Soundcheck puts all of it in one Liquid Glass panel that looks and moves like Control Center:

- **Speakers.** Play through as many speakers as you like at once, each at its own volume, with its
  own EQ, balance and mono.
- **Apps.** A volume for every app that's making sound, with mute, boost, an EQ, effects and its own
  speakers.
- **AirPlay.** Stream to HomePods and other AirPlay speakers, in sync with your Mac's own speakers.
- **Mics.** One virtual microphone, *Soundcheck Mic*, that every app uses. Pick the real mic once, in
  Soundcheck, or mix several mics and apps into it, give each mic an EQ and effects, and hear yourself
  in your headphones.
- **Shortcuts and Siri.** Switch speakers, set an app's volume or apply a saved setup from a shortcut.
- **The volume keys.** Your keyboard's volume keys move whichever group you pick (speakers, apps or
  mics), with an Apple-style volume pill.

Its speaker icon only appears in the menu bar while something is playing or a mic is listening, so
most of the time it isn't there at all.

## What makes it different

There are good sound apps for the Mac, but each covers one piece. Soundcheck puts the whole set
in one free app:

- **Everything in one place, for free.** The closest app is Rogue Amoeba's SoundSource ($49), which
  also has per-app volume, speaker groups and AirPlay. For a virtual mic that mixes mics and apps you'd
  add their Loopback ($99). Soundcheck does all of it, free and open source under the MIT license.
- **AirPlay that stays in sync.** Soundcheck has its own AirPlay 2 sender. It follows the HomePods'
  network clock (PTP) the way macOS does, so several AirPlay speakers and your Mac's own speakers play
  as one. From Control Center, macOS itself
  [can't play to several AirPlay speakers](https://support.apple.com/105068) (only the Music app can),
  and the free per-app volume apps, FineTune and Background Music, don't send to AirPlay at all.
- **A microphone you set once.** Soundcheck Mic is always your Mac's microphone while Soundcheck runs,
  so you switch mics in the menu bar and every app follows. No more digging through each app's audio
  settings, and you can mix in more mics and apps whenever you like.
- **Volumes that move together, sensibly.** Groups keep their balance: the main bar moves every
  speaker (or app, or mic) by the same amount, the volume keys can go past full until everything is at
  full, and nothing forgets its level when you unplug it. macOS's own Multi-Output Device plays through
  several speakers, but the volume keys and menu bar slider don't work with it.
- **An EQ wherever there's a volume bar.** Fill out a display's thin speakers, take the boom out of a
  MacBook's, bring a podcast's voices forward or warm up your mic: every speaker, app and mic has its
  own five-band EQ, named for what each band does rather than its frequency.
- **Effects for apps and mics.** Reverb, echo, a compressor, a limiter, pitch, distortion and voice
  isolation are built in, and any Audio Unit plug-in on your Mac works too.
- **Made for calls and streams.** Quiet Apps in Calls lowers or mutes everything else while an app
  uses the mic, Mute Mics has its own shortcut, you can see which apps are listening, and Hear
  Yourself plays your mic in your headphones.
- **Feels like part of macOS.** A Liquid Glass panel that opens like Control Center's menus, a volume
  pill styled like Apple's, and a speaker icon that only shows up when there's something to control.
- **No driver for app volumes.** Per-app volume, extra speakers and AirPlay use macOS's own process
  taps. The only thing Soundcheck installs is Soundcheck Mic, and only when you ask for it.

### How it compares

| | Soundcheck | SoundSource 6 | FineTune | Background Music |
| --- | :---: | :---: | :---: | :---: |
| Price | **Free** | $49 | Free | Free |
| Open source | ✓ MIT | — | ✓ GPL-3.0 | ✓ GPL-2.0 |
| A volume for each app | ✓ | ✓ | ✓ | ✓ |
| Send an app to its own speakers | ✓ | ✓ | ✓ | — |
| Several speakers at once, each with its own volume | ✓ | ✓ | ✓ | — |
| AirPlay speakers, in sync with the Mac's speakers | ✓ | ✓ | — | — |
| Virtual mic that mixes mics and apps | ✓ | — ¹ | — | — |
| Volume keys with their own volume pill | ✓ | ✓ | ✓ | — |
| Lower or mute apps during calls | ✓ | — | — | — ² |
| Saved setups | ✓ | ✓ | — ³ | — |
| Installs a system audio add-on for app volumes | No | Yes | No | Yes |
| EQ | ✓ | ✓ | ✓ | — |
| Audio effects (reverb, compressors, plug-ins) | ✓ ⁴ | ✓ | — | — |

— means the app doesn't offer it, as far as its own site and docs say (checked November 2026).
¹ Rogue Amoeba sells this separately as Loopback ($99).
² Background Music can pause your music player when other audio plays.
³ FineTune has EQ presets and remembers settings per device.
⁴ On apps and mics.

Soundcheck's EQ is a five-band one for every speaker, app and mic. Apps and mics can also have
effects: Soundcheck's own, or Audio Unit plug-ins.

## Features

### The panel

Click the speaker in the menu bar. At the top, **Sound** has a three-part switch:
**Speakers | Apps | Mics**. Whichever you choose is what the main volume bar and your keyboard's
volume keys control.

The main bar always shows the loudest one in the group, and moving it moves everything in the group by
the same amount. With one speaker at half and two at zero, dragging the main bar to full gives full,
half and half. Turn the volume keys up past full and the quieter ones keep rising until everything is
at full. The gaps between them are remembered.

### Speakers

- **Several at once is the default.** Open the Speakers list. Click a speaker to play only through
  it, or click its circle to add it alongside the others: your MacBook's speakers, a display, USB
  speakers, headphones, AirPlay speakers, all at once.
- **Mix** puts a volume bar under each speaker in use, right in the Speakers list. It turns on by
  itself when your speakers are at different volumes. Turn it off and they all even out at the
  loudest one.
- **Mute one speaker.** The speaker icon at the end of its bar shows how loud it is (no waves at
  zero, up to three); click it to mute just that speaker. It stays muted while you turn everything
  else up, until you click it again.
- **Displays and devices without a volume** (most HDMI and DisplayPort monitors) get a real volume
  anyway, and their volume keys work.
- **Switch to Headphones.** Plug in headphones and everything moves to them, their microphone too (AirPods, a headset), with a pill to say so. When they go, the speakers and the microphone from before come back.
- **Every speaker remembers its volume**, across unplugging, restarting and relaunching.
- **Every speaker in sync.** Bluetooth headphones, HDMI displays and USB speakers each take a
  different time to play what they're given. Soundcheck holds the quicker ones back by the
  difference each device reports, so ten speakers of different kinds play as one, AirPlay included.
- **Night Mode** (in Options) evens out loud and quiet parts for late-night films.
- **EQ, balance and mono.** The button to the left of a speaker's bar (the main bar when one speaker
  is playing, or its own bar with Mix on) opens its EQ: **Bass**, **Warmth**, **Voice**, **Clarity** and
  **Air**, each ±12 dB, with starting points like *More Bass*, *Less Boom* and *Clear Voices*. Below it
  are **Balance** and **Mono** (for one earbud, or a speaker in a corner). Double-click a band to set it
  flat again.
- **A volume limit for headphones.** Set the loudest a pair of headphones can go. The slider and the
  volume keys stop there, and so does anything else that tries to turn them up.
- **Hear Yourself.** Click the headphones button next to a speaker's EQ button (with Soundcheck Mic
  added) to hear Soundcheck Mic on that speaker, with its EQ, for streaming and podcasting.
  **Right-click** it to pick exactly which mics that speaker plays: the guest's mic only in the
  guest's headphones, both in yours, or a mic that isn't going into Soundcheck Mic at all, just for
  your ears. Turn it on for your headphones and it's on whenever they're in use. How loud you hear
  yourself is set in the Microphone section.

### AirPlay

The **AirPlay** row in the Speakers list opens to the AirPlay speakers on your network, with their
icons and names, like Apple's own picker. Its icon shows how many are playing.

- **Soundcheck streams to them itself.** It's a full AirPlay 2 sender built into the app, so
  AirPlay speakers are just more speakers: pick several, mix them with the Mac's own speakers, give
  each its own volume.
- **In sync, automatically.** Soundcheck keeps time the way a Mac does: it follows the HomePods'
  own network clock (PTP), plays every AirPlay speaker on the same timeline, and holds your Mac's
  speakers back by exactly as long as AirPlay takes. There's no delay slider to fiddle with.
- **HomePods connect with no code.** An Apple TV shows a code on screen the first time; type it into
  the AirPlay list and it's remembered (in your Keychain).
- **The volume goes both ways.** Turn a HomePod up on the speaker itself, with Siri or from your
  iPhone, and its bar in Soundcheck follows.
- **EQ, balance and mono** work on AirPlay speakers too, so a HomePod mini can get a little more bass.

### Apps

- **A volume for every app that's making sound.** The Apps list shows their icons stacked, with a
  "+3"-style count for the rest. Open it for a bar per app.
- **Click an app's icon, or the speaker at the end of its bar, to mute it.** The speaker shows how
  loud the app is, like the speakers' bars. If a muted app starts playing later, a pill tells you it's muted,
  once, so you're never left wondering why something's silent.
- **Boost Apps** lets a quiet app go up to 200%, past a tick at 100%, with a limiter so it doesn't
  crackle.
- **Split** sends an app to its own speakers: music on your desk speakers while a call stays on your
  headphones. AirPlay speakers that are on are in the list too, so a podcast can play on just the
  kitchen HomePod while everything else stays on the Mac.
- **An EQ for each app.** The button beside an app's bar opens its EQ, so you can add bass to your
  music without making a call boomy.
- **Effects for each app.** The **FX** button next to an app's EQ adds up to four effects after it,
  one after the other: **Reverb**, **Echo**, **Compressor**, **Limiter**, **Pitch**, **Distortion** and
  **Voice Isolation** (just the voice in a video, without the noise around it), or any Audio Unit
  plug-in on your Mac, listed by who makes it. Soundcheck's own have a few plain controls and their
  presets (Reverb's rooms and halls, say) right in the panel; **Open Window** shows all of an effect's
  controls, in a plug-in's own design. Click an effect's icon to turn it off without losing how it's
  set. Other makers' plug-ins run in a process of their own, so one that crashes just goes quiet
  instead of taking your sound with it.
- **Pinned Apps** always have a bar, even when they're quiet.
- **Browser tabs, one by one.** With Soundcheck's extension in Safari, Dia or Chrome, a browser's
  name in the Apps list opens to its tabs that are playing or on a call, each with its favicon, its
  own volume and mute (on top of the browser's). When a tab joins a call (Meet, Zoom, Teams,
  Discord…), Quiet Apps in Calls lowers or mutes the browser's other tabs as well as the other apps.
  Set it up in **Options › Soundcheck › Browser Tabs**.
- **System** is always at the end of the list: macOS's own sounds (alerts like the "can't do that"
  bonk, notification sounds, the charging chime, Control Center's volume click and ringtones) as one
  app, with its own volume, mute, EQ and speakers. Route it into Soundcheck Mic too, if you want your
  call or stream to hear your notifications.
- **Every app remembers its volume.** App bars move on their own, unless you pick **Apps** at the top,
  where the main bar and the volume keys move them all together.

### Mics and Soundcheck Mic

**Soundcheck Mic** is a virtual microphone that Soundcheck adds to your Mac. While Soundcheck is
running it's your Mac's microphone, and it carries whichever real mic you pick in Soundcheck. That
means Zoom, FaceTime, Discord, OBS and your browser never need their microphone setting changed again:
you change it once, in the menu bar, and every app follows.

- **Route** mixes into Soundcheck Mic. Tick as many mics as you like, each with its own level and
  mute, and add apps too (each with its own level and mute, which only applies inside Soundcheck Mic), so the people on your call hear your music, a soundboard or a
  game along with you.
- **Live level meters** run inside every mic slider, a lighter shade of the bar that follows how loud
  you are. They're sized to the slider, so a mic turned all the way down shows nothing.
- **A mic at zero is muted**, really muted, in the hardware and in the mix. Or click the mic at
  the end of its bar to mute it without losing its level.
- **An EQ for each mic**, inside Soundcheck Mic: *Less Rumble* for a desk mic, *Clear Voices* for a
  laptop's. Every app hears the result.
- **Effects for each mic** too, with the FX button next to its EQ: *Voice Isolation* to keep just your
  voice, a *Compressor* to even you out, *Reverb* or *Pitch* for fun, or your own plug-ins. They come
  after the mic's EQ and Voice Cleanup, and every app hears them.
- **Hear Yourself** plays your mic in your headphones: turn it on with the headphones button next to
  their EQ, and set how loud under the mic.
- **Voice Cleanup** (in Options) cuts rumble, quiets the room between your words and evens out your
  level, for everyone who hears Soundcheck Mic.
- **Lower Apps When You Talk** (in Options) dips the music you've routed into Soundcheck Mic while
  you speak, then brings it back, like a radio host.
- **Mute Mics** has a keyboard shortcut you choose, and a pill shows **Mics Muted** or **Mics On**.
- **See who's listening.** An orange dot and the apps' icons show which apps are using the mic right
  now.
- When **Mics** is picked at the top, the main bar is your mic level, with its meter.

### Options

The **•••** menu in the panel has three sections, opening one at a time, then Reset and Quit:

**Speakers & Apps**

| Option | What it does |
| --- | --- |
| Switch to Headphones | Moves all sound, and the microphone, to headphones when they connect (on by default) |
| Night Mode | Evens out loud and quiet parts, so explosions don't wake anyone and dialogue stays clear |
| Quiet Apps in Calls | While a call rings (FaceTime, or your iPhone through Continuity) or an app is using the mic, lowers every other app, or mutes them, and fades them back after. While it's on, Soundcheck carries the sound whenever something plays, so a call only has to turn things down |
| Boost Apps | Lets app volumes go past 100%, up to 200% |
| Pinned Apps | Apps that always show in the Apps list, chosen from what's playing or with Finder |

**Microphones**

| Option | What it does |
| --- | --- |
| Voice Cleanup | In Soundcheck Mic: cuts rumble, quiets the room between your words (it learns how noisy the room is) and evens out your level |
| Lower Apps When You Talk | Apps routed into Soundcheck Mic dip while you talk, so you're heard over the music; they don't change on your speakers |
| Mute Mics | Mutes every mic, with a keyboard shortcut you set |

**Soundcheck**

| Option | What it does |
| --- | --- |
| Open at Login | Starts Soundcheck when you log in |
| Keep in Menu Bar | Shows the speaker icon all the time, not only while something plays or listens |
| Saved Setups ↗ | Opens the Saved Setups window; your setups are listed below it with Apply buttons |
| Browser Tabs ↗ | Turns on Soundcheck's Safari extension, and adds it to Dia, Chrome and other Chrome-based browsers |
| Check for Updates… | Looks for a newer Soundcheck now (it also checks once a day) |
| Sound Settings… | Opens macOS's Sound settings |

**Reset** evens out the speakers, puts every app back to full and unmuted, sets every EQ, balance and
mono flat, turns every effect off (each stays set up, to turn back on), unmutes anything muted on its
own, and turns Split, Route and Hear Yourself off. For 5
seconds after, it's **Undo Reset**.

### Saved Setups

A setup is a layout you can apply in one click: which speakers play and how loud, each app's volume,
mute and speakers, and what goes into Soundcheck Mic. Make one from how things are right now and
edit it in the Saved Setups window. A setup can also **apply itself** when a speaker or mic connects
(your dock, your headphones) or when an app opens (Zoom, OBS), and the volume pill says so. *Work* might be headphones, Slack quiet and your USB mic; *Movie*
might be the TV's speakers plus the HomePods, everything else muted.

### Shortcuts and Siri

Soundcheck adds three actions to the Shortcuts app, so a shortcut, an automation or Siri can drive it:

| Action | What it does |
| --- | --- |
| Switch Speakers | Plays through the speakers you choose, AirPlay speakers included |
| Set App Volume | Sets one app's volume (up to 200% with Boost Apps on) |
| Apply Setup | Puts one of your saved setups in place |

Say "Apply *Movie* in Soundcheck" to Siri, or run a setup when you join a Wi-Fi network or a Focus
starts.

### iPhone and iPad: Soundcheck Companion

**Soundcheck Companion** is an app for iPhone and iPad (it's called **Soundcheck** on the Home
Screen). It isn't screen sharing: it's the whole panel, made for the phone, working on your Mac live.

- **Control everything.** Speakers, Mix, AirPlay, every app's volume, mute, EQ, effects and Split,
  browser tabs, mics, Route, Hear Yourself and all of the Options, from the couch. A plug-in's own
  window is only on the Mac; the app shows its main controls.
- **Play your Mac here.** Your iPhone or iPad becomes one of the Mac's speakers, in sync with the
  others (AirPlay speakers included). Lock it and the Lock Screen shows your Mac (*MacBook*, on the
  grey tile Soundcheck shows for System) with play/pause and skip, which work whatever's playing on
  the Mac. Pick it on the Mac (it's listed with the speakers) or in the app's Speakers tab, where
  **Timing** under it lines it up with the other speakers by ear if it sounds early or late.
- **Volume buttons for the Mac.** While the app's open, or the iPhone plays your Mac's sound, its
  volume buttons turn the Mac up and down: whatever the main bar controls (Speakers, Apps or
  Mics), the same choice as on the Mac.
- **Use it as a microphone.** Pick it in Mics (on the Mac, or in the app). The iPhone's microphone
  goes into Soundcheck Mic as **iPhone (Soundcheck)**, with its own volume, mute, EQ and effects,
  beside **iPhone (Continuity)** (macOS's Continuity microphone, which Soundcheck now calls that).
- **Calls on your iPhone.** With Quiet Apps in Calls on, answer a call on your iPhone and the Mac's
  apps stay down until you hang up (the Mac on its own only knows it rang).
- **Without opening the app.** *Play Mac Here* and *Play or Pause Mac* go in Control Center, and a
  Lock Screen and Home Screen widget has play/pause and volume. They're in Shortcuts and Siri too.

The first time, open the app on the same Wi-Fi as your Mac and click **Allow** on the Mac (both show
the same code). After that it connects by itself, and your iPad on the same Apple Account is allowed
too, through iCloud Keychain. Manage paired devices in **Options › Soundcheck › iPhone & iPad**.

iOS only lets an app start playing or listening while it's open. When you pick your iPhone as the
speaker or microphone **on the Mac** while the app is in the background, Soundcheck wakes it over
Bluetooth and it shows a notification. Tap it and it starts. From the app, Control Center or the
Lock Screen, it starts straight away.

### The volume pill

With Soundcheck allowed to use the volume keys, pressing them shows Soundcheck's own pill instead of
Apple's, styled like it, for the group you're changing. Volume knobs on Windows-style keyboards work
too. Anything muted (the Mac, one speaker, an app or a mic) says **Muted** and keeps its level,
dimmed, so muted never looks the same as turned all the way down. The menu bar icon's waves fill with the volume, and it animates the way Apple's does when you
mute.

## Install

1. [Download Soundcheck.dmg](https://github.com/myles-dean/Soundcheck/releases/latest/download/Soundcheck.dmg),
   open it and drag **Soundcheck** to **Applications**.
2. Open Soundcheck. A short walkthrough covers the settings, the permissions, adding Soundcheck Mic
   and hiding Apple's Sound icon.
3. Hide Apple's Sound icon so there's only one: **System Settings › Menu Bar**, set **Sound** to
   **Don't Show**.

Soundcheck checks for updates once a day and asks before installing one (or choose
**Options › Check for Updates…**).

Or install it with [Homebrew](https://brew.sh):

```bash
brew tap myles-dean/tap
brew trust myles-dean/tap
brew install --cask soundcheck
```

Soundcheck needs **macOS 26 Tahoe** or later.

### Permissions

macOS asks before an app can do these, so Soundcheck asks for each one when you first need it (the
walkthrough lists them all):

| Permission | What it's for |
| --- | --- |
| Accessibility | Taking over the volume keys and showing Soundcheck's volume pill |
| System Audio Recording | App volumes, EQ, several speakers, AirPlay and routing apps into Soundcheck Mic |
| Microphone | Carrying your real mic into Soundcheck Mic |
| Local Network | Finding AirPlay speakers and streaming to them, and letting Soundcheck Companion find your Mac |
| Bluetooth | Waking Soundcheck Companion on a paired iPhone or iPad (only asked once you've paired one) |

Adding **Soundcheck Mic** asks for your password once, because it installs a small audio driver in
`/Library/Audio/Plug-Ins/HAL`. Your sound pauses for a second while macOS loads it.

## FAQ

**Why does a recording icon appear next to Control Center?**
That's macOS's privacy indicator for "system audio recording". It shows whenever an app takes in
other apps' sound, which is how Soundcheck changes an app's volume, plays through several speakers,
streams to AirPlay and routes apps into Soundcheck Mic. Nothing is recorded or saved. Apple sets the
icon and its colour, and no app can hide it. When Soundcheck isn't changing anything (one speaker,
every app at full, no EQ, Night Mode, AirPlay, Route or Quiet Apps in Calls), it lets go and the icon
goes away.

**Does Soundcheck record anything or send anything anywhere?**
No. Sound passes through it to your speakers and to Soundcheck Mic, and nothing is written to disk.
The only network traffic is to AirPlay speakers you pick, and a daily look at GitHub for a newer
version of Soundcheck (nothing about you or your Mac is sent).

**Which AirPlay speakers work?**
HomePods are tested and connect with no code. Apple TVs pair with the code they show on screen the
first time. Other AirPlay 2 speakers and TVs should work, but they're experimental for now. If one
won't connect, please [open an issue](https://github.com/myles-dean/Soundcheck/issues).

**What happens to my microphone if I quit Soundcheck?**
Your real mic becomes the Mac's microphone again, and every app gets its own sound back.

**And if Soundcheck crashes?**
Soundcheck Mic is silent without Soundcheck, so a small watchdog that runs beside it gives your real
mic back straight away, and opens Soundcheck again (which picks Soundcheck Mic back up). If you
force quit it, your mic comes back and Soundcheck stays closed.

**How do I remove Soundcheck Mic?**
`brew uninstall --zap --cask soundcheck` removes it. Without Homebrew, quit Soundcheck and run:

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/SoundcheckMic.driver && sudo killall coreaudiod
```

**Why macOS 26 only?**
Soundcheck is built on Core Audio process taps and the Liquid Glass design that's new in
macOS 26 Tahoe.

## Build from source

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
./build.sh            # build into ./build
./build.sh install    # build, install to /Applications and launch
./build.sh release    # Developer ID build packaged as build/Soundcheck.dmg, plus build/appcast.xml
```

A release attaches both `Soundcheck.dmg` and `appcast.xml` to its GitHub release; the app's update
feed is the latest release's `appcast.xml`. The appcast is signed with the update key in the
maintainer's Keychain (Sparkle's `generate_keys --account Soundcheck`).

How it fits together:

- `App/Audio`: the engine. Each app's sound is taken with a Core Audio process tap, set to its volume
  and played to its speakers through private aggregate devices; with AirPlay, one mixer feeds every
  speaker from the same timeline.
- `App/AirPlay`: the AirPlay 2 sender (discovery, HomeKit pairing, encryption, the RTP stream and PTP
  timing).
- `App/UI`: the menu bar panel, volume pill, walkthrough and Saved Setups window.
- `App/Intents`: the Shortcuts actions.
- `App/Watchdog.swift`: gives the real mic back (and reopens Soundcheck) if Soundcheck crashes.
- `Extension`: the browser extension (one set of scripts; a manifest for Chrome-based browsers and
  one for Safari, whose extension is built into the app), and `App/Browser`, the app's side of it
  (Chrome-based browsers start Soundcheck's own executable as their native messaging helper).
- `Driver`: Soundcheck Mic, a Core Audio driver (AudioServerPlugIn) with a visible microphone and a
  hidden output that Soundcheck feeds.

## Credits

The AirPlay sender is a Swift port of [pyatv](https://github.com/postlund/pyatv) by Pierre Ståhl,
with PTP timing from OwnTone's [libairptp](https://github.com/owntone/libairptp) and
[tuxplay](https://github.com/ksha23/tuxplay). Their licenses are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The EQ's filters follow Robert Bristow-Johnson's
Audio EQ Cookbook.

## License

[MIT](LICENSE) © 2026 Myles Dean
