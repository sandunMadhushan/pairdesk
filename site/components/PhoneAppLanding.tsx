// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect, useState } from "react";
import { APP_STORE, PLAY_STORE, phoneKind, type Phone } from "@/lib/phoneApp";

const REPO = "sandunMadhushan/pairdesk";
const LATEST = `https://github.com/${REPO}/releases/latest`;

// One link for the phone app. Android gets the store page once the app is
// there and the APK from GitHub until then; iPhone waits for the App Store.
export default function PhoneAppLanding() {
  const [phone, setPhone] = useState<Phone | null>(null);
  const [apk, setApk] = useState<{ arm64: string; armv7: string | null } | null>(null);

  useEffect(() => {
    const kind = phoneKind();
    setPhone(kind);
    if (kind === "android" && PLAY_STORE) location.replace(PLAY_STORE);
    if (kind === "ios" && APP_STORE) location.replace(APP_STORE);
  }, []);

  useEffect(() => {
    const ctrl = new AbortController();
    fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { signal: ctrl.signal })
      .then((r) => (r.ok ? r.json() : null))
      .then((rel) => {
        const assets: { name: string; browser_download_url: string }[] = rel?.assets ?? [];
        const find = (suffix: string) => assets.find((a) => a.name.endsWith(suffix))?.browser_download_url ?? null;
        const arm64 = find("-android-arm64.apk");
        if (arm64) setApk({ arm64, armv7: find("-android-armv7.apk") });
      })
      .catch(() => {});
    return () => ctrl.abort();
  }, []);

  const android = (
    <>
      <p className="mt-6 text-lg text-slate">
        {PLAY_STORE
          ? "PairDesk for Android is on Google Play."
          : "Android 6 or newer. Allow your browser to install apps when Android asks."}
      </p>
      <div className="mt-8 flex flex-wrap gap-3">
        <a className="btn btn-ink" href={PLAY_STORE ?? apk?.arm64 ?? LATEST}>
          {PLAY_STORE ? "Open Google Play" : "Download for Android"}
        </a>
        {!PLAY_STORE && apk?.armv7 && (
          <a className="btn btn-line" href={apk.armv7}>
            Older phone (32-bit)
          </a>
        )}
      </div>
    </>
  );

  const ios = (
    <p className="mt-6 text-lg text-slate">
      {APP_STORE
        ? "PairDesk for iPhone is on the App Store."
        : "The iPhone app is coming soon. PairDesk already works from any Android phone."}
    </p>
  );

  return (
    <section className="max-w-xl">
      <h1 className="display text-[clamp(2.4rem,7vw,4rem)]">Get the PairDesk phone app</h1>
      {phone === "ios" ? (
        ios
      ) : phone === "android" ? (
        android
      ) : (
        <>
          <p className="mt-6 text-lg text-slate">
            Open this page on your phone, or pick yours below. You&apos;ll also need PairDesk on your computer.
          </p>
          <h2 className="mt-8 text-xl font-semibold tracking-tight">Android</h2>
          {android}
          <h2 className="mt-10 text-xl font-semibold tracking-tight">iPhone</h2>
          {ios}
        </>
      )}
      <noscript>
        <p className="mt-6">
          <a className="link" href={LATEST}>
            Get PairDesk for Android from GitHub
          </a>
        </p>
      </noscript>
    </section>
  );
}
