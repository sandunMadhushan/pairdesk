// SPDX-License-Identifier: GPL-3.0-or-later
import Link from "next/link";

const GITHUB = "https://github.com/sandunMadhushan/pairdesk";

export default function Footer() {
  return (
    <footer className="border-t border-line/70">
      <div className="mx-auto flex max-w-7xl flex-col gap-6 px-4 py-12 text-[0.95rem] text-mist sm:px-6 md:flex-row md:items-end md:justify-between">
        <div className="max-w-md">
          <p className="flex items-center gap-2 font-display text-lg font-bold text-ink">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src="/icon.svg" alt="" width={24} height={24} />
            PairDesk
          </p>
          <p className="mt-2">Free software under the GPL-3.0-or-later licence, made by Sandun Madhushan.</p>
        </div>
        <nav aria-label="Footer" className="flex flex-wrap gap-x-6 gap-y-2">
          <Link href="/privacy" className="hover:text-ink">
            Privacy
          </Link>
          <Link href="/code-signing" className="hover:text-ink">
            Code signing policy
          </Link>
          <a href={GITHUB} className="hover:text-ink">
            Source code
          </a>
          <a href={`${GITHUB}/issues`} className="hover:text-ink">
            Report a problem
          </a>
        </nav>
      </div>
    </footer>
  );
}
