// SPDX-License-Identifier: GPL-3.0-or-later
import type { MetadataRoute } from "next";
import { DESCRIPTION, NAME } from "@/lib/seo";

export const dynamic = "force-static";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: NAME,
    short_name: NAME,
    description: DESCRIPTION,
    start_url: "/",
    display: "standalone",
    background_color: "#eef3fb",
    theme_color: "#1f5bff",
    icons: [
      { src: "/icon-192.png", sizes: "192x192", type: "image/png" },
      { src: "/icon-512.png", sizes: "512x512", type: "image/png" },
      { src: "/icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  };
}
