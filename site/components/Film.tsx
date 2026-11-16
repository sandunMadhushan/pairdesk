// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect, useRef, useState } from "react";

// The 38-second film, right under the hero.
//
// Three sizes of the same film (1080p 1.9 MB, 720p 1.2 MB, 480p 0.7 MB). The
// page starts with 720p so loading begins at once, then switches to a smaller
// or bigger one for the connection and screen, and steps down by itself if
// playback stalls.
//
// It plays with sound when it scrolls into view. Browsers only allow that after
// the person has used the page (a click, a tap, a key), so before that it plays
// muted and the first tap or key anywhere switches the sound on.
const SRC = {
  hi: "/video/pairdesk-film-1080.mp4",
  mid: "/video/pairdesk-film-720.mp4",
  low: "/video/pairdesk-film-480.mp4",
} as const;
type Tier = keyof typeof SRC;

type Connection = { saveData?: boolean; effectiveType?: string; downlink?: number };

function pickTier(width: number): Tier {
  const c = (navigator as Navigator & { connection?: Connection }).connection;
  const type = c?.effectiveType;
  if (c?.saveData) return "low";
  if (type === "slow-2g" || type === "2g" || type === "3g") return "low";
  if (c?.downlink !== undefined && c.downlink < 2.5) return "low";
  if (width >= 900 && (!type || type === "4g") && (c?.downlink === undefined || c.downlink >= 8)) {
    return "hi";
  }
  return "mid";
}

const stepDown: Record<Tier, Tier> = { hi: "mid", mid: "low", low: "low" };

const ICON = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 2,
  strokeLinecap: "round",
  strokeLinejoin: "round",
} as const;

const pill =
  "flex items-center gap-2 rounded-full bg-white/90 p-2 text-sm font-semibold text-ink shadow-lg backdrop-blur transition hover:bg-white sm:px-4 sm:py-2.5";

export default function Film() {
  const video = useRef<HTMLVideoElement>(null);
  const controls = useRef<HTMLDivElement>(null);
  const [muted, setMuted] = useState(true);
  const [blocked, setBlocked] = useState(false); // wants sound, browser says not yet
  const [ended, setEnded] = useState(false);
  const [still, setStill] = useState(false);

  // What the person wants, kept outside React so the listeners always see it.
  const wantSound = useRef(true);
  const inView = useRef(false);
  const done = useRef(false);
  const tier = useRef<Tier>("mid");

  useEffect(() => {
    const v = video.current;
    if (!v) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    setStill(reduce);

    const switchTo = (next: Tier) => {
      if (tier.current === next) return;
      const at = v.currentTime;
      const playing = !v.paused && !v.ended;
      tier.current = next;
      v.addEventListener(
        "loadedmetadata",
        () => {
          if (at > 0.1) v.currentTime = at;
          if (playing) v.play().catch(() => {});
        },
        { once: true },
      );
      v.src = SRC[next];
      v.load();
    };
    switchTo(pickTier(v.clientWidth));

    if (reduce) return;

    const sound = (on: boolean) => {
      v.muted = !on;
      setMuted(!on);
      if (on) setBlocked(false);
    };

    const start = async () => {
      if (done.current) return;
      if (wantSound.current) {
        v.muted = false;
        try {
          await v.play();
          sound(true);
          return;
        } catch {
          // The browser wants a tap first: play muted and wait for one.
        }
      }
      sound(false);
      setBlocked(wantSound.current);
      v.play().catch(() => {});
    };

    const seen = new IntersectionObserver(
      ([e]) => {
        inView.current = e.isIntersecting;
        if (e.isIntersecting) void start();
        else v.pause();
      },
      { threshold: 0.5 },
    );
    seen.observe(v);

    // The first tap, click or key anywhere on the page unlocks sound.
    const unlock = (e: Event) => {
      if (controls.current?.contains(e.target as Node)) return;
      off();
      if (wantSound.current && v.muted && inView.current && !done.current) {
        sound(true);
        if (v.paused) v.play().catch(() => {});
      }
    };
    const kinds = ["pointerdown", "touchend", "keydown"] as const;
    const off = () => kinds.forEach((k) => document.removeEventListener(k, unlock, true));
    kinds.forEach((k) => document.addEventListener(k, unlock, true));

    // If it stalls for more than a moment, go to a smaller file and carry on.
    let stall: number | undefined;
    const waiting = () => {
      window.clearTimeout(stall);
      stall = window.setTimeout(() => {
        if (v.readyState < 3 && !v.paused) switchTo(stepDown[tier.current]);
      }, 1800);
    };
    const flowing = () => window.clearTimeout(stall);
    const finished = () => {
      done.current = true;
      setEnded(true);
    };
    v.addEventListener("waiting", waiting);
    v.addEventListener("playing", flowing);
    v.addEventListener("canplay", flowing);
    v.addEventListener("ended", finished);

    return () => {
      seen.disconnect();
      off();
      window.clearTimeout(stall);
      v.removeEventListener("waiting", waiting);
      v.removeEventListener("playing", flowing);
      v.removeEventListener("canplay", flowing);
      v.removeEventListener("ended", finished);
    };
  }, []);

  const toggleSound = () => {
    const v = video.current;
    if (!v) return;
    wantSound.current = v.muted; // muted now → they want sound; playing → they don't
    v.muted = !v.muted;
    setMuted(v.muted);
    setBlocked(false);
    if (!v.muted && v.paused && !done.current) v.play().catch(() => {});
  };

  const replay = () => {
    const v = video.current;
    if (!v) return;
    done.current = false;
    setEnded(false);
    v.currentTime = 0;
    // Pressing the button is a tap, so sound is allowed unless they turned it off.
    v.muted = !wantSound.current;
    setMuted(v.muted);
    setBlocked(false);
    v.play().catch(() => {
      v.muted = true;
      setMuted(true);
      v.play().catch(() => {});
    });
  };

  return (
    <section aria-labelledby="film-title" className="px-3 sm:px-6">
      <div className="mx-auto max-w-7xl">
        <div className="mb-6 flex flex-wrap items-end justify-between gap-4 px-2">
          <h2 id="film-title" className="display text-[clamp(2rem,4vw,3.2rem)]">
            See it in action
          </h2>
          <p className="text-slate">PairDesk in 38 seconds</p>
        </div>
        <div
          data-sheet
          className="relative overflow-hidden rounded-[clamp(22px,3.4vw,40px)] bg-ink ring-1 ring-line shadow-[0_40px_80px_-40px_rgba(17,17,17,.55)]"
        >
          <video
            ref={video}
            className="block aspect-video w-full"
            src={SRC.mid}
            poster="/video/pairdesk-film-poster.jpg"
            muted
            playsInline
            preload="auto"
            controls={still}
            aria-label="A 38-second film: pairing a phone with a computer, then using it as a touchpad and keyboard, seeing the screen, sending files and the clipboard, shortcuts, sound and apps, on Windows, macOS and Linux with Android and iPhone."
          />
          {!still && (
            <div ref={controls} className="absolute bottom-2.5 right-2.5 z-10 flex gap-1.5 sm:bottom-6 sm:right-6 sm:gap-2">
              <button type="button" onClick={replay} className={pill}>
                <svg aria-hidden="true" viewBox="0 0 24 24" className="h-4 w-4 sm:h-5 sm:w-5" {...ICON}>
                  <path d="M3 12a9 9 0 1 0 3-6.7" />
                  <path d="M3 4v5h5" />
                </svg>
                <span className="sr-only sm:not-sr-only">Replay</span>
              </button>
              <button
                type="button"
                onClick={toggleSound}
                aria-pressed={!muted}
                className={`${pill} ${blocked ? "animate-pulse ring-4 ring-lime" : ""}`}
              >
                <svg aria-hidden="true" viewBox="0 0 24 24" className="h-4 w-4 sm:h-5 sm:w-5" {...ICON}>
                  <path d="M4 9v6h4l5 4V5L8 9z" />
                  {muted ? (
                    <path d="M17 9l5 5M22 9l-5 5" />
                  ) : (
                    <path d="M16.5 8.5a5 5 0 0 1 0 7M19 6a8.5 8.5 0 0 1 0 12" />
                  )}
                </svg>
                <span className="sr-only sm:not-sr-only">{muted ? (blocked ? "Tap for sound" : "Sound on") : "Sound off"}</span>
              </button>
            </div>
          )}
          {ended && !still && (
            <button
              type="button"
              onClick={replay}
              aria-label="Replay the film"
              className="absolute inset-0 grid place-items-center bg-ink/35 transition hover:bg-ink/25"
            >
              <span className="grid h-14 w-14 place-items-center rounded-full bg-lime sm:h-20 sm:w-20 text-ink shadow-xl">
                <svg aria-hidden="true" viewBox="0 0 24 24" className="h-7 w-7 sm:h-9 sm:w-9" {...ICON}>
                  <path d="M3 12a9 9 0 1 0 3-6.7" />
                  <path d="M3 4v5h5" />
                </svg>
              </span>
            </button>
          )}
        </div>
      </div>
    </section>
  );
}
