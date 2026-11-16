// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect, useRef, useState } from "react";

// The 38-second film, right under the hero. It plays muted while it is on
// screen (browsers only autoplay without sound), with a button for the sound.
// With reduced motion it waits for the person to press play.
export default function Film() {
  const video = useRef<HTMLVideoElement>(null);
  const [muted, setMuted] = useState(true);
  const [still, setStill] = useState(false);

  useEffect(() => {
    const v = video.current;
    if (!v) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    setStill(reduce);
    if (reduce) return;
    const seen = new IntersectionObserver(
      ([e]) => {
        if (e.isIntersecting) v.play().catch(() => {});
        else v.pause();
      },
      { threshold: 0.35 },
    );
    seen.observe(v);
    return () => seen.disconnect();
  }, []);

  const toggleSound = () => {
    const v = video.current;
    if (!v) return;
    v.muted = !v.muted;
    setMuted(v.muted);
    if (!v.muted && v.paused) v.play().catch(() => {});
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
            src="/video/pairdesk-film.mp4"
            poster="/video/pairdesk-film-poster.jpg"
            muted
            loop
            playsInline
            preload="metadata"
            controls={still}
            aria-label="A 38-second film: pairing a phone with a computer, then using it as a touchpad and keyboard, seeing the screen, sending files and the clipboard, shortcuts, sound and apps, on Windows, macOS and Linux with Android and iPhone."
          />
          {!still && (
            <button
              type="button"
              onClick={toggleSound}
              aria-pressed={!muted}
              className="absolute bottom-4 right-4 flex items-center gap-2 rounded-full bg-white/90 px-4 py-2.5 text-sm font-semibold text-ink shadow-lg backdrop-blur transition hover:bg-white sm:bottom-6 sm:right-6"
            >
              <svg aria-hidden="true" viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M4 9v6h4l5 4V5L8 9z" />
                {muted ? <path d="M17 9l5 5M22 9l-5 5" /> : <path d="M16.5 8.5a5 5 0 0 1 0 7M19 6a8.5 8.5 0 0 1 0 12" />}
              </svg>
              {muted ? "Sound on" : "Sound off"}
            </button>
          )}
        </div>
      </div>
    </section>
  );
}
