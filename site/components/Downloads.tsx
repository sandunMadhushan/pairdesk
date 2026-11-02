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

function OsIcon({ d }: { d: string }) {
  return (
    <svg viewBox="0 0 24 24" className="size-7" fill="currentColor" aria-hidden="true">
      <path d={d} />
    </svg>
  );
}
const WIN = "M3 5.5 10.5 4.4v7.1H3zM11.5 4.3 21 3v8.5h-9.5zM3 12.5h7.5v7.1L3 18.5zM11.5 12.5H21V21l-9.5-1.3z";
const LINUX =
  "M12 2c-2.2 0-3.6 1.9-3.6 4.6 0 1.3.3 2.3-.5 3.6-1 1.6-2.9 4-2.9 6.5 0 .9.2 1.6.6 2.2-.5.4-1.1.9-1.1 1.6 0 1 1.3 1.5 3.3 1.5 1.3 0 2.1-.4 2.6-.8.5.1 1 .2 1.6.2s1.1-.1 1.6-.2c.5.4 1.3.8 2.6.8 2 0 3.3-.5 3.3-1.5 0-.7-.6-1.2-1.1-1.6.4-.6.6-1.3.6-2.2 0-2.5-1.9-4.9-2.9-6.5-.8-1.3-.5-2.3-.5-3.6C15.6 3.9 14.2 2 12 2zm-1.6 4.2c.4 0 .7.5.7 1.1s-.3 1.1-.7 1.1-.7-.5-.7-1.1.3-1.1.7-1.1zm3.2 0c.4 0 .7.5.7 1.1s-.3 1.1-.7 1.1-.7-.5-.7-1.1.3-1.1.7-1.1zM12 9.2c.8 0 1.9.5 1.9.9s-1.1 1-1.9 1-1.9-.6-1.9-1 1.1-.9 1.9-.9z";
const DROID =
  "M7.2 9h9.6c.7 0 1.2.5 1.2 1.2v7.2c0 .7-.5 1.2-1.2 1.2H16v2.6a1.2 1.2 0 1 1-2.4 0v-2.6h-3.2v2.6a1.2 1.2 0 1 1-2.4 0v-2.6h-.8c-.7 0-1.2-.5-1.2-1.2v-7.2C6 9.5 6.5 9 7.2 9zM3.6 9a1.2 1.2 0 0 1 1.2 1.2v5.2a1.2 1.2 0 1 1-2.4 0v-5.2C2.4 9.5 2.9 9 3.6 9zm16.8 0a1.2 1.2 0 0 1 1.2 1.2v5.2a1.2 1.2 0 1 1-2.4 0v-5.2c0-.7.5-1.2 1.2-1.2zM8.3 2.6l1 1.6A6 6 0 0 1 12 3.6c1 0 1.9.2 2.7.6l1-1.6a.4.4 0 0 1 .7.4l-1 1.6A5.4 5.4 0 0 1 18 8H6a5.4 5.4 0 0 1 2.6-3.4l-1-1.6a.4.4 0 0 1 .7-.4zM9.6 5.6a.6.6 0 1 0 0 1.2.6.6 0 0 0 0-1.2zm4.8 0a.6.6 0 1 0 0 1.2.6.6 0 0 0 0-1.2z";

export default function Downloads() {
  const { version, href } = useLatest();
  return (
    <section id="download" aria-labelledby="download-title" className="scroll-mt-20 px-3 sm:px-6">
      <div data-sheet className="sheet mx-auto max-w-7xl">
        <div className="p-7 sm:p-12 lg:p-16">
          <div className="flex flex-wrap items-end justify-between gap-6">
            <div className="max-w-2xl">
              <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
                <h2 id="download-title" className="display text-[clamp(2.4rem,5vw,4.2rem)]">
                  Download PairDesk
                </h2>
                {version && (
                  <span className="rounded-full bg-pair-soft px-3 py-1 text-sm font-semibold text-pair">Version {version}</span>
                )}
              </div>
              <p className="mt-5 text-lg text-slate">
                Install it on the computer and on your phone. PairDesk updates itself on the computer, and the phone app
                tells you when a new version is out.
              </p>
            </div>
            <p className="hand text-[1.8rem] text-marker">free, always</p>
          </div>

          <div data-pop className="mt-12 grid gap-5 lg:grid-cols-3">
            <div data-pop-item className="flex flex-col rounded-[28px] bg-sky p-7">
              <span className="grid size-14 place-items-center rounded-2xl bg-white text-[#0078d4] shadow-sm">
                <OsIcon d={WIN} />
              </span>
              <h3 className="mt-6 text-2xl font-semibold tracking-tight">Windows</h3>
              <p className="mt-2 text-slate">Windows 10 or 11, 64-bit. No administrator rights needed.</p>
              <div className="mt-auto pt-7">
                <a className="btn btn-ink w-full" href={href("windows-x64-setup")}>
                  Download the setup
                </a>
                <p className="mt-4 text-[0.9rem] text-slate">
                  Or the{" "}
                  <a className="link" href={href("windows-x64")}>
                    program file
                  </a>{" "}
                  without installing. If SmartScreen warns, choose <i>More info</i>, then <i>Run anyway</i>.
                </p>
              </div>
            </div>

            <div data-pop-item className="flex flex-col rounded-[28px] bg-sky p-7">
              <span className="grid size-14 place-items-center rounded-2xl bg-white text-ink shadow-sm">
                <OsIcon d={LINUX} />
              </span>
              <h3 className="mt-6 text-2xl font-semibold tracking-tight">Linux</h3>
              <p className="mt-2 text-slate">Ubuntu 20.04, Debian 11, Fedora and newer. GNOME and KDE, Wayland or X11.</p>
              <ul className="mt-auto grid gap-2.5 pt-7">
                {(
                  [
                    ["linux-x64-deb", ".deb", "Ubuntu, Debian, Mint"],
                    ["linux-x64-rpm", ".rpm", "Fedora, openSUSE"],
                    ["linux-x64-appimage", "AppImage", "any distribution"],
                  ] as [Asset, string, string][]
                ).map(([a, label, note]) => (
                  <li key={a}>
                    <a
                      href={href(a)}
                      className="flex min-h-12 items-center justify-between rounded-2xl bg-white px-4 py-2.5 font-semibold transition-colors hover:bg-pair-soft"
                    >
                      {label}
                      <span className="text-[0.9rem] font-normal text-slate">{note}</span>
                    </a>
                  </li>
                ))}
              </ul>
            </div>

            <div data-pop-item className="flex flex-col rounded-[28px] bg-pair p-7 text-white shadow-[0_30px_60px_-30px_var(--color-pair)]">
              <span className="grid size-14 place-items-center rounded-2xl bg-white text-[#3ddc84] shadow-sm">
                <OsIcon d={DROID} />
              </span>
              <h3 className="mt-6 text-2xl font-semibold tracking-tight">Android</h3>
              <p className="mt-2 text-white/80">Android 6 or newer. Coming to F-Droid; until then, download it here.</p>
              <div className="mt-auto pt-7">
                <a className="btn btn-white w-full" href={href("android-arm64")}>
                  Download for Android
                </a>
                <p className="mt-4 text-[0.9rem] text-white/80">
                  For most phones. Older 32-bit phones need the{" "}
                  <a className="text-white underline underline-offset-4" href={href("android-armv7")}>
                    armv7 version
                  </a>
                  . Allow your browser to install apps when Android asks.
                </p>
              </div>
            </div>
          </div>

          <p className="mt-10 text-[0.95rem] text-slate">
            All files and checksums are on{" "}
            <a className="link" href={LATEST}>
              GitHub Releases
            </a>
            .
          </p>
        </div>
      </div>
    </section>
  );
}
