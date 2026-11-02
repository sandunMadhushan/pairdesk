// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect, useState } from "react";

type View =
  | { kind: "loading" }
  | { kind: "broken" }
  | { kind: "desktop" }
  | { kind: "phone"; help: boolean; open: string };

export default function LinkLanding() {
  const [view, setView] = useState<View>({ kind: "loading" });

  useEffect(() => {
    const query = location.hash.replace(/^#/, "");
    const valid = /(^|&)fp=/.test(query) && /(^|&)t=/.test(query);
    if (!valid) return setView({ kind: "broken" });
    if (!/Android/i.test(navigator.userAgent)) return setView({ kind: "desktop" });
    const fallback = `${location.origin}/#download`;
    setView({
      kind: "phone",
      help: /(^|&)h=1(&|$)/.test(query),
      open: `intent://pair?${query}#Intent;scheme=pairdesk;package=me.madhushan.pairdesk;S.browser_fallback_url=${encodeURIComponent(fallback)};end`,
    });
  }, []);

  if (view.kind === "loading") return null;

  if (view.kind === "broken")
    return (
      <section className="max-w-xl">
        <h1 className="display text-[clamp(2.4rem,7vw,4rem)]">This link is incomplete</h1>
        <p className="mt-6 text-lg text-slate">
          Part of the link seems to be missing. Copy the whole link again, or ask for a new one, and paste it in
          PairDesk with <b className="text-ink">Paste a link</b>.
        </p>
      </section>
    );

  if (view.kind === "desktop")
    return (
      <section className="max-w-xl">
        <h1 className="display text-[clamp(2.4rem,7vw,4rem)]">Open this link on your phone</h1>
        <p className="mt-6 text-lg text-slate">
          This is a PairDesk link. It&apos;s meant for the PairDesk app on an Android phone: send it to your phone (in a
          chat, an email or a note) and tap it there.
        </p>
        <p className="mt-4 text-slate">
          To control this computer from your phone, install{" "}
          <a className="link" href="/#download">
            PairDesk on the computer
          </a>{" "}
          and pair from its window instead.
        </p>
      </section>
    );

  return (
    <section className="max-w-xl">
      <h1 className="display text-[clamp(2.4rem,9vw,4rem)]">
        {view.help ? "Help with a computer" : "Connect with PairDesk"}
      </h1>
      <p className="mt-6 text-lg text-slate">
        {view.help
          ? "Someone asked you for help with their computer. Open this link in PairDesk to see and use their screen for a while."
          : "Someone sent you a link to their computer. Open it in the PairDesk app to connect."}
      </p>
      <a
        href={view.open}
        className="mt-8 btn btn-pair"
      >
        Open in PairDesk
      </a>
      <div className="mt-12 border-t border-line pt-6">
        <h2 className="text-xl font-semibold">Don&apos;t have PairDesk yet?</h2>
        <ol className="mt-3 list-decimal space-y-2 pl-5 text-slate marker:text-marker">
          <li>
            Download PairDesk for Android from{" "}
            <a className="link" href="/#download">
              the download section
            </a>{" "}
            and install it.
          </li>
          <li>
            Come back to this page and tap <b className="text-ink">Open in PairDesk</b>, or tap the link you were sent
            again.
          </li>
        </ol>
      </div>
      <p className="mt-8 text-[0.95rem] text-slate">
        The link works once and only for a few minutes. If it has run out, ask for a new one.
      </p>
    </section>
  );
}
