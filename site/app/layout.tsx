// SPDX-License-Identifier: GPL-3.0-or-later
import type { Metadata, Viewport } from "next";
import "@fontsource-variable/bricolage-grotesque/standard.css";
import "@fontsource-variable/atkinson-hyperlegible-next/index.css";
import "./globals.css";
import SmoothScroll from "@/components/SmoothScroll";

export const metadata: Metadata = {
  metadataBase: new URL("https://pairdesk.madhushan.me"),
  title: "PairDesk – your phone is the remote for your computer",
  description:
    "Free and open source: control your Windows or Linux computer from your Android phone. Touchpad, keyboard, screen view, files, clipboard and sound. No account.",
  icons: { icon: "/favicon.png" },
  openGraph: {
    title: "PairDesk",
    description: "Control your Windows or Linux computer from your Android phone.",
    images: ["/icon-256.png"],
  },
};

export const viewport: Viewport = {
  themeColor: "#0a0f24",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <SmoothScroll />
        {children}
      </body>
    </html>
  );
}
