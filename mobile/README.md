# PairDesk phone app

Flutter app that turns your phone into a touchpad and keyboard for the PairDesk
desktop agent. Android now; iPhone later.

```bash
flutter test
flutter run                         # phone connected over USB with USB debugging on
flutter build apk --release --split-per-abi
```

App ID: `me.madhushan.pairdesk` (must never change after the first public release).

| File | What it does |
| --- | --- |
| `lib/agent_connection.dart` | Pinned-TLS WebSocket, sign-in handshake, protocol messages |
| `lib/pairing/` | QR link parsing, phone key (Ed25519), saved computers, network discovery |
| `lib/app_model.dart` | App-wide state |
| `lib/touchpad_gestures.dart` | Finger events → move / click / scroll (pure Dart, unit-tested) |
| `lib/touchpad.dart` | Touchpad and hold-to-drag button widgets |
| `lib/screens/` | Home (paired computers), QR scanner, settings, button editor |
| `lib/screens/tabs/` | Control screen tabs: buttons, apps, power |
| `lib/buttons/` | Custom button model, defaults and storage |
| `lib/settings/` | Phone settings and the app lock |

The QR scanner uses ZXing, not Google ML Kit, so the app has no proprietary
dependencies (needed for F-Droid).

See [../docs/PROTOCOL.md](../docs/PROTOCOL.md) for the messages.
