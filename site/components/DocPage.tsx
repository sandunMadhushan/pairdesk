// SPDX-License-Identifier: GPL-3.0-or-later
import Header from "@/components/Header";
import Footer from "@/components/Footer";

export default function DocPage({ children }: { children: React.ReactNode }) {
  return (
    <>
      <Header />
      <main className="px-3 pt-28 sm:px-6 sm:pt-32">
        <div className="sheet mx-auto max-w-5xl px-6 py-12 sm:px-14 sm:py-16">
          <article className="prose-doc">{children}</article>
        </div>
      </main>
      <Footer />
    </>
  );
}
