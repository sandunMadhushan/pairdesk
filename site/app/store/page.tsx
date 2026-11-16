// SPDX-License-Identifier: GPL-3.0-or-later
import type { Metadata } from "next";
import Header from "@/components/Header";
import StoreLanding from "@/components/StoreLanding";
import { page } from "@/lib/seo";

// One link for the Store: opens the Microsoft Store app on Windows and the
// Store's web page on every other device.
export const metadata: Metadata = {
  ...page({
    title: "PairDesk in the Microsoft Store",
    description: "Get PairDesk for Windows from the Microsoft Store.",
    path: "/store/",
    standalone: true,
  }),
  robots: { index: false, follow: false },
};

export default function Store() {
  return (
    <>
      <Header />
      <main className="min-h-svh px-3 pt-28 pb-16 sm:px-6 sm:pt-32">
        <div className="sheet mx-auto max-w-3xl px-6 py-12 sm:px-14 sm:py-16">
          <StoreLanding />
        </div>
      </main>
    </>
  );
}
