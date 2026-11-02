// SPDX-License-Identifier: GPL-3.0-or-later
import type { Metadata } from "next";
import Header from "@/components/Header";
import LinkLanding from "@/components/LinkLanding";
import { page } from "@/lib/seo";

// Shown only when a pairing link didn't open PairDesk by itself. The
// pairing details are after the # and never leave the browser.
export const metadata: Metadata = {
  ...page({
    title: "Open this link in PairDesk",
    description: "Someone sent you a PairDesk link. Tap it on your Android phone with PairDesk installed to connect.",
    path: "/p/",
    standalone: true,
  }),
  robots: { index: false, follow: false },
  referrer: "no-referrer",
};

export default function PairLink() {
  return (
    <>
      <Header />
      <main className="min-h-svh px-3 pt-28 pb-16 sm:px-6 sm:pt-32">
        <div className="sheet mx-auto max-w-3xl px-6 py-12 sm:px-14 sm:py-16">
          <LinkLanding />
        </div>
      </main>
    </>
  );
}
