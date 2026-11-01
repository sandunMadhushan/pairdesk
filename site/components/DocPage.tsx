// SPDX-License-Identifier: GPL-3.0-or-later
import Header from "@/components/Header";
import Footer from "@/components/Footer";

export default function DocPage({ children }: { children: React.ReactNode }) {
  return (
    <>
      <Header />
      <main className="mx-auto max-w-7xl px-4 pt-36 pb-28 sm:px-6">
        <article className="prose-doc">{children}</article>
      </main>
      <Footer />
    </>
  );
}
