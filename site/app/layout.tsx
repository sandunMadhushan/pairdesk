// SPDX-License-Identifier: GPL-3.0-or-later
import type { Metadata, Viewport } from "next";
import "@fontsource-variable/outfit/index.css";
import "@fontsource-variable/caveat/index.css";
import "./globals.css";
import { Analytics } from "@vercel/analytics/next";
import SmoothScroll from "@/components/SmoothScroll";
import { AUTHOR, DESCRIPTION, NAME, OG_IMAGE, SITE, TAGLINE } from "@/lib/seo";

export const metadata: Metadata = {
  metadataBase: new URL(SITE),
  title: {
    default: `${NAME}: control your computer from your Android phone`,
    template: `%s | ${NAME}`,
  },
  description: DESCRIPTION,
  applicationName: NAME,
  authors: [AUTHOR],
  creator: AUTHOR.name,
  publisher: AUTHOR.name,
  category: "technology",
  keywords: [
    "PairDesk",
    "phone as touchpad",
    "phone as mouse and keyboard",
    "control PC from Android",
    "Android remote control for Windows",
    "Linux remote desktop from phone",
    "remote mouse",
    "screen mirroring to phone",
    "send files phone to PC",
    "open source remote control",
    "help a friend with their computer",
  ],
  alternates: { canonical: "/" },
  openGraph: {
    type: "website",
    siteName: NAME,
    locale: "en_US",
    url: "/",
    title: `${NAME}: ${TAGLINE.toLowerCase()}`,
    description: DESCRIPTION,
    images: [OG_IMAGE],
  },
  twitter: {
    card: "summary_large_image",
    title: `${NAME}: ${TAGLINE.toLowerCase()}`,
    description: DESCRIPTION,
    images: [OG_IMAGE.url],
  },
  robots: {
    index: true,
    follow: true,
    googleBot: { index: true, follow: true, "max-image-preview": "large", "max-snippet": -1 },
  },
  icons: {
    icon: [
      { url: "/favicon.png", sizes: "32x32", type: "image/png" },
      { url: "/icon.svg", type: "image/svg+xml" },
    ],
    apple: [{ url: "/apple-touch-icon.png", sizes: "180x180" }],
  },
  formatDetection: { telephone: false, email: false, address: false },
};

export const viewport: Viewport = {
  themeColor: "#eef3fb",
  colorScheme: "light",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <SmoothScroll />
        {children}
        <Analytics />
      </body>
    </html>
  );
}
