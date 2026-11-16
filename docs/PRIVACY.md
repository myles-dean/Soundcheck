# Privacy

Soundcheck, its browser extension and Soundcheck Companion don't collect, store or send any personal data.

**The Mac app** passes sound between your apps, speakers and microphones on your Mac; nothing is
recorded or saved. It connects to the network only to stream to AirPlay speakers you choose, and
once a day to check GitHub for a newer version of Soundcheck (nothing about you or your Mac is
sent). Audio Unit plug-ins you add as effects are other makers' software: Soundcheck runs them in a
process of their own and passes them only the sound of the app or mic you added them to; what they
do with it is up to their makers.

**The browser extension** (for Chrome, Dia and other Chrome-based browsers, and Safari) tells the
Soundcheck app on the same Mac which tabs are playing sound or on a call, with their titles, sites
and icons, and carries out the volume and mute you set for each tab. That information goes only to
the Soundcheck app on your computer, through the browser's native messaging, and is never stored
or sent anywhere else.

**Soundcheck Companion** (the iPhone and iPad app) talks only to Soundcheck on your own Macs, over
your local network, encrypted with a key made when you allow it on the Mac. It shows and changes
Soundcheck's settings, and, only when you turn them on, plays your Mac's sound or sends your
iPhone's microphone to your Mac. That sound goes straight between your devices and is never
recorded or saved. Bluetooth is used only so your Mac can wake the app (it carries no sound or
personal data); phone calls are checked only to tell your Mac whether one is on, never who it's
with. The app's pairing keys are kept in your keychain (synced by iCloud Keychain to your other
devices if you use it). Nothing is sent to anyone else.

Questions: open an issue at https://github.com/myles-dean/Soundcheck/issues
