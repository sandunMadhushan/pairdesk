// SPDX-License-Identifier: GPL-3.0-or-later
import Header from "@/components/Header";
import Footer from "@/components/Footer";
import Story from "@/components/Story";
import Downloads from "@/components/Downloads";
import { More, Questions, Setup, Trust } from "@/components/Sections";

export default function Home() {
  return (
    <>
      <Header home />
      <main>
        <Story />
        <Setup />
        <Trust />
        <More />
        <Downloads />
        <Questions />
      </main>
      <Footer />
    </>
  );
}
