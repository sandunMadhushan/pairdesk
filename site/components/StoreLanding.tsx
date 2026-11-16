// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect, useState } from "react";
import { STORE_APP, STORE_WEB, isWindows } from "@/lib/store";

// A link that works everywhere: on Windows it opens the Microsoft Store app on
// PairDesk's page; on a phone, Mac or Linux there is no Store app, so it goes to
// the Store's web page instead.
export default function StoreLanding() {
  const [windows, setWindows] = useState<boolean | null>(null);

  useEffect(() => {
    if (isWindows()) {
      setWindows(true);
      location.href = STORE_APP;
    } else {
      setWindows(false);
      location.replace(STORE_WEB);
    }
  }, []);

  return (
    <section className="max-w-xl">
      <h1 className="display text-[clamp(2.4rem,7vw,4rem)]">
        {windows ? "Opening the Microsoft Store" : "Taking you to the Microsoft Store"}
      </h1>
      <p className="mt-6 text-lg text-slate">
        {windows
          ? "If your browser asks, choose Open Microsoft Store."
          : "PairDesk for Windows is in the Microsoft Store."}
      </p>
      <div className="mt-8 flex flex-wrap gap-3">
        {windows && (
          <a className="btn btn-ink" href={STORE_APP}>
            Open the Microsoft Store app
          </a>
        )}
        <a className={windows ? "btn btn-line" : "btn btn-ink"} href={STORE_WEB}>
          {windows ? "Open in the browser instead" : "Open the Store page"}
        </a>
      </div>
      <noscript>
        <p className="mt-6">
          <a className="link" href={STORE_WEB}>
            Open PairDesk in the Microsoft Store
          </a>
        </p>
      </noscript>
    </section>
  );
}
