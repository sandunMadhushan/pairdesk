// SPDX-License-Identifier: GPL-3.0-or-later
import Header from "@/components/Header";
import Footer from "@/components/Footer";
import Hero from "@/components/Hero";
import Motion from "@/components/Motion";
import Downloads from "@/components/Downloads";
import Anywhere from "@/components/Anywhere";
import Help from "@/components/Help";
import { Files, Screen, Touchpad } from "@/components/Features";
import { Questions, Setup, Stats, Tour, Trust } from "@/components/Sections";
import { AUTHOR, DESCRIPTION, NAME, SITE } from "@/lib/seo";

// What search engines read about the app (schema.org).
const STRUCTURED = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "SoftwareApplication",
      "@id": `${SITE}/#app`,
      name: NAME,
      description: DESCRIPTION,
      url: `${SITE}/`,
      applicationCategory: "UtilitiesApplication",
      operatingSystem: "Windows 10, Windows 11, Linux, Android 6.0 or newer",
      offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
      isAccessibleForFree: true,
      license: "https://www.gnu.org/licenses/gpl-3.0.html",
      downloadUrl: `${SITE}/#download`,
      installUrl: `${SITE}/#download`,
      image: `${SITE}/og.jpg`,
      screenshot: ["1_computers", "2_touchpad", "3_buttons", "4_apps", "5_clipboard_files"].map(
        (s) => `${SITE}/screenshots/${s}.png`,
      ),
      featureList: [
        "Use the phone as a touchpad and keyboard",
        "See and control the computer's screen",
        "Send files and share the clipboard both ways",
        "Hear the computer and talk through it",
        "Connect from anywhere through Tailscale or the PairDesk relay",
        "Help a friend with a two-hour help link",
      ],
      author: { "@type": "Person", name: AUTHOR.name, url: AUTHOR.url },
      sameAs: ["https://github.com/sandunMadhushan/pairdesk"],
    },
    {
      "@type": "WebSite",
      "@id": `${SITE}/#site`,
      name: NAME,
      url: `${SITE}/`,
      inLanguage: "en",
      publisher: { "@type": "Person", name: AUTHOR.name, url: AUTHOR.url },
    },
  ],
};

export default function Home() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(STRUCTURED).replace(/</g, "\\u003c") }}
      />
      <Header home />
      <main className="flex flex-col gap-10 overflow-x-clip sm:gap-14">
        <Hero />
        <Stats />
        <Touchpad />
        <Screen />
        <Files />
        <Anywhere />
        <Help />
        <div className="py-14 sm:py-20">
          <Setup />
        </div>
        <Trust />
        <div className="py-14 sm:py-20">
          <Tour />
        </div>
        <Downloads />
        <Questions />
      </main>
      <Footer />
      <Motion />
    </>
  );
}
