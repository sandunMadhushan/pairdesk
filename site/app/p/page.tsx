// SPDX-License-Identifier: GPL-3.0-or-later
import type { Metadata } from "next";
import Header from "@/components/Header";
import LinkLanding from "@/components/LinkLanding";

// Shown only when a pairing link didn't open PairDesk by itself. The
// pairing details are after the # and never leave the browser.
export const metadata: Metadata = {
  title: "Open in PairDesk",
  description: "A PairDesk pairing link. Open it on your Android phone with PairDesk installed.",
  robots: { index: false, follow: false },
  referrer: "no-referrer",
};

export default function PairLink() {
  return (
    <>
      <Header />
      <main className="mx-auto min-h-svh max-w-7xl px-4 pt-36 pb-24 sm:px-6">
        <LinkLanding />
      </main>
    </>
  );
}
