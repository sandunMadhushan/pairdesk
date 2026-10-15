# Contributing to PairDesk

Thanks for helping. A few ground rules keep the project healthy.

## Contributor licence agreement

Before your first pull request is merged you will be asked to sign a short
contributor licence agreement (CLA) through CLA Assistant. It lets the maintainer
keep offering PairDesk under GPL-3.0 and, if needed later, under other terms.
You keep the copyright to your work.

## Before opening a pull request

- Run the checks for what you changed:
  - Agent: `cd agent && cargo fmt && cargo clippy && cargo test`
  - Phone app: `cd mobile && dart format -l 110 lib test && flutter analyze && flutter test`
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
