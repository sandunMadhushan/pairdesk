// SPDX-License-Identifier: GPL-3.0-or-later
import type { Metadata } from "next";
import Header from "@/components/Header";
import PhoneAppLanding from "@/components/PhoneAppLanding";
import { page } from "@/lib/seo";

// One link for the phone app: the computer app's QR code points here, and
// when the app reaches Google Play and the App Store only this page changes.
export const metadata: Metadata = {
  ...page({
    title: "Get the PairDesk phone app",
    description: "Download the PairDesk app for your phone.",
    path: "/app/",
    standalone: true,
  }),
  robots: { index: false, follow: false },
};

export default function App() {
  return (
    <>
      <Header />
      <main className="min-h-svh px-3 pt-28 pb-16 sm:px-6 sm:pt-32">
        <div className="sheet mx-auto max-w-3xl px-6 py-12 sm:px-14 sm:py-16">
          <PhoneAppLanding />
        </div>
      </main>
    </>
  );
}
