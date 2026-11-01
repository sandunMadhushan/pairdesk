// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect, useState } from "react";

const REPO = "sandunMadhushan/pairdesk";
const LATEST = `https://github.com/${REPO}/releases/latest`;

type Asset =
  | "windows-x64-setup"
  | "windows-x64"
  | "linux-x64-deb"
  | "linux-x64-rpm"
  | "linux-x64-appimage"
  | "android-arm64"
  | "android-armv7";

const fileName = (a: Asset, v: string) =>
  ({
    "windows-x64-setup": `PairDesk-Setup-${v}-x64.exe`,
    "windows-x64": `pairdesk-agent-${v}-windows-x64.exe`,
    "linux-x64-deb": `pairdesk_${v}_amd64.deb`,
    "linux-x64-rpm": `pairdesk-${v}-1.x86_64.rpm`,
    "linux-x64-appimage": `PairDesk-${v}-x86_64.AppImage`,
    "android-arm64": `pairdesk-${v}-android-arm64.apk`,
    "android-armv7": `pairdesk-${v}-android-armv7.apk`,
  })[a];

/** Points the buttons at the latest release's files; until then (or if
 *  GitHub can't be reached) they lead to the release page. */
function useLatest() {
  const [state, setState] = useState<{ version: string; urls: Map<string, string> } | null>(null);
  useEffect(() => {
    const ctrl = new AbortController();
    fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { signal: ctrl.signal })
      .then((r) => (r.ok ? r.json() : null))
      .then((rel) => {
        if (!rel?.tag_name) return;
        const urls = new Map<string, string>(
          (rel.assets ?? []).map((a: { name: string; browser_download_url: string }) => [
            a.name,
            a.browser_download_url,
          ]),
        );
        setState({ version: String(rel.tag_name).replace(/^v/, ""), urls });
      })
      .catch(() => {});
    return () => ctrl.abort();
  }, []);
  const href = (a: Asset) => (state && state.urls.get(fileName(a, state.version))) || LATEST;
  return { version: state?.version, href };
}

const primary =
  "inline-flex rounded-full bg-blue px-5 py-2.5 font-semibold text-white transition-colors hover:bg-blue-deep";

export default function Downloads() {
  const { version, href } = useLatest();
  return (
    <section id="download" aria-labelledby="download-title" className="scroll-mt-16 border-t border-line/70 py-28 sm:py-36">
      <div className="mx-auto max-w-7xl px-4 sm:px-6">
        <div className="flex flex-wrap items-end gap-x-5 gap-y-3">
          <h2 id="download-title" className="display text-[clamp(2.4rem,5.6vw,4.6rem)]">
            Download
          </h2>
          {version && (
            <span className="mb-2 rounded-full border border-signal/40 px-3 py-1 text-sm text-signal">
              Version {version}
            </span>
          )}
        </div>
        <p className="mt-5 max-w-xl text-lg text-mist">
          Install it on the computer and on your phone. PairDesk updates itself on the computer, and the phone app
          tells you when a new version is out.
        </p>

        <div className="mt-16 grid gap-12 md:grid-cols-3 md:gap-0 md:divide-x md:divide-line">
          <div className="md:pr-10">
            <h3 className="text-3xl font-semibold tracking-tight">Windows</h3>
            <p className="mt-3 text-mist">Windows 10 or 11, 64-bit. No administrator rights needed.</p>
            <a className={`${primary} mt-7`} href={href("windows-x64-setup")}>
              Download the setup
            </a>
            <p className="mt-5 text-[0.95rem] text-mist">
              Or the{" "}
              <a className="link" href={href("windows-x64")}>
                program file
              </a>{" "}
              without installing. If SmartScreen warns, choose <i>More info</i>, then <i>Run anyway</i>.
            </p>
          </div>

          <div className="md:px-10">
            <h3 className="text-3xl font-semibold tracking-tight">Linux</h3>
            <p className="mt-3 text-mist">Ubuntu 20.04, Debian 11, Fedora and newer. GNOME and KDE, Wayland or X11.</p>
            <ul className="mt-7 grid gap-3">
              {(
                [
                  ["linux-x64-deb", ".deb", "for Ubuntu, Debian and Mint"],
                  ["linux-x64-rpm", ".rpm", "for Fedora and openSUSE"],
                  ["linux-x64-appimage", "AppImage", "for any distribution"],
                ] as [Asset, string, string][]
              ).map(([a, label, note]) => (
                <li key={a} className="flex items-baseline gap-3">
                  <a className="link font-semibold" href={href(a)}>
                    {label}
                  </a>
                  <span className="text-mist">{note}</span>
                </li>
              ))}
            </ul>
          </div>

          <div className="md:pl-10">
            <h3 className="text-3xl font-semibold tracking-tight">Android</h3>
            <p className="mt-3 text-mist">Android 6 or newer. Coming to F-Droid; until then, download it here.</p>
            <a className={`${primary} mt-7`} href={href("android-arm64")}>
              Download for Android
            </a>
            <p className="mt-5 text-[0.95rem] text-mist">
              For most phones. Older 32-bit phones need the{" "}
              <a className="link" href={href("android-armv7")}>
                armv7 version
              </a>
              . Allow your browser to install apps when Android asks.
            </p>
          </div>
        </div>

        <p className="mt-16 text-[0.95rem] text-mist">
          All files and checksums are on{" "}
          <a className="link" href={LATEST}>
            GitHub Releases
          </a>
          .
        </p>
      </div>
    </section>
  );
}
