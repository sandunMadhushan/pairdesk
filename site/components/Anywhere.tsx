// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect, useRef, useState } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import type { Globe } from "@/lib/globe";

/* Home in Sri Lanka, a relay hop, and the phone travelling in Europe. */
const PINS = [
  { lat: 7.3, lng: 80.6, color: 0x1f5bff },
  { lat: 25, lng: 55, color: 0x141a2e },
  { lat: 48.9, lng: 2.35, color: 0xff7a1a },
];
const LABELS = [
  { title: "Your computer", sub: "awake at home" },
  { title: "Relay", sub: "passes sealed data only" },
  { title: "Your phone", sub: "on another network" },
];

export default function Anywhere() {
  const stage = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const labels = useRef<(HTMLDivElement | null)[]>([]);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    gsap.registerPlugin(ScrollTrigger);
    const el = canvas.current;
    const box = stage.current;
    if (!el || !box) return;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let globe: Globe | null = null;
    let disposed = false;
    const cleanups: (() => void)[] = [];

    Promise.all([import("@/lib/globe"), import("@/lib/land-dots.json")])
      .then(([{ Globe }, dots]) => {
        if (disposed) return;
        try {
          globe = new Globe(el, (dots as unknown as { default: number[] }).default, PINS, reduced);
        } catch {
          setFailed(true);
          return;
        }
        const g = globe;
        g.onFrame = (pts) =>
          pts.forEach((p, i) => {
            const l = labels.current[i];
            if (!l) return;
            l.style.transform = `translate(${p.x}px, ${p.y}px)`;
            l.style.opacity = p.front ? "1" : "0";
          });
        const fit = () => g.resize(el.clientWidth, el.clientHeight);
        fit();
        const ro = new ResizeObserver(fit);
        ro.observe(el);
        cleanups.push(() => ro.disconnect());

        if (reduced) g.setReveal(1);
        else {
          const st = ScrollTrigger.create({
            trigger: box,
            start: "top 85%",
            end: "center 45%",
            scrub: 0.6,
            onUpdate: (s) => g.setReveal(s.progress),
          });
          cleanups.push(() => st.kill());
        }

        const io = new IntersectionObserver(([e]) => (e.isIntersecting ? g.start() : g.stop()));
        io.observe(el);
        cleanups.push(() => io.disconnect());
      })
      .catch(() => setFailed(true));

    return () => {
      disposed = true;
      cleanups.forEach((c) => c());
      globe?.dispose();
    };
  }, []);

  return (
    <section id="anywhere" aria-labelledby="anywhere-title" className="scroll-mt-20 px-3 sm:px-6">
      <div data-sheet className="sheet mx-auto max-w-7xl overflow-hidden">
        <div className="grid items-center gap-6 p-7 sm:p-12 lg:grid-cols-[0.9fr_1.1fr] lg:gap-10 lg:p-16">
          <div className="max-w-xl">
            <h2 id="anywhere-title" className="display text-[clamp(2.2rem,4.4vw,3.6rem)]">
              From the next room, or the next country
            </h2>
            <p className="mt-5 text-lg text-slate">
              At home it connects over Wi-Fi. Away, it goes through Tailscale if you use it, or through the PairDesk
              relay. Either way the connection is encrypted between your phone and your computer, and nobody in
              between can read it.
            </p>
            <dl data-pop className="mt-9 grid grid-cols-3 gap-4 border-t border-line pt-7">
              {[
                ["Wi-Fi", "at home"],
                ["Tailscale", "if you have it"],
                ["Relay", "everywhere else"],
              ].map(([k, v]) => (
                <div key={k} data-pop-item>
                  <dt className="text-xl font-semibold tracking-tight">{k}</dt>
                  <dd className="text-[0.95rem] text-slate">{v}</dd>
                </div>
              ))}
            </dl>
          </div>

          <div ref={stage} className="relative mx-auto aspect-square w-full max-w-[600px]">
            {!failed && <canvas ref={canvas} className="absolute inset-0 h-full w-full" aria-hidden="true" />}
            {failed && (
              <p className="hand absolute inset-0 grid place-items-center text-center text-3xl text-marker">
                home, relay, phone
              </p>
            )}
            {/* labels follow the pins */}
            {!failed &&
              LABELS.map((l, i) => (
                <div
                  key={l.title}
                  ref={(n) => {
                    labels.current[i] = n;
                  }}
                  className="pointer-events-none absolute top-0 left-0 opacity-0 transition-opacity duration-300"
                >
                  <div className={`chip -translate-x-1/2 -translate-y-[calc(100%+14px)] !rounded-2xl !py-2 ${i === 1 ? "!bg-ink text-white" : ""}`}>
                    <span className="leading-tight">
                      <b className="block text-[0.85rem] font-semibold">{l.title}</b>
                      <span className={`text-[0.75rem] ${i === 1 ? "text-white/70" : "text-slate"}`}>{l.sub}</span>
                    </span>
                  </div>
                </div>
              ))}
          </div>
        </div>
      </div>
    </section>
  );
}
