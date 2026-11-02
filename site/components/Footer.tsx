// SPDX-License-Identifier: GPL-3.0-or-later
import Link from "next/link";

const GITHUB = "https://github.com/sandunMadhushan/pairdesk";

export default function Footer() {
  return (
    <footer className="relative mt-24 overflow-hidden bg-pair text-white sm:mt-32">
      <svg aria-hidden="true" viewBox="0 0 1200 300" preserveAspectRatio="none" className="pointer-events-none absolute inset-0 h-full w-full text-white/10" fill="none">
        <path d="M-40 240 C 220 60, 480 300, 760 120 S 1140 60, 1260 180" stroke="currentColor" strokeWidth="2" />
      </svg>
      <div className="relative mx-auto grid max-w-7xl gap-10 px-4 py-16 sm:px-6 md:grid-cols-[1.4fr_1fr_1fr] lg:py-20">
        <div className="max-w-sm">
          <p className="flex items-center gap-2.5 text-xl font-semibold">
            <span className="grid size-9 place-items-center rounded-xl bg-white">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src="/icon.svg" alt="" width={26} height={26} />
            </span>
            PairDesk
          </p>
          <p className="mt-4 text-white/80">Free software under the GPL-3.0-or-later licence.</p>
          <p className="mt-2 text-white/80">
            Built by{" "}
            <a
              href="https://madhushan.me"
              className="font-semibold text-white underline decoration-white/40 underline-offset-4 hover:decoration-white"
            >
              Sandun Madhushan
            </a>
          </p>
          <a href="/#download" className="btn btn-white mt-7">
            Download PairDesk
          </a>
        </div>
        <nav aria-label="Project">
          <h2 className="font-semibold">Project</h2>
          <ul className="mt-4 grid gap-2.5 text-white/80">
            <li>
              <a href={GITHUB} className="hover:text-white hover:underline">
                Source code
              </a>
            </li>
            <li>
              <a href={`${GITHUB}/releases`} className="hover:text-white hover:underline">
                All releases
              </a>
            </li>
            <li>
              <a href={`${GITHUB}/issues`} className="hover:text-white hover:underline">
                Report a problem
              </a>
            </li>
          </ul>
        </nav>
        <nav aria-label="Policies">
          <h2 className="font-semibold">Policies</h2>
          <ul className="mt-4 grid gap-2.5 text-white/80">
            <li>
              <Link href="/privacy" className="hover:text-white hover:underline">
                Privacy
              </Link>
            </li>
            <li>
              <Link href="/code-signing" className="hover:text-white hover:underline">
                Code signing policy
              </Link>
            </li>
          </ul>
        </nav>
      </div>
      <p aria-hidden="true" className="relative -mb-[0.18em] text-center text-[clamp(4rem,20vw,17rem)] leading-[0.8] font-bold tracking-[-0.05em] text-white/[0.08] select-none">
        PairDesk
      </p>
    </footer>
  );
}
