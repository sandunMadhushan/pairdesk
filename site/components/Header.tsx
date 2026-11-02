// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

const GITHUB = "https://github.com/sandunMadhushan/pairdesk";

export default function Header({ home = false }: { home?: boolean }) {
  const at = (id: string) => (home ? `#${id}` : `/#${id}`);
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const on = () => setScrolled(window.scrollY > 24);
    on();
    window.addEventListener("scroll", on, { passive: true });
    return () => window.removeEventListener("scroll", on);
  }, []);

  return (
    <header className="fixed inset-x-0 top-0 z-50 px-3 pt-3 sm:px-6 sm:pt-4">
      <div
        className={`mx-auto flex h-16 max-w-7xl items-center justify-between rounded-full pr-2 pl-5 transition-[background-color,box-shadow] duration-300 ${
          scrolled ? "bg-white/85 shadow-[0_14px_40px_-20px_rgba(31,58,120,.45)] backdrop-blur-md" : "bg-transparent"
        }`}
      >
        <Link href="/" className="flex items-center gap-2.5 text-lg font-semibold tracking-tight">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/icon.svg" alt="" width={32} height={32} />
          PairDesk
        </Link>
        <nav aria-label="Main" className="flex items-center gap-1 text-[0.95rem] font-medium text-slate">
          <a href={at("touchpad")} className="hidden rounded-full px-3.5 py-2 hover:text-ink md:inline">
            Features
          </a>
          <a href={at("setup")} className="hidden rounded-full px-3.5 py-2 hover:text-ink md:inline">
            How it works
          </a>
          <a href={at("questions")} className="hidden rounded-full px-3.5 py-2 hover:text-ink lg:inline">
            Questions
          </a>
          <a href={GITHUB} className="hidden rounded-full px-3.5 py-2 hover:text-ink sm:inline">
            GitHub
          </a>
          <a href={at("download")} className="btn btn-ink ml-1 !min-h-11 !px-5 !py-2">
            Download
          </a>
        </nav>
      </div>
    </header>
  );
}
