// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect, useRef, useState } from "react";
import { Squiggle } from "@/components/Devices";

/** A simple flat person; skin, hair and shirt vary. */
function Avatar({ skin, hair, shirt, long = false }: { skin: string; hair: string; shirt: string; long?: boolean }) {
  return (
    <svg viewBox="0 0 80 80" className="h-full w-full" aria-hidden="true">
      <circle cx="40" cy="40" r="40" fill="#eef3fb" />
      <clipPath id={`c-${shirt.slice(1)}`}>
        <circle cx="40" cy="40" r="40" />
      </clipPath>
      <g clipPath={`url(#c-${shirt.slice(1)})`}>
        {long && <path d="M18 44 Q16 18 40 16 Q64 18 62 44 L62 66 L18 66 Z" fill={hair} />}
        <path d="M14 82 Q16 58 40 56 Q64 58 66 82 Z" fill={shirt} />
        <rect x="34" y="46" width="12" height="12" rx="5" fill={skin} />
        <ellipse cx="40" cy="36" rx="15" ry="17" fill={skin} />
        <path d="M24 34 Q24 16 40 16 Q57 16 56 34 Q50 24 40 25 Q30 24 24 34 Z" fill={hair} />
        <circle cx="34" cy="37" r="1.8" fill="#1d2235" />
        <circle cx="46" cy="37" r="1.8" fill="#1d2235" />
        <path d="M35 44 Q40 48 45 44" stroke="#1d2235" strokeWidth="1.8" fill="none" strokeLinecap="round" />
      </g>
    </svg>
  );
}

function Countdown() {
  const box = useRef<HTMLSpanElement>(null);
  const [left, setLeft] = useState(2 * 3600 - 23);
  useEffect(() => {
    const el = box.current;
    if (!el || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    let id: ReturnType<typeof setInterval> | undefined;
    const io = new IntersectionObserver(([e]) => {
      clearInterval(id);
      if (e.isIntersecting) id = setInterval(() => setLeft((v) => (v > 0 ? v - 1 : 2 * 3600)), 1000);
    });
    io.observe(el);
    return () => {
      io.disconnect();
      clearInterval(id);
    };
  }, []);
  const h = Math.floor(left / 3600);
  const m = String(Math.floor((left % 3600) / 60)).padStart(2, "0");
  const s = String(left % 60).padStart(2, "0");
  return (
    <span ref={box} className="tabular-nums">
      {h}:{m}:{s}
    </span>
  );
}

export default function Help() {
  return (
    <section id="help" aria-labelledby="help-title" className="scroll-mt-20 px-3 sm:px-6">
      <div data-sheet className="sheet mx-auto max-w-7xl overflow-hidden">
        <div className="grid items-center gap-12 p-7 sm:p-12 lg:grid-cols-2 lg:gap-16 lg:p-16">
          <div className="max-w-xl">
            <h2 id="help-title" className="display text-[clamp(2.2rem,4.4vw,3.6rem)]">
              A friend is stuck? Help them from your phone.
            </h2>
            <p className="mt-5 text-lg text-slate">
              They press <b className="text-ink">Get help</b> on their computer and send you the link in any chat. You
              tap it, and you&apos;re looking at their screen.
            </p>
            <p className="mt-4 text-lg text-slate">
              Helpers can see and control the screen, and nothing more: no power buttons, no files, no listening.
              It ends after two hours, when you leave, or the moment they press End help.
            </p>
          </div>

          <div data-pop className="relative mx-auto aspect-[1/1.3] w-full max-w-[560px] text-[0.85rem] sm:aspect-[1/0.9] sm:text-[0.95rem]">
            <div aria-hidden="true" className="absolute inset-[8%_4%_6%_10%] rounded-[36px] bg-[linear-gradient(160deg,#e7eeff,#f3f6fd)]" />
            <svg aria-hidden="true" viewBox="0 0 500 450" className="absolute inset-0 h-full w-full text-[#b9c8ea]" fill="none">
              <path data-draw d="M120 130 C 200 160, 260 140, 330 210 S 380 330, 300 360" stroke="currentColor" strokeWidth="2.5" strokeDasharray="2 10" strokeLinecap="round" />
            </svg>

            {/* the friend */}
            <div data-pop-item className="absolute top-[4%] left-[2%] w-[26%]">
              <div className="aspect-square overflow-hidden rounded-full shadow-[0_18px_40px_-16px_rgba(31,58,120,.5)] ring-4 ring-white">
                <Avatar skin="#e8b796" hair="#3b2a20" shirt="#ff7a1a" long />
              </div>
            </div>
            <div data-pop-item className="absolute top-[6%] left-[30%] max-w-[62%]">
              <p className="rounded-[20px] rounded-tl-md bg-white px-4 py-3 shadow-[0_18px_40px_-18px_rgba(31,58,120,.45)]">
                My printer vanished again. Can you have a look?
              </p>
            </div>

            {/* you */}
            <div data-pop-item className="absolute top-[30%] right-[2%] w-[22%]">
              <div className="aspect-square overflow-hidden rounded-full shadow-[0_18px_40px_-16px_rgba(31,58,120,.5)] ring-4 ring-white">
                <Avatar skin="#b9805a" hair="#141a2e" shirt="#1f5bff" />
              </div>
            </div>
            <div data-pop-item className="absolute top-[36%] right-[26%] max-w-[64%] sm:top-[38%] sm:max-w-[58%]">
              <p className="rounded-[20px] rounded-tr-md bg-pair px-4 py-3 text-white shadow-[0_18px_40px_-18px_var(--color-pair)]">
                Press Get help and send me the link.
              </p>
            </div>

            {/* the link */}
            <div data-pop-item className="absolute top-[58%] left-[4%] sm:top-[60%] sm:left-[6%]">
              <span className="chip !rounded-2xl">
                <span className="grid size-9 place-items-center rounded-xl bg-pair-soft text-pair">
                  <svg viewBox="0 0 24 24" className="size-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
                    <path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1" />
                    <path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" />
                  </svg>
                </span>
                <span className="leading-tight">
                  <b className="block font-semibold">Help link</b>
                  <span className="text-[0.8rem] text-slate">pairdesk.madhushan.me/p#…</span>
                </span>
              </span>
            </div>

            {/* the timer */}
            <div data-pop-item className="absolute right-[8%] bottom-[4%]">
              <span className="chip !bg-ink !rounded-2xl text-white">
                <span className="ping relative size-2.5 rounded-full bg-go text-go" />
                <span className="leading-tight">
                  <b className="block font-semibold">
                    Helping, <Countdown /> left
                  </b>
                  <span className="text-[0.8rem] text-white/70">They can press End help any time</span>
                </span>
              </span>
            </div>

            <div data-pop-item className="absolute bottom-[22%] left-[44%] hidden text-marker sm:block">
              <Squiggle className="w-16 rotate-[20deg]" />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
