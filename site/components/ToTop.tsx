// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect, useState } from "react";

type Smooth = { scrollTo: (to: number, o?: { duration?: number }) => void };

/** A round button in the corner that appears after scrolling down a screen. */
export default function ToTop() {
  const [shown, setShown] = useState(false);

  useEffect(() => {
    const check = () => setShown(window.scrollY > window.innerHeight * 1.2);
    check();
    window.addEventListener("scroll", check, { passive: true });
    return () => window.removeEventListener("scroll", check);
  }, []);

  const up = () => {
    const lenis = (window as Window & { __lenis?: Smooth }).__lenis;
    if (lenis) lenis.scrollTo(0, { duration: 1.1 });
    else window.scrollTo({ top: 0, behavior: "smooth" });
  };

  return (
    <button
      type="button"
      onClick={up}
      aria-label="Back to top"
      tabIndex={shown ? 0 : -1}
      className={`fixed bottom-5 right-5 z-50 grid h-12 w-12 place-items-center rounded-full bg-ink text-lime shadow-[0_12px_30px_-10px_rgba(17,17,17,.6)] ring-1 ring-white/10 transition duration-300 hover:-translate-y-0.5 sm:bottom-8 sm:right-8 ${
        shown ? "translate-y-0 opacity-100" : "pointer-events-none translate-y-4 opacity-0"
      }`}
    >
      <svg aria-hidden="true" viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
        <path d="M12 19V5M5 12l7-7 7 7" />
      </svg>
    </button>
  );
}
