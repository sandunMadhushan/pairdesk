// SPDX-License-Identifier: GPL-3.0-or-later
import type { NextConfig } from "next";

// A static site: `next build` writes it to out/, which GitHub Pages serves
// at pairdesk.madhushan.me (see .github/workflows/pages.yml).
const config: NextConfig = {
  output: "export",
  images: { unoptimized: true },
  // privacy/index.html rather than privacy.html next to a privacy/ folder,
  // which GitHub Pages would answer with a redirect anyway.
  trailingSlash: true,
  reactStrictMode: true,
};

export default config;
