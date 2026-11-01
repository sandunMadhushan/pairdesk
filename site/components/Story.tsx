// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { Fragment, useEffect, useRef, useState } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import type { PairScene } from "@/lib/scene";

const GITHUB = "https://github.com/sandunMadhushan/pairdesk";

const CHAPTERS = [
  {
    title: "Touchpad and keyboard",
    body: "Move, click, drag and scroll with the gestures you already know. Type with your phone's keyboard, voice typing included, and keep your shortcuts and media keys one tap away.",
  },
  {
    title: "The screen in your hand",
    body: "See the computer's screen on your phone and work on it right there. Pinch to zoom and the view follows the pointer. On Windows it even reaches the lock screen and admin prompts.",
  },
  {
    title: "Files, clipboard and sound, both ways",
    body: "Share a photo to PairDesk and it lands in the computer's Downloads. Copy on one, paste on the other. Hear what the computer plays, and talk through its speakers.",
  },
  {
    title: "From anywhere, and for a friend",
    body: "At home it connects over Wi-Fi. Away, it goes through Tailscale or the PairDesk relay, encrypted end to end. If a friend is stuck, they press Get help and send you a link for two hours of limited access.",
  },
];

export default function Story() {
  const section = useRef<HTMLElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const headline = useRef<HTMLHeadingElement>(null);
  const [fallback, setFallback] = useState(false);

  useEffect(() => {
    gsap.registerPlugin(ScrollTrigger);
    const el = canvas.current;
    const sec = section.current;
    if (!el || !sec) return;

    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const lowPower = window.matchMedia("(pointer: coarse)").matches || (navigator.hardwareConcurrency ?? 8) <= 4;
    let scene: PairScene | null = null;
    let disposed = false;
    const cleanups: (() => void)[] = [];

    // Headline: the one orchestrated entrance on the page.
    const words = headline.current?.querySelectorAll("[data-word]");
    if (words && !reduced) {
      gsap.fromTo(
        words,
        { yPercent: 110 },
        { yPercent: 0, duration: 1.1, ease: "expo.out", stagger: 0.07, delay: 0.15 },
      );
    }

    import("@/lib/scene")
      .then(({ PairScene }) => {
        if (disposed) return;
        try {
          scene = new PairScene(el, { reducedMotion: reduced, lowPower });
        } catch {
          setFallback(true);
          return;
        }
        const s = scene;
        const fit = () => s.resize(el.clientWidth, el.clientHeight);
        fit();
        const ro = new ResizeObserver(fit);
        ro.observe(el);
        cleanups.push(() => ro.disconnect());

        const st = ScrollTrigger.create({
          trigger: sec,
          start: "top top",
          end: "bottom bottom",
          scrub: reduced ? false : 0.6,
          onUpdate: (self) => {
            s.setProgress(self.progress);
          },
        });
        cleanups.push(() => st.kill());

        if (!reduced) {
          const intro = { v: 0 };
          const tw = gsap.to(intro, {
            v: 1,
            duration: 2.6,
            ease: "power2.out",
            delay: 0.1,
            onUpdate: () => s.setIntro(intro.v),
          });
          cleanups.push(() => tw.kill());
          const move = (e: PointerEvent) => {
            if (e.pointerType !== "mouse") return;
            s.setPointer((e.clientX / window.innerWidth) * 2 - 1, (e.clientY / window.innerHeight) * 2 - 1);
          };
          window.addEventListener("pointermove", move, { passive: true });
          cleanups.push(() => window.removeEventListener("pointermove", move));
        }

        // Only draw while the stage is on screen and the tab is visible.
        let visible = true;
        const sync = () => (visible && !document.hidden ? s.start() : s.stop());
        const io = new IntersectionObserver(([entry]) => {
          visible = entry.isIntersecting;
          sync();
        });
        io.observe(el);
        document.addEventListener("visibilitychange", sync);
        cleanups.push(() => {
          io.disconnect();
          document.removeEventListener("visibilitychange", sync);
        });
        sync();
      })
      .catch(() => setFallback(true));

    return () => {
      disposed = true;
      cleanups.forEach((c) => c());
      scene?.dispose();
    };
  }, []);

  const headlineWords = "Your phone is the remote for your computer.".split(" ");

  return (
    <section ref={section} id="top" aria-label="What PairDesk does" className="relative">
      {/* The stage: stays in place while the chapters scroll past. */}
      <div className="sticky top-0 h-svh w-full overflow-hidden" aria-hidden="true">
        <div className="absolute inset-0 bg-[radial-gradient(ellipse_70%_60%_at_68%_45%,#16245a_0%,transparent_70%)] max-md:bg-[radial-gradient(ellipse_90%_45%_at_50%_30%,#16245a_0%,transparent_70%)]" />
        {fallback ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src="/screenshots/2_touchpad.png"
            alt=""
            className="absolute top-[14%] right-[12%] w-[min(40vw,260px)] rotate-3 rounded-[28px] border border-white/10 max-md:top-[10%] max-md:right-1/2 max-md:w-40 max-md:translate-x-1/2"
          />
        ) : (
          <canvas ref={canvas} className="absolute inset-0 h-full w-full" />
        )}
        {/* Keeps the text readable over the scene. */}
        <div className="absolute inset-0 bg-[linear-gradient(90deg,var(--color-night)_0%,color-mix(in_oklab,var(--color-night)_75%,transparent)_30%,transparent_58%)] max-md:bg-[linear-gradient(0deg,var(--color-night)_0%,color-mix(in_oklab,var(--color-night)_85%,transparent)_38%,transparent_62%)]" />
      </div>

      <div className="relative -mt-[100svh]">
        {/* Hero */}
        <div className="mx-auto flex min-h-svh max-w-7xl flex-col justify-center px-4 pt-24 pb-16 max-md:justify-start max-md:pt-[40svh] sm:px-6">
          <h1 ref={headline} className="display max-w-[11ch] text-[clamp(3rem,7.6vw,6.8rem)]">
            {headlineWords.map((w, k) => (
              <Fragment key={k}>
                <span className="inline-block overflow-hidden pb-[0.08em] align-bottom">
                  <span data-word className="inline-block">
                    {w}
                  </span>
                </span>
                {k < headlineWords.length - 1 ? " " : null}
              </Fragment>
            ))}
          </h1>
          <p className="mt-7 max-w-[34rem] text-lg text-mist sm:text-xl">
            Use your Android phone as a touchpad and keyboard, see and control the screen, send files and talk
            through the computer. Pair once, then just open the app. Free and open source, with no account.
          </p>
          <div className="mt-9 flex flex-wrap items-center gap-3">
            <a
              href="#download"
              className="rounded-full bg-blue px-6 py-3 text-[1.05rem] font-semibold text-white shadow-[0_8px_30px_-8px_#3a74f0] transition-colors hover:bg-blue-deep"
            >
              Download PairDesk
            </a>
            <a
              href={GITHUB}
              className="rounded-full border border-white/15 px-6 py-3 text-[1.05rem] font-semibold transition-colors hover:border-white/40"
            >
              View the source
            </a>
          </div>
          <p className="mt-6 text-[0.95rem] text-mist">For Windows 10 and 11, Linux, and Android 6 or newer.</p>
        </div>

        {/* Chapters */}
        {CHAPTERS.map((c) => (
          <div
            key={c.title}
            className="mx-auto flex min-h-svh max-w-7xl items-center px-4 max-md:items-end max-md:pb-[12svh] sm:px-6"
          >
            <div className="max-w-md">
              <h2 className="text-[clamp(2.1rem,4.4vw,3.4rem)] leading-[1.02] font-bold tracking-[-0.03em]">
                {c.title}
              </h2>
              <p className="mt-5 text-lg text-mist">{c.body}</p>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}
