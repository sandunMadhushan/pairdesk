# Getting PairDesk into stores

What's ready in this repository, and the steps only the project owner can
take (accounts, forms, submissions). Do them in this order.

## 0. Make the repository public

Everything below needs it: F-Droid and Flathub build from public source,
SignPath only signs public open-source projects, GitHub Pages is free only
for public repositories, and the update check reads `releases/latest`, which
anonymous visitors (every PairDesk install) can only see in a public
repository.

Before switching: Settings → General → Danger zone → Change visibility.
The history contains no secrets (the signing keys were never committed).

## 1. Website: pairdesk.madhushan.me

Ready: `site/` (home page with downloads, privacy policy, code signing
policy) and `.github/workflows/pages.yml`.

1. Settings → Pages → Build and deployment → Source: **GitHub Actions**.
2. At your DNS provider for madhushan.me: `CNAME pairdesk → sandunmadhushan.github.io`.
3. Settings → Pages → Custom domain: `pairdesk.madhushan.me`; tick
   **Enforce HTTPS** once the certificate is issued.
4. Actions → Website → Run workflow (later pushes to `site/` deploy by themselves).

The stores link to `https://pairdesk.madhushan.me/privacy/`.

## 2. Microsoft Store (free for individuals)

Ready: the MSIX package. Each release workflow run builds it
(`store-package-x.y.z` artifact) from `packaging/windows/msix/AppxManifest.xml`.
The Store copy starts at sign-in through a startup task, opens the firewall
for port 47800 and mDNS on private networks, and gets updates from the Store.

1. Register at <https://storedeveloper.microsoft.com> (individual account,
   no fee) and open Partner Center → Apps and games → New product → MSIX or
   PWA app; reserve the name **PairDesk**.
2. Product management → Product identity: copy *Package/Identity/Name*,
   *Package/Identity/Publisher* and *Package/Properties/PublisherDisplayName*
   into the repository variables `MSIX_IDENTITY_NAME`, `MSIX_PUBLISHER` and
   `MSIX_PUBLISHER_NAME` (Settings → Secrets and variables → Actions →
   Variables), then rerun the release workflow (dry run) to get a package
   with that identity.
3. Start a submission:
   - Pricing: Free. Category: Utilities & tools (or Productivity).
   - Properties: privacy policy URL `https://pairdesk.madhushan.me/privacy/`;
     website `https://pairdesk.madhushan.me`.
   - Packages: upload `PairDesk-x.y.z.msix`.
   - Store listing: use the description below and screenshots of the
     settings page (`site/public/screenshots/settings.png`) plus phone screenshots.
   - Submission options → notes for certification: the `runFullTrust`
     capability is needed because PairDesk is a desktop program that moves
     the pointer and types on behalf of the paired phone; there is no
     server or account; testers can pair any Android phone with the APK
     from GitHub Releases.
4. Each new release: new submission with the new `.msix` (version x.y.z.0).

Store description:

> PairDesk turns your Android phone into a remote for this PC: touchpad and
> keyboard, the screen in your hand, shortcut buttons, apps, power actions,
> and files and clipboard both ways. Pair once by scanning a code; your
> phone then connects whenever you open the app, on the same Wi-Fi or from
> anywhere with Tailscale. No account, no server: the phone talks to the PC
> directly over an encrypted connection, and only paired phones can
> connect. Free and open source (GPL-3.0). Get the phone app at
> pairdesk.madhushan.me.

## 3. F-Droid

Ready:
- the recipe `packaging/fdroid/me.madhushan.pairdesk.yml` (passes `fdroid lint`);
- the listing text, icon, screenshots and changelogs in `fastlane/metadata/android/en-US`;
- no non-free dependencies (QR scanning is ZXing; no Google Play Services
  or Firebase);
- the Google dependency blob is off, and `PAIRDESK_UNSIGNED=1` builds an
  unsigned APK for F-Droid to sign.

1. Make sure tag `v0.8.0` exists (the release does that).
2. Create a GitLab account, fork <https://gitlab.com/fdroid/fdroiddata>,
   add `metadata/me.madhushan.pairdesk.yml` (copy it from `packaging/fdroid/`),
   and open a merge request. The template asks some questions; answer them
   yourself. F-Droid encourages saying that AI tools helped write the app.
3. F-Droid builds and signs its own APKs with its own key, so Android
   won't install an F-Droid copy over the GitHub copy (or the other way
   round). That's normal for F-Droid apps.

Screenshots are regenerated with
`PAIRDESK_SCREENSHOTS=../fastlane/metadata/android/en-US/images/phoneScreenshots flutter test test/store_screenshots_test.dart`
(run from `mobile/`).

## 4. Flathub

**Read this before starting.** Flathub's requirements
(<https://docs.flathub.org/docs/for-app-authors/requirements>) say:
- submitters must disclose AI-generated code, documentation and packaging;
- **Flathub manifests must not contain AI-generated or AI-assisted content**;
- AI tools must not open or automate submission pull requests.

PairDesk's code was written with Claude, so:
- the manifest in `packaging/flatpak/` was written by Claude and **can't be
  submitted to Flathub**. It's the project's own test build: it builds
  offline, runs, and was tested (sandbox, portals, host commands);
- for Flathub you'd write the manifest yourself, disclose the AI-generated
  code in the pull request, and open the PR yourself.

Reviewers may also question `--talk-name=org.freedesktop.Flatpak` (used to
open the computer's apps and run power actions on the host). The rules ask
for minimal permissions; be ready to explain that a remote control for the
whole computer needs it, or offer a build without those features.

Because of these rules, the `.deb`, `.rpm` and AppImage from GitHub Releases
are the main Linux downloads. Flathub is optional.

Submission steps (when you do it): fork `flathub/flathub` with all
branches, branch from `new-pr`, add your manifest and `cargo-sources.json`
(`packaging/flatpak/cargo-sources.py agent/Cargo.lock`), and open a PR
against `new-pr` titled `Add me.madhushan.pairdesk`. The app ID needs proof
you own madhushan.me (Flathub explains the `.well-known` token during review).

## 5. Windows code signing: SignPath Foundation (free)

Unsigned downloads make Windows SmartScreen warn ("unknown publisher").
SignPath Foundation signs open-source releases for free.

Their conditions (<https://signpath.org/terms>), and where PairDesk stands:
- OSI licence, no proprietary parts: yes (GPL-3.0-or-later).
- Already released, functionality described on the download page: yes,
  after v0.8.0 and the website.
- Uninstall support: yes (the Windows setup has an uninstaller).
- Privacy: the update check is described in the privacy policy and can be
  turned off on the settings page.
- A "Code signing policy" page linked from the home and download pages:
  `site/app/code-signing/page.tsx` (linked in the footer). Update it once accepted.
- Multi-factor authentication on GitHub and SignPath for everyone on the team.

Apply at <https://signpath.org/apply>. Once accepted, set the secret
`SIGNPATH_API_TOKEN` and the variables `SIGNPATH_ORGANIZATION_ID`,
`SIGNPATH_PROJECT_SLUG` and `SIGNPATH_POLICY_SLUG` (artifact configuration
slug `agent`). The release workflow then signs `pairdesk-agent.exe` and
`pairdesk-startup.exe` before building the setup. The setup itself would
need a second signing request after it's built; ask SignPath how they
prefer to handle installers.

## 6. Google Play (later)

The plan leaves this for later: US$25 once, plus a closed test with 12
testers for 14 days for new personal accounts.
