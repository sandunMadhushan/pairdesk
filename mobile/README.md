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
| `lib/agent_connection.dart` | WebSocket connection and protocol messages |
| `lib/touchpad_gestures.dart` | Finger events → move / click / scroll (pure Dart, unit-tested) |
| `lib/touchpad.dart` | Touchpad and hold-to-drag button widgets |
| `lib/screens/` | Connect screen and control screen |

See [../docs/PROTOCOL.md](../docs/PROTOCOL.md) for the messages.
