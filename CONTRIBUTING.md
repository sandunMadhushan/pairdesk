# Contributing to PairDesk

Thanks for helping. A few ground rules keep the project healthy.

## Contributor licence agreement

Before your first pull request is merged you will be asked to sign a short
contributor licence agreement (CLA) through CLA Assistant. It lets the maintainer
keep offering PairDesk under GPL-3.0 and, if needed later, under other terms.
You keep the copyright to your work.

## Before opening a pull request

- Run `tools/check.sh` before you push: it runs exactly what GitHub Actions
  runs, so a green run here is a green run there. `tools/check.sh phone`,
  `agent` or `relay` checks only that part. Two things catch people out:
  CI fails if `dart format -l 110` would change anything, and `flutter
  analyze` counts an *info* as a failure, not just a warning.
  - Agent on its own: `cd agent && cargo fmt && cargo clippy && cargo test`
  - Phone app on its own: `cd mobile && dart format -l 110 lib test && flutter analyze && flutter test`
- Start every new source file with a licence header:
  - Rust: `// SPDX-License-Identifier: GPL-3.0-or-later`
  - Dart: `// SPDX-License-Identifier: GPL-3.0-or-later`
- If you change messages between phone and agent, update
  [docs/PROTOCOL.md](docs/PROTOCOL.md) and the tests on both sides.
- Keep the agent's command set closed: new actions must be named and validated,
  never "run this string".

## Reporting security problems

Please do not open a public issue for anything that lets someone control a computer
they have not paired with. Email the maintainer through the contact on
<https://pairdesk.madhushan.me> instead.
