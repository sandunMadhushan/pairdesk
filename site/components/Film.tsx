// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect, useRef, useState } from "react";

// The 38-second film, right under the hero.
//
// Four sizes of the same film (1080p 1.9 MB, 720p 1.2 MB, 480p 0.7 MB, 360p
// 0.4 MB). Like YouTube, the quality menu has "Auto" and the four sizes. Auto
// starts with the one that suits the connection and screen, then steps down by
// itself if playback stalls. A size the person picks is kept (in this browser)
// and never changed behind their back.
//
// It plays with sound when it scrolls into view. Browsers only allow that after
// the person has used the page (a click, a tap, a key), so before that it plays
// muted and the first tap or key anywhere switches the sound on.
const SRC = {
  "1080": "/video/pairdesk-film-1080.mp4",
  "720": "/video/pairdesk-film-720.mp4",
  "480": "/video/pairdesk-film-480.mp4",
  "360": "/video/pairdesk-film-360.mp4",
} as const;
type Tier = keyof typeof SRC;
type Choice = Tier | "auto";
const TIERS: Tier[] = ["1080", "720", "480", "360"];
const STORE = "pairdesk.film.quality";

type Connection = { saveData?: boolean; effectiveType?: string; downlink?: number };

function pickTier(width: number): Tier {
  const c = (navigator as Navigator & { connection?: Connection }).connection;
  const type = c?.effectiveType;
  if (c?.saveData || type === "slow-2g" || type === "2g") return "360";
  if (type === "3g" || (c?.downlink !== undefined && c.downlink < 2.5)) {
    return c?.downlink !== undefined && c.downlink < 1 ? "360" : "480";
  }
  if (width >= 900 && (!type || type === "4g") && (c?.downlink === undefined || c.downlink >= 8)) {
    return "1080";
  }
  return "720";
}

const stepDown: Record<Tier, Tier> = { "1080": "720", "720": "480", "480": "360", "360": "360" };

function saved(): Choice {
  try {
    const v = window.localStorage.getItem(STORE);
    if (v && (v === "auto" || v in SRC)) return v as Choice;
  } catch {
    // Storage can be blocked; Auto it is.
  }
  return "auto";
}

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
  const userPaused = useRef(false); // they paused it: scrolling back must not restart it
  const unlockedAt = useRef(0); // the tap that switched sound on must not also pause
  const [paused, setPaused] = useState(false);
  const tier = useRef<Tier>("720");
  const choice = useRef<Choice>("auto");
  const [playing, setPlaying] = useState<Tier>("720"); // the size loaded now
  const [pick, setPick] = useState<Choice>("auto"); // what the menu shows
  const [menu, setMenu] = useState(false);
  const quality = useRef<HTMLDivElement>(null);

  // Loads another size of the film and carries on from the same moment.
  const load = (next: Tier) => {
    const v = video.current;
    if (!v || tier.current === next) return;
    const at = v.currentTime;
    const playingNow = !v.paused && !v.ended;
    tier.current = next;
    setPlaying(next);
    v.addEventListener(
      "loadedmetadata",
      () => {
        if (at > 0.1) v.currentTime = at;
        if (playingNow) v.play().catch(() => {});
      },
      { once: true },
    );
    v.src = SRC[next];
    v.load();
  };

  useEffect(() => {
    const v = video.current;
    if (!v) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    setStill(reduce);

    choice.current = saved();
    setPick(choice.current);
    load(choice.current === "auto" ? pickTier(v.clientWidth) : choice.current);

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
        if (e.isIntersecting) {
          if (!userPaused.current) void start();
        }
        else v.pause();
      },
      { threshold: 0.5 },
    );
    seen.observe(v);

    // The first tap, click or key anywhere on the page unlocks sound.
    const unlock = (e: Event) => {
      const t = e.target as Node;
      if (controls.current?.contains(t) || quality.current?.contains(t)) return;
      off();
      if (wantSound.current && v.muted && inView.current && !done.current) {
        sound(true);
        unlockedAt.current = performance.now();
        if (v.paused && !userPaused.current) v.play().catch(() => {});
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
        if (choice.current === "auto" && v.readyState < 3 && !v.paused) load(stepDown[tier.current]);
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

  useEffect(() => {
    if (!menu) return;
    const away = (e: Event) => {
      if (!quality.current?.contains(e.target as Node)) setMenu(false);
    };
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setMenu(false);
    document.addEventListener("pointerdown", away);
    document.addEventListener("keydown", esc);
    return () => {
      document.removeEventListener("pointerdown", away);
      document.removeEventListener("keydown", esc);
    };
  }, [menu]);

  const choose = (c: Choice) => {
    const v = video.current;
    choice.current = c;
    setPick(c);
    setMenu(false);
    try {
      window.localStorage.setItem(STORE, c);
    } catch {
      // Not remembered; it still applies now.
    }
    if (v) load(c === "auto" ? pickTier(v.clientWidth) : c);
  };

  const toggleSound = () => {
    const v = video.current;
    if (!v) return;
    wantSound.current = v.muted; // muted now → they want sound; playing → they don't
    v.muted = !v.muted;
    setMuted(v.muted);
    setBlocked(false);
    if (!v.muted && v.paused && !done.current) v.play().catch(() => {});
  };

  // A tap or click on the picture plays or pauses it, on phones too.
  const tap = () => {
    const v = video.current;
    if (!v || still || done.current) return;
    if (performance.now() - unlockedAt.current < 600) return;
    if (v.paused) {
      userPaused.current = false;
      setPaused(false);
      v.play().catch(() => {});
    } else {
      userPaused.current = true;
      setPaused(true);
      v.pause();
    }
  };

  const replay = () => {
    const v = video.current;
    if (!v) return;
    done.current = false;
    userPaused.current = false;
    setPaused(false);
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
            className={`block aspect-video w-full ${still ? "" : "cursor-pointer"}`}
            onClick={tap}
            onKeyDown={(e) => {
              if (e.key === " " || e.key === "Enter") {
                e.preventDefault();
                tap();
              }
            }}
            tabIndex={still ? undefined : 0}
            src={SRC["720"]}
            poster="/video/pairdesk-film-poster.jpg"
            muted
            playsInline
            preload="auto"
            controls={still}
            aria-label="A 38-second film: pairing a phone with a computer, then using it as a touchpad and keyboard, seeing the screen, sending files and the clipboard, shortcuts, sound and apps, on Windows, macOS and Linux with Android and iPhone."
          />
          <div ref={quality} className="absolute right-2.5 top-2.5 z-10 sm:right-6 sm:top-6">
            <button
              type="button"
              onClick={() => setMenu((m) => !m)}
              aria-haspopup="menu"
              aria-expanded={menu}
              aria-label={`Video quality: ${pick === "auto" ? `Auto, ${playing}p` : `${pick}p`}`}
              className={pill}
            >
              <svg aria-hidden="true" viewBox="0 0 24 24" className="h-4 w-4 sm:h-5 sm:w-5" {...ICON}>
                <circle cx="12" cy="12" r="3" />
                <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" />
              </svg>
              <span>{pick === "auto" ? `Auto · ${playing}p` : `${pick}p`}</span>
            </button>
            {menu && (
              <ul
                role="menu"
                aria-label="Video quality"
                className="absolute right-0 mt-2 flex w-max max-w-[calc(100vw-2.5rem)] gap-1 rounded-full bg-white/95 p-1 text-xs font-semibold text-ink shadow-xl backdrop-blur sm:block sm:w-44 sm:max-w-none sm:overflow-hidden sm:rounded-2xl sm:p-0 sm:py-1 sm:text-sm"
              >
                {(["auto", ...TIERS] as Choice[]).map((c) => (
                  <li key={c} role="none">
                    <button
                      type="button"
                      role="menuitemradio"
                      aria-checked={pick === c}
                      onClick={() => choose(c)}
                      className={`flex w-full items-center justify-between gap-3 rounded-full px-3 py-2 text-left transition sm:rounded-none sm:px-4 sm:py-2.5 sm:hover:bg-ink/5 ${
                        pick === c ? "bg-ink text-white sm:bg-transparent sm:text-ink" : ""
                      }`}
                    >
                      <span>
                        {c === "auto" ? "Auto" : `${c}p`}
                        {c === "auto" && <span className="hidden sm:inline"> ({playing}p)</span>}
                      </span>
                      {pick === c && (
                        <svg aria-hidden="true" viewBox="0 0 24 24" className="hidden h-4 w-4 sm:block" {...ICON}>
                          <path d="M5 12.5l4.5 4.5L19 7" />
                        </svg>
                      )}
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
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
          {paused && !ended && !still && (
            <span aria-hidden="true" className="pointer-events-none absolute inset-0 grid place-items-center">
              <span className="grid h-14 w-14 place-items-center rounded-full bg-ink/60 text-white shadow-xl backdrop-blur sm:h-20 sm:w-20">
                <svg viewBox="0 0 24 24" className="ml-1 h-7 w-7 sm:h-9 sm:w-9" fill="currentColor">
                  <path d="M7 4.5v15a1 1 0 0 0 1.5.9l12-7.5a1 1 0 0 0 0-1.8l-12-7.5A1 1 0 0 0 7 4.5z" />
                </svg>
              </span>
            </span>
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
