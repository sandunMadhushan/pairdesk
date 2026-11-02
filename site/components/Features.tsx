// SPDX-License-Identifier: GPL-3.0-or-later
import type { ReactNode } from "react";
import { Desktop, Phone, Spark, Squiggle } from "@/components/Devices";

function Check() {
  return (
    <span className="mt-0.5 grid size-6 shrink-0 place-items-center rounded-full bg-pair-soft text-pair" aria-hidden="true">
      <svg viewBox="0 0 24 24" className="size-3.5" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
        <path d="m5 12.5 4.5 4.5L19 7.5" />
      </svg>
    </span>
  );
}

/** One white sheet: words on one side, a moving picture on the other. */
function Feature({
  id,
  title,
  body,
  points,
  note,
  flip = false,
  children,
}: {
  id: string;
  title: string;
  body: string;
  points: string[];
  note?: string;
  flip?: boolean;
  children: ReactNode;
}) {
  return (
    <section id={id} aria-labelledby={`${id}-title`} className="scroll-mt-20 px-3 sm:px-6">
      <div data-sheet className="sheet mx-auto max-w-7xl overflow-hidden">
        <div className={`grid items-center gap-10 p-7 sm:p-12 lg:grid-cols-2 lg:gap-16 lg:p-16 ${flip ? "lg:[&>*:first-child]:order-2" : ""}`}>
          <div className="max-w-xl">
            <h2 id={`${id}-title`} className="display text-[clamp(2.2rem,4.4vw,3.6rem)]">
              {title}
            </h2>
            <p className="mt-5 text-lg text-slate">{body}</p>
            <ul className="mt-8 grid gap-3.5">
              {points.map((pt) => (
                <li key={pt} className="flex gap-3">
                  <Check />
                  <span>{pt}</span>
                </li>
              ))}
            </ul>
            {note && <p className="hand mt-8 text-[1.75rem] text-marker">{note}</p>}
          </div>
          <div data-pop className="relative min-h-[380px] sm:min-h-[460px]">
            {children}
          </div>
        </div>
      </div>
    </section>
  );
}

function Key({ children, className = "", delay = "0s" }: { children: ReactNode; className?: string; delay?: string }) {
  return (
    <span
      className={`key grid h-12 min-w-12 place-items-center rounded-xl border border-line bg-white px-3 font-semibold text-ink ${className}`}
      style={{ animationDelay: delay }}
    >
      {children}
    </span>
  );
}

export function Touchpad() {
  return (
    <Feature
      id="touchpad"
      title="Touchpad, keyboard and your own buttons"
      body="Move, click, drag and scroll with the gestures you already know. Type with your phone's keyboard, voice typing included, and keep shortcuts and media keys one tap away."
      points={[
        "Two fingers scroll, a two-finger tap right-clicks",
        "Make buttons for the shortcuts you use every day",
        "Volume, play and skip are always at the top",
      ]}
      note="feels like a real laptop touchpad"
    >
      <div className="absolute inset-0 rounded-[32px] bg-[radial-gradient(circle_at_50%_55%,var(--color-pair-soft)_0%,transparent_65%)]" aria-hidden="true" />
      <div data-pop-item className="absolute top-1/2 left-1/2 w-[46%] max-w-[230px] -translate-x-1/2 -translate-y-1/2 rotate-[4deg]">
        <Phone>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/screenshots/3_buttons.png" alt="PairDesk's shortcut buttons screen" width={540} height={1170} loading="lazy" className="h-full w-full object-cover" />
        </Phone>
      </div>
      <div data-pop-item className="absolute top-[10%] left-[2%] flex items-center gap-2 sm:left-[6%]">
        <Key>Ctrl</Key>
        <span className="text-slate" aria-hidden="true">+</span>
        <Key delay=".25s">C</Key>
      </div>
      <div data-pop-item className="absolute top-[22%] right-[0%] sm:right-[4%]">
        <span className="chip bob">
          <span className="grid size-8 place-items-center rounded-lg bg-marker/15 text-marker">
            <svg viewBox="0 0 24 24" className="size-4.5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
              <rect x="9" y="3" width="6" height="12" rx="3" />
              <path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
            </svg>
          </span>
          Voice typing works too
        </span>
      </div>
      <div data-pop-item className="absolute bottom-[12%] left-[0%] flex items-center gap-2 sm:left-[4%]">
        <Key delay="1.1s">Alt</Key>
        <span className="text-slate" aria-hidden="true">+</span>
        <Key delay="1.35s">Tab</Key>
      </div>
      <div data-pop-item className="absolute right-[2%] bottom-[8%] sm:right-[8%]">
        <span className="chip bob-slow">
          <span className="flex h-5 items-end gap-[3px]" aria-hidden="true">
            <i className="eq block w-1 rounded-full bg-pair" />
            <i className="eq block w-1 rounded-full bg-pair [animation-delay:-.25s]" />
            <i className="eq block w-1 rounded-full bg-pair [animation-delay:-.5s]" />
            <i className="eq block w-1 rounded-full bg-pair [animation-delay:-.75s]" />
          </span>
          Volume up
        </span>
      </div>
    </Feature>
  );
}

export function Screen() {
  return (
    <Feature
      id="screen"
      flip
      title="The screen in your hand"
      body="See the computer's screen on your phone and work on it right there. Pinch to zoom and the view follows the pointer."
      points={[
        "Tap where you want to click, drag to move things",
        "Hear what the computer plays while you watch",
        "On Windows it reaches the sign-in screen and admin prompts",
      ]}
    >
      <div className="absolute inset-0 rounded-[32px] bg-[radial-gradient(circle_at_50%_50%,#fff1e6_0%,transparent_65%)]" aria-hidden="true" />
      <div data-pop-item className="absolute top-1/2 left-1/2 w-[92%] max-w-[560px] -translate-x-1/2 -translate-y-1/2 -rotate-[3deg]">
        <Phone landscape>
          <div className="pinch absolute inset-0">
            <Desktop />
          </div>
          <span aria-hidden="true" className="finger-a absolute top-[62%] left-[72%] size-[9%] rounded-full bg-white/50 ring-2 ring-white" />
          <span aria-hidden="true" className="finger-b absolute top-[62%] left-[72%] size-[9%] rounded-full bg-white/50 ring-2 ring-white" />
        </Phone>
      </div>
      <div data-pop-item className="absolute top-[6%] left-[4%]">
        <span className="chip bob">
          <span className="grid size-8 place-items-center rounded-lg bg-ink text-white">
            <svg viewBox="0 0 24 24" className="size-4" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden="true">
              <rect x="5" y="11" width="14" height="10" rx="2" />
              <path d="M8 11V8a4 4 0 0 1 8 0v3" />
            </svg>
          </span>
          Unlock the sign-in screen
        </span>
      </div>
      <div data-pop-item className="absolute right-[4%] bottom-[6%] flex items-center gap-2 text-marker">
        <span className="hand text-[1.6rem]">pinch to zoom</span>
        <Spark className="size-8 rotate-[100deg]" />
      </div>
    </Feature>
  );
}

const FILES = [
  { name: "holiday.jpg", tone: "bg-[#ffe4cf] text-marker", delay: "0s" },
  { name: "slides.pdf", tone: "bg-pair-soft text-pair", delay: "1.6s" },
  { name: "song.mp3", tone: "bg-[#d9f5e7] text-go", delay: "3.2s" },
];

export function Files() {
  return (
    <Feature
      id="files"
      title="Files, clipboard and sound, both ways"
      body="Share a photo to PairDesk and it lands in the computer's Downloads. Copy on one, paste on the other. Hear what the computer plays, and talk through its speakers."
      points={[
        "Send files from any app's share menu",
        "Drop a file on PairDesk on the computer to send it to the phone",
        "Talk and listen at the same time, with echo removed",
      ]}
    >
      <div data-pop-item className="absolute top-1/2 left-[2%] w-[40%] max-w-[210px] -translate-y-1/2 -rotate-[5deg]">
        <Phone>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/screenshots/5_clipboard_files.png" alt="PairDesk's clipboard and files sheet" width={540} height={1170} loading="lazy" className="h-full w-full object-cover" />
        </Phone>
      </div>

      {/* the computer's folder */}
      <div data-pop-item className="absolute top-[30%] right-[0%] w-[50%] max-w-[260px] rounded-3xl bg-white p-4 shadow-[0_30px_60px_-30px_rgba(31,58,120,.45)] ring-1 ring-line">
        <div className="flex items-center gap-2.5">
          <svg viewBox="0 0 24 24" className="size-7 text-pair" aria-hidden="true">
            <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" fill="currentColor" opacity=".9" />
          </svg>
          <span className="leading-tight">
            <b className="block text-[0.95rem] font-semibold">PairDesk</b>
            <span className="text-[0.8rem] text-slate">in Downloads, on the computer</span>
          </span>
        </div>
        <ul className="mt-3 grid gap-2 text-[0.85rem]">
          {FILES.map((f) => (
            <li key={f.name} className="flex items-center gap-2 rounded-xl bg-sky px-2.5 py-2">
              <span className={`grid size-6 place-items-center rounded-md text-[0.6rem] font-bold ${f.tone}`} aria-hidden="true">
                {f.name.split(".")[1].toUpperCase()}
              </span>
              {f.name}
            </li>
          ))}
        </ul>
      </div>

      {/* files in flight */}
      {FILES.map((f) => (
        <span key={f.name} aria-hidden="true" className="fly z-10" style={{ animationDelay: f.delay }}>
          <span className="chip !gap-2 !px-2.5 !py-1.5 text-[0.8rem]">
            <span className={`grid size-5 place-items-center rounded-md text-[0.5rem] font-bold ${f.tone}`}>
              {f.name.split(".")[1].toUpperCase()}
            </span>
            {f.name}
          </span>
        </span>
      ))}

      <div data-pop-item className="absolute top-[4%] right-[8%]">
        <span className="chip bob">
          <svg viewBox="0 0 24 24" className="size-5 text-pair" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <rect x="8" y="3" width="8" height="4" rx="1" />
            <path d="M16 5h2a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2" />
          </svg>
          Copied on the phone, pasted here
        </span>
      </div>
      <div data-pop-item className="absolute right-[10%] bottom-[6%] hidden text-marker sm:block">
        <Squiggle className="w-20 rotate-[160deg]" />
      </div>
    </Feature>
  );
}
