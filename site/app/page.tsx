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

export default function Home() {
  return (
    <>
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
