# PairDesk on iPhone

The iPhone app works on iOS 15 and newer (iPhone 6s and later). It isn't on the App Store yet, so you install it yourself with your Apple ID. You don't need a Mac for this.

## Install

1. Install PairDesk on your computer (Windows, Mac or Linux).
2. Download `PairDesk-<version>-iphone.ipa` from the [latest release](https://github.com/sandunMadhushan/pairdesk/releases/latest).
3. Install [Sideloadly](https://sideloadly.io) on Windows or a Mac, connect the iPhone with a cable, drag in the `.ipa` and sign in with your Apple ID.
4. On the iPhone, open **Settings → General → VPN & Device Management**, tap your Apple ID and **Trust**. If iOS asks, turn on **Developer Mode** (Settings → Privacy & Security) and restart.
5. Open PairDesk, tap **+**, then **Scan pairing code**, and point the camera at the code on the computer.

With a free Apple ID, iOS stops apps installed this way after **7 days**, and allows 3 of them at a time. Install it again with Sideloadly each week; your pairings are kept.

## Allow it once

- **Local Network**: iOS asks the first time. Allow it, or the iPhone can't find the computer on your Wi-Fi (the relay and Tailscale work without it). To change it later: Settings → PairDesk → Local Network.
- **Camera**: for scanning the pairing code.
- **Microphone**: only when you talk through the computer.

## Good to know

- Files you receive are in the **Files** app, under **On My iPhone → PairDesk**.
- "Share → PairDesk" from other apps isn't on iPhone yet; send files from the Files tab instead.
- iOS pauses apps in the background, so PairDesk reconnects by itself when you come back to it.
