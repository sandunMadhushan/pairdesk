// SPDX-License-Identifier: GPL-3.0-or-later
import type { MetadataRoute } from "next";
import { SITE } from "@/lib/seo";

export const dynamic = "force-static";

export default function robots(): MetadataRoute.Robots {
  return {
    // /p/ only opens pairing links; there's nothing to index there.
    rules: [{ userAgent: "*", allow: "/", disallow: "/p/" }],
    sitemap: `${SITE}/sitemap.xml`,
    host: SITE,
  };
}
