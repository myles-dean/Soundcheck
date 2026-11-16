# Soundcheck Companion: App Store listing

**Name:** Soundcheck Companion
**Subtitle:** Your Mac's sound, from your iPhone
**Bundle ID:** com.mylesdean.Soundcheck.Companion (widgets: com.mylesdean.Soundcheck.Companion.Widgets)
**Category:** Music (secondary: Utilities)
**Price:** Free
**Devices:** iPhone and iPad, iOS 26 or later
**Privacy policy URL:** https://github.com/myles-dean/Soundcheck/blob/main/docs/PRIVACY.md
**Support URL:** https://github.com/myles-dean/Soundcheck/issues

## Promotional text

Control Soundcheck on your Mac from your iPhone or iPad, play your Mac's sound here in sync with
its other speakers, or use your iPhone as your Mac's microphone.

## Description

Soundcheck Companion works with Soundcheck, the free sound app for your Mac's menu bar.
It isn't screen sharing: it's Soundcheck's whole panel, made for your
iPhone and iPad, working on your Mac live.

CONTROL YOUR MAC'S SOUND
• Pick speakers, play through several at once, each at its own volume, and add AirPlay speakers
• Give every app its own volume, mute, EQ and effects, and send apps to their own speakers
• Set each browser tab's volume
• Choose the microphone, mix several with Route, and hear yourself while you stream
• Night Mode, Voice Cleanup, Quiet Apps in Calls and every other option

PLAY YOUR MAC HERE
Your iPhone or iPad becomes one of your Mac's speakers, in sync with the others. Lock it and your
Mac is on the Lock Screen, with play and pause for whatever's playing on the Mac. While it plays,
or whenever the app's open, your volume buttons turn the Mac up and down.

USE IT AS A MICROPHONE
Your iPhone's microphone goes into Soundcheck Mic on your Mac, with its own volume, EQ and effects.

CALLS ON YOUR IPHONE
Answer a call on your iPhone and your Mac's music stays down until you hang up.

WITHOUT OPENING THE APP
Add Play Mac Here and Play or Pause Mac to Control Center, use the Lock Screen and Home Screen
widgets, or ask Siri.

Requires Soundcheck 1.2 or later on a Mac with macOS 26, on the same Wi-Fi network.

## Keywords

mac,sound,volume,speaker,airplay,remote,mixer,eq,microphone,soundcheck,audio,menu bar

## What's new (1.0)

The first version.

## App Review notes

Soundcheck Companion needs Soundcheck (free, open source: https://github.com/myles-dean/Soundcheck)
running on a Mac on the same network. To review it: install Soundcheck on a Mac (macOS 26), open
it, then open the companion; click Allow on the Mac when asked. A demo video can be supplied.

- Background audio: used only while the device plays the Mac's sound as a speaker, or sends its
  microphone to the Mac, both turned on by the user.
- Bluetooth (bluetooth-central): keeps a Bluetooth LE connection to the user's own paired Mac, so
  the Mac can wake the app when the user picks this device as a speaker or microphone on the Mac,
  and ask whether a phone call is on (to keep the Mac's sound down during calls answered on the
  iPhone). No audio or personal data goes over Bluetooth.
- Call status (CallKit's CXCallObserver): only whether a call is on, never who it's with.
- Local network: finds the Mac with Bonjour (_soundcheck._tcp) and connects to it directly.
- Encryption: standard algorithms from Apple's CryptoKit (X25519, ChaChaPoly, HMAC) to secure the
  connection between the user's own devices (exempt; ITSAppUsesNonExemptEncryption is NO).

## App Privacy answers

Data collection: **No, we don't collect data from this app.** Nothing leaves the user's own
devices: the connection is directly between the iPhone/iPad and the user's Mac.

## Screenshots needed

- iPhone 6.9" (iPhone 17 Pro Max): Speakers, Apps with an app's EQ, Mics, Options, Lock Screen player
- iPad 13" (iPad Pro M5): the sidebar layout
