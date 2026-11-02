// SPDX-License-Identifier: GPL-3.0-or-later
import type { Metadata } from "next";

export const SITE = "https://pairdesk.madhushan.me";
export const NAME = "PairDesk";
export const TAGLINE = "Your phone is the remote for your computer";
export const DESCRIPTION =
  "Free, open-source remote control for Windows and Linux from your Android phone: touchpad, keyboard, screen view, file transfer and two-way sound. No account needed.";
export const AUTHOR = { name: "Sandun Madhushan", url: "https://madhushan.me" };

export const OG_IMAGE = {
  url: "/og.jpg",
  width: 1200,
  height: 630,
  alt: "PairDesk: an Android phone used as the touchpad for a laptop",
};

/** Metadata for one page: its own title, description and address, with the
 *  shared share image, so link previews are right on every page. */
export function page({
  title,
  description,
  path,
  standalone = false,
}: {
  title: string;
  description: string;
  path: string;
  /** Use the title as it is, without "| PairDesk". */
  standalone?: boolean;
}): Metadata {
  const full = standalone ? title : `${title} | ${NAME}`;
  return {
    title: standalone ? { absolute: title } : title,
    description,
    alternates: { canonical: path },
    openGraph: {
      type: "website",
      siteName: NAME,
      locale: "en_US",
      url: path,
      title: full,
      description,
      images: [OG_IMAGE],
    },
    twitter: {
      card: "summary_large_image",
      title: full,
      description,
      images: [OG_IMAGE.url],
    },
  };
}
