# PairDesk on a Mac

PairDesk for Mac is new. It works on macOS 11 (Big Sur) and newer, on Apple silicon and Intel Macs, including Macs in a virtual machine.

## Install

1. Download `PairDesk-<version>-mac.dmg` from the [latest release](https://github.com/sandunMadhushan/pairdesk/releases/latest).
2. Open it and drag **PairDesk** onto **Applications**.
3. Open PairDesk from Applications. macOS says it can't check it for malware, because PairDesk isn't signed with a paid Apple developer account yet. Choose **Done**, then open **System Settings → Privacy & Security**, scroll down and choose **Open Anyway** next to PairDesk.
4. PairDesk's window opens with a pairing code, and its icon appears in the menu bar at the top right. Closing the window keeps PairDesk running there.

## Allow it once

macOS asks you to allow these in **System Settings → Privacy & Security**. PairDesk's Home page lists what is still missing, with a button for each:

| Permission | What it's for |
| --- | --- |
| **Accessibility** | Moving the pointer and typing from your phone. macOS asks the first time a phone sends input. |
| **Screen Recording** | The screen view, and hearing the Mac's own sound (macOS 14.2 and newer). Quit and reopen PairDesk after allowing it. |
| **Microphone** | Only if you let a phone hear the Mac's microphone (PairDesk → Permissions). |
| **Automation** (System Events) | Lock, restart and shut down from the phone. macOS asks the first time. |

Because the app isn't signed with an Apple developer account yet, macOS forgets Accessibility and Screen Recording when PairDesk is updated: turn them off and on again in System Settings after an update.

## What works

Touchpad, keyboard (Cmd, Option and the Mac shortcut buttons), shortcut buttons, opening apps from Applications, power actions, screen view, clipboard, files both ways (dropped on PairDesk's window; received files go to Downloads/PairDesk), two-way sound, remote access through the relay or Tailscale, and Get help.

Not on the Mac: the sign-in screen (macOS doesn't let apps control it), and "Send to phone" in Finder's right-click menu (drop files on PairDesk's window instead). PairDesk tells you about new versions; download and drag the new one to Applications.

## Remove it

Choose **Stop PairDesk** in the menu-bar icon's menu, then drag PairDesk from Applications to the Bin. Its settings are in `~/Library/Application Support/PairDesk`, and start at sign-in in `~/Library/LaunchAgents/PairDesk.plist`.
