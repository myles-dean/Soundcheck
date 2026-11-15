# Chrome Web Store listing

**Name:** Soundcheck

**Summary** (132 characters max):
A volume for every tab, in the Soundcheck Mac app, and quieter tabs and apps while a tab is on a call.

**Category:** Tools

**Description:**

Soundcheck is a free, open-source Mac app that replaces the Sound menu: a volume for every app,
several speakers at once, AirPlay in sync, and a microphone that mixes. This extension lets it
reach inside your browser.

- Every tab that's playing appears under your browser in Soundcheck's Apps list, with its icon,
  its own volume and mute.
- When a tab joins a call (Google Meet, Zoom, Teams, Discord and more), Soundcheck's Quiet Apps in
  Calls lowers or mutes your other tabs and apps, and brings them back when the call ends.

It needs the Soundcheck app for macOS 26 or later: https://github.com/myles-dean/Soundcheck

Nothing leaves your Mac. The extension only talks to the Soundcheck app on the same computer.

**Single purpose:**
Lets the Soundcheck Mac app set each browser tab's volume and mute, and lower the other tabs while
one tab is on a call.

**Permission justifications:**
- tabs: to list the tabs that are playing sound or on a call, with their titles, so Soundcheck can
  show them, and to mute a tab when you mute it in Soundcheck.
- favicon: to show each tab's icon next to it in Soundcheck.
- nativeMessaging: to talk to the Soundcheck app on the same Mac, which shows the tabs and sends
  back each tab's volume and mute.
- Host permission (all sites): to set the volume of the audio and video players on whatever page
  you're on, and to notice when a page starts using the microphone for a call. Calls and media can
  be on any site, so it can't be limited to a list.

**Remote code:** No. All of the extension's code is in the package.

**Data use:** The extension doesn't collect or transmit any user data. Tab titles, sites and
icons go only to the Soundcheck app on the same Mac, through Chrome's native messaging, and are
never stored or sent anywhere.
