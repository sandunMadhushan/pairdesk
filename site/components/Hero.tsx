// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { Fragment, useEffect, useRef, useState } from "react";
import { gsap } from "gsap";
import { Cursor, Desktop, Laptop, Phone, Spark, Squiggle } from "@/components/Devices";

const GITHUB = "https://github.com/sandunMadhushan/pairdesk";
const WORDS = "Your phone is the remote for your computer.".split(" ");

/* The touchpad area inside 2_touchpad.png (540 × 1170), as fractions. */
const PAD = { left: 18 / 540, top: 172 / 1170, right: 522 / 540, bottom: 920 / 1170 };

export default function Hero() {
  const root = useRef<HTMLElement>(null);
  const screen = useRef<HTMLDivElement>(null);
  const pad = useRef<HTMLDivElement>(null);
  const cursor = useRef<SVGSVGElement>(null);
  const finger = useRef<HTMLSpanElement>(null);
  const ripple = useRef<HTMLSpanElement>(null);
  const [playing, setPlaying] = useState(true);

  useEffect(() => {
    const el = root.current;
    const scr = screen.current;
    const touch = pad.current;
    const cur = cursor.current;
    const fin = finger.current;
    const rip = ripple.current;
    if (!el || !scr || !touch || !cur || !fin || !rip) return;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    // Positions as fractions of the laptop screen (cursor) and the pad (finger).
    const p = { cx: 0.32, cy: 0.3, fx: 0.5, fy: 0.5, f: 0 };
    const draw = () => {
      cur.style.left = `${p.cx * 100}%`;
      cur.style.top = `${p.cy * 100}%`;
      fin.style.left = `${p.fx * 100}%`;
      fin.style.top = `${p.fy * 100}%`;
      fin.style.opacity = String(p.f);
    };
    draw();

    const click = () => {
      rip.style.left = `${p.cx * 100}%`;
      rip.style.top = `${p.cy * 100}%`;
      gsap.fromTo(rip, { scale: 0.2, opacity: 0.9 }, { scale: 1.6, opacity: 0, duration: 0.55, ease: "power2.out" });
      // Did the click land on the music card?
      const card = scr.querySelector<HTMLElement>("[data-target=play]");
      if (!card) return;
      const s = scr.getBoundingClientRect();
      const c = card.getBoundingClientRect();
      const x = s.left + p.cx * s.width;
      const y = s.top + p.cy * s.height;
      if (x >= c.left && x <= c.right && y >= c.top && y <= c.bottom) setPlaying((v) => !v);
    };

    const ctx = gsap.context(() => {
      // The one orchestrated entrance: words, then the devices, then the chips.
      if (!reduced) {
        const tl = gsap.timeline({ defaults: { ease: "expo.out" } });
        tl.from("[data-word]", { yPercent: 115, duration: 1.1, stagger: 0.06 }, 0.1)
          .from("[data-hero-copy]", { y: 18, opacity: 0, duration: 0.9, stagger: 0.08 }, 0.55)
          .from("[data-laptop]", { y: 90, rotateX: 18, opacity: 0, duration: 1.4 }, 0.35)
          .from("[data-phone]", { y: 160, rotate: -16, opacity: 0, duration: 1.4 }, 0.55)
          .from("[data-chip]", { scale: 0.4, opacity: 0, duration: 0.8, stagger: 0.12, ease: "back.out(1.8)" }, 1.1)
          .from("[data-note]", { opacity: 0, x: -10, duration: 0.6 }, 1.5);
      }
    }, el);

    // Autopilot: drags across the pad so the pointer travels to the music
    // card, taps it, wanders off, and does it again.
    let auto: gsap.core.Timeline | null = null;
    if (!reduced) {
      auto = gsap.timeline({ repeat: -1, delay: 2.2, defaults: { ease: "power2.inOut" } });
      auto
        .to(p, { f: 1, duration: 0.25, onUpdate: draw })
        .to(p, { cx: 0.72, cy: 0.62, fx: 0.72, fy: 0.7, duration: 1.4, onUpdate: draw })
        .to(p, { f: 0.4, duration: 0.12, yoyo: true, repeat: 1, onUpdate: draw, onComplete: click })
        .to(p, { f: 0, duration: 0.3, onUpdate: draw }, "+=0.3")
        .to(p, { fx: 0.45, fy: 0.4, duration: 0.01, onUpdate: draw })
        .to(p, { f: 1, duration: 0.25, onUpdate: draw }, "+=1.6")
        .to(p, { cx: 0.32, cy: 0.3, fx: 0.25, fy: 0.25, duration: 1.3, onUpdate: draw })
        .to(p, { f: 0, duration: 0.3, onUpdate: draw })
        .to(p, { fx: 0.5, fy: 0.5, duration: 0.01, onUpdate: draw }, "+=1.4");
    }

    // The real thing: drag on the phone's pad and the pointer follows.
    let last: { x: number; y: number; t: number; moved: number } | null = null;
    let idle: ReturnType<typeof setTimeout> | undefined;
    const down = (e: PointerEvent) => {
      touch.setPointerCapture(e.pointerId);
      auto?.pause();
      clearTimeout(idle);
      last = { x: e.clientX, y: e.clientY, t: performance.now(), moved: 0 };
      const r = touch.getBoundingClientRect();
      p.fx = (e.clientX - r.left) / r.width;
      p.fy = (e.clientY - r.top) / r.height;
      p.f = 1;
      draw();
    };
    const move = (e: PointerEvent) => {
      if (!last) return;
      const r = touch.getBoundingClientRect();
      const s = scr.getBoundingClientRect();
      const dx = e.clientX - last.x;
      const dy = e.clientY - last.y;
      last.moved += Math.abs(dx) + Math.abs(dy);
      last.x = e.clientX;
      last.y = e.clientY;
      const gain = 2.2;
      p.cx = Math.min(0.97, Math.max(0.01, p.cx + (dx * gain) / s.width));
      p.cy = Math.min(0.95, Math.max(0.01, p.cy + (dy * gain) / s.height));
      p.fx = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
      p.fy = Math.min(1, Math.max(0, (e.clientY - r.top) / r.height));
      draw();
    };
    const up = () => {
      if (!last) return;
      if (last.moved < 8 && performance.now() - last.t < 300) click();
      last = null;
      gsap.to(p, { f: 0, duration: 0.3, onUpdate: draw });
      idle = setTimeout(() => {
        if (!auto) return;
        gsap.to(p, {
          cx: 0.32,
          cy: 0.3,
          duration: 0.8,
          ease: "power2.inOut",
          onUpdate: draw,
          onComplete: () => void auto?.restart(true),
        });
      }, 5000);
    };
    touch.addEventListener("pointerdown", down);
    touch.addEventListener("pointermove", move);
    touch.addEventListener("pointerup", up);
    touch.addEventListener("pointercancel", up);

    // Stop the loop when the hero is off screen.
    const io = new IntersectionObserver(([en]) => {
      if (!auto || last) return;
      if (en.isIntersecting) auto.resume();
      else auto.pause();
    });
    io.observe(el);

    return () => {
      ctx.revert();
      auto?.kill();
      io.disconnect();
      clearTimeout(idle);
      touch.removeEventListener("pointerdown", down);
      touch.removeEventListener("pointermove", move);
      touch.removeEventListener("pointerup", up);
      touch.removeEventListener("pointercancel", up);
    };
  }, []);

  return (
    <section ref={root} id="top" aria-labelledby="hero-title" className="relative overflow-hidden pt-28 pb-16 sm:pt-32 lg:pb-24">
      {/* paper grid + a soft light behind the devices */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 [background-image:radial-gradient(#c9d4ea_1.2px,transparent_1.2px)] [background-size:26px_26px] [mask-image:radial-gradient(ellipse_80%_70%_at_70%_40%,#000_20%,transparent_75%)]"
      />
      <div aria-hidden="true" className="pointer-events-none absolute top-[8%] right-[-10%] size-[70vmax] rounded-full bg-[radial-gradient(circle,#ffffff_0%,rgba(255,255,255,0)_62%)]" />

      <div className="relative mx-auto grid max-w-7xl items-center gap-14 px-4 sm:px-6 lg:grid-cols-[1.02fr_1fr] lg:gap-6">
        <div className="relative z-10">
          <Spark className="absolute -top-9 left-[-6px] size-10 rotate-[-12deg] text-marker" />
          <h1 id="hero-title" className="display text-[clamp(3rem,7vw,6.2rem)] leading-[0.98]">
            {WORDS.map((w, k) => (
              <Fragment key={k}>
                <span className="inline-block overflow-hidden pb-[0.1em] align-bottom">
                  <span data-word className="inline-block">
                    {w}
                  </span>
                </span>
                {k < WORDS.length - 1 ? " " : null}
              </Fragment>
            ))}
          </h1>
          <p data-hero-copy className="mt-7 max-w-[32rem] text-lg text-slate sm:text-xl">
            Use your Android phone as a touchpad and keyboard, see and control the screen, send files and talk
            through the computer. Pair once, then just open the app. Free and open source, with no account.
          </p>
          <div data-hero-copy className="mt-9 flex flex-wrap items-center gap-3">
            <a href="#download" className="btn btn-ink">
              Download PairDesk
            </a>
            <a href={GITHUB} className="btn btn-line">
              View the source
            </a>
          </div>
          <p data-hero-copy className="mt-6 text-[0.95rem] text-slate">
            For Windows 10 and 11, Linux, and Android 6 or newer.
          </p>
        </div>

        {/* The stage */}
        <div className="relative mx-auto w-full max-w-[640px] [perspective:1400px] lg:max-w-none">
          <svg aria-hidden="true" viewBox="0 0 600 420" className="pointer-events-none absolute -top-[8%] -left-[6%] w-[112%] text-[#b9c8ea]" fill="none">
            <path data-draw d="M20 330 C 120 120, 420 40, 580 150" stroke="currentColor" strokeWidth="2" strokeDasharray="1 9" strokeLinecap="round" />
          </svg>

          <div data-laptop className="relative ml-[20%] w-[80%]">
            <Laptop screenRef={screen}>
              <Desktop playing={playing}>
                <span
                  ref={ripple}
                  aria-hidden="true"
                  className="pointer-events-none absolute -mt-[3cqw] -ml-[3cqw] size-[6cqw] rounded-full border-[0.5cqw] border-marker opacity-0"
                />
                <Cursor ref={cursor} className="w-[4.2cqw] -translate-x-[18%] -translate-y-[10%]" style={{ left: "32%", top: "30%" }} />
              </Desktop>
            </Laptop>
          </div>

          <div data-phone className="absolute bottom-[-14%] left-[-1%] w-[30%] min-w-[120px] rotate-[-6deg]">
            <Phone>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src="/screenshots/2_touchpad.png" alt="The PairDesk touchpad screen" width={540} height={1170} className="h-full w-full object-cover select-none" draggable={false} />
              <div
                ref={pad}
                role="img"
                aria-label="Try it: drag here to move the computer's pointer, tap to click"
                className="absolute cursor-grab touch-none rounded-[6%] active:cursor-grabbing"
                style={{
                  left: `${PAD.left * 100}%`,
                  top: `${PAD.top * 100}%`,
                  width: `${(PAD.right - PAD.left) * 100}%`,
                  height: `${(PAD.bottom - PAD.top) * 100}%`,
                }}
              >
                <span
                  ref={finger}
                  aria-hidden="true"
                  className="pointer-events-none absolute -mt-[9%] -ml-[9%] size-[18%] rounded-full bg-pair/25 opacity-0 ring-2 ring-pair/50"
                />
              </div>
            </Phone>
          </div>

          {/* chips */}
          <div data-chip className="absolute top-[-13%] right-[6%]">
            <span className="chip bob">
              <span className="ping relative size-2.5 rounded-full bg-go text-go" />
              <span>
                <b className="block font-semibold">Connected</b>
                <span className="text-[0.8rem] text-slate">Sandun-Laptop, Wi-Fi</span>
              </span>
            </span>
          </div>
          <div data-chip className="absolute right-[-2%] bottom-[-14%] sm:right-[2%]">
            <span className="chip bob-slow">
              <span className="grid size-9 place-items-center rounded-xl bg-pair-soft text-pair">
                <svg viewBox="0 0 24 24" className="size-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                  <path d="M12 4v11m0 0-4-4m4 4 4-4M5 20h14" />
                </svg>
              </span>
              <span>
                <b className="block font-semibold">photo.jpg</b>
                <span className="text-[0.8rem] text-slate">Saved in Downloads</span>
              </span>
            </span>
          </div>

          <div data-note className="absolute bottom-[-30%] left-[30%] hidden items-start gap-1 text-marker sm:flex lg:bottom-[-26%]">
            <Squiggle className="mt-[-30px] w-16 -scale-x-100 rotate-[200deg]" />
            <span className="hand text-[1.7rem]">go on, drag the touchpad</span>
          </div>
        </div>
      </div>
    </section>
  );
}
