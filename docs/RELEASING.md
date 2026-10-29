# Releasing PairDesk

Releases are built, tested and published by GitHub Actions
(`.github/workflows/release.yml`). Nothing is built on a laptop.

## One-time setup

Repository → Settings → Secrets and variables → Actions:

| Secret | What |
|---|---|
| `UPDATE_SIGNING_KEY` | The Ed25519 private key (PEM) that signs `latest.json`. Its public half is `PUBLIC_KEY` in `agent/src/update.rs` and `updatePublicKey` in `mobile/lib/update_check.dart`. |
| `ANDROID_KEYSTORE_BASE64` | The release keystore (`pairdesk-release.jks`), base64-encoded. Alias `pairdesk`. |
| `ANDROID_KEYSTORE_PASSWORD` | Its password (the key has the same one). |
| `SIGNPATH_API_TOKEN` | Optional, once SignPath accepts the project (Windows code signing). |

Variables (same page, *Variables* tab): `MSIX_IDENTITY_NAME`, `MSIX_PUBLISHER`,
`MSIX_PUBLISHER_NAME` from Partner Center, and `SIGNPATH_ORGANIZATION_ID`,
`SIGNPATH_PROJECT_SLUG`, `SIGNPATH_POLICY_SLUG` once SignPath is set up.

**Back up both keys somewhere safe outside GitHub** (a password manager). If
the Android key is lost, nobody can update the app; they'd have to uninstall
it. If the update key is lost, a new one needs a release that ships the new
public key, and copies older than that release must be updated by hand.

## Each release

1. Bump the version in `agent/Cargo.toml` (then `cargo update -p pairdesk-agent`)
   and `mobile/pubspec.yaml` (`x.y.z+N`; increase `N` by one each release).
2. Add a `<release version="x.y.z" date="…">` entry to
   `packaging/linux/me.madhushan.pairdesk.metainfo.xml`.
3. Write `docs/releases/vx.y.z.md` (the release notes) and
   `fastlane/metadata/android/en-US/changelogs/{1000+N,2000+N,4000+N}.txt`
   (the phone changelog F-Droid shows, at most 500 characters).
4. Optional: Actions → Release → Run workflow (dry run ticked). It builds and
   tests everything and keeps the files as an artifact.
5. Commit, then tag and push: `git tag vx.y.z && git push origin vx.y.z`.

The workflow checks the versions match, builds the Windows, Linux and Android
downloads, tests the Windows setup under Wine (install, self-update,
uninstall), writes `SHA256SUMS.txt` and the signed `latest.json`, and
publishes the release as *Latest*. Computers running PairDesk see the update
within a day.

Never mark a release as a pre-release: `releases/latest` (and so the
updater) skips pre-releases.

## After the release

- Microsoft Store: download the `store-package-x.y.z` artifact from the
  workflow run and upload the `.msix` in Partner Center (see `docs/STORES.md`).
- Flathub: update `tag`/`commit` in the Flathub repo's manifest (and
  `cargo-sources.json` if dependencies changed).
- F-Droid picks new tags up by itself once the app is listed.
