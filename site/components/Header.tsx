// SPDX-License-Identifier: GPL-3.0-or-later
import Link from "next/link";

const GITHUB = "https://github.com/sandunMadhushan/pairdesk";

export default function Header({ home = false }: { home?: boolean }) {
  const at = (id: string) => (home ? `#${id}` : `/#${id}`);
  return (
    <header className="fixed inset-x-0 top-0 z-50 border-b border-white/5 bg-night/70 backdrop-blur-md">
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-4 sm:px-6">
        <Link href="/" className="flex items-center gap-2.5 font-display text-lg font-bold tracking-tight">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/icon.svg" alt="" width={30} height={30} />
          PairDesk
        </Link>
        <nav aria-label="Main" className="flex items-center gap-1 text-[0.95rem] text-mist sm:gap-2">
          <a href={at("setup")} className="hidden rounded-full px-3 py-1.5 hover:text-ink md:inline">
            How it works
          </a>
          <a href={at("questions")} className="hidden rounded-full px-3 py-1.5 hover:text-ink md:inline">
            Questions
          </a>
          <a href={GITHUB} className="hidden rounded-full px-3 py-1.5 hover:text-ink sm:inline">
            GitHub
          </a>
          <a
            href={at("download")}
            className="ml-1 rounded-full bg-blue px-4 py-1.5 font-semibold text-white transition-colors hover:bg-blue-deep"
          >
            Download
          </a>
        </nav>
      </div>
    </header>
  );
}
