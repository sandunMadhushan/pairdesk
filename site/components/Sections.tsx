// SPDX-License-Identifier: GPL-3.0-or-later
import Link from "next/link";
import { Spark } from "@/components/Devices";

const GITHUB = "https://github.com/sandunMadhushan/pairdesk";

const STATS = [
  { n: 2, suffix: " min", label: "to set up, once" },
  { n: 3, suffix: "", label: "systems: Windows, Linux and Android" },
  { n: 2, suffix: " h", label: "at most for a help link" },
  { n: 0, suffix: "", label: "accounts, ads or trackers" },
];

export function Stats() {
  return (
    <section aria-label="PairDesk in numbers" className="px-3 sm:px-6">
      <div data-sheet className="mx-auto max-w-7xl overflow-hidden rounded-[clamp(28px,4vw,44px)] bg-pair text-white shadow-[0_40px_80px_-40px_var(--color-pair)]">
        <dl className="relative grid grid-cols-2 lg:grid-cols-4">
          <svg aria-hidden="true" viewBox="0 0 800 200" preserveAspectRatio="none" className="pointer-events-none absolute inset-0 h-full w-full text-white/10" fill="none">
            <path d="M-20 160 C 160 40, 320 220, 520 90 S 760 40, 840 120" stroke="currentColor" strokeWidth="2" />
          </svg>
          {STATS.map((s, i) => (
            <div
              key={s.label}
              className={`relative flex items-center gap-4 px-6 py-8 sm:px-10 sm:py-10 ${i % 2 ? "border-l border-white/20" : ""} ${i > 1 ? "border-t border-white/20 lg:border-t-0" : ""} ${i === 2 ? "lg:border-l" : ""}`}
            >
              <dd className="display shrink-0 text-[clamp(2.8rem,5vw,4rem)] tabular-nums">
                <span data-count={s.n} data-suffix={s.suffix}>
                  {s.n}
                  {s.suffix}
                </span>
              </dd>
              <dt className="max-w-[11rem] text-[0.95rem] leading-snug text-white/85">{s.label}</dt>
            </div>
          ))}
        </dl>
      </div>
    </section>
  );
}

const STEPS = [
  {
    title: "Install it on your computer",
    body: "Run the Windows setup or install the Linux package. PairDesk opens and shows a pairing code.",
    icon: "M4 5h16v11H4zM2 19h20",
  },
  {
    title: "Get the app on your phone",
    body: "Install PairDesk for Android. It asks for the camera only to read the code.",
    icon: "M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2",
  },
  {
    title: "Scan the code, or tap a link",
    body: "After that the app connects whenever you open it, even after a restart.",
    icon: "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h2v2h-2zM18 18h2v2h-2zM14 18h2M18 14h2",
  },
];

export function Setup() {
  return (
    <section id="setup" aria-labelledby="setup-title" className="scroll-mt-20 px-4 sm:px-6">
      <div className="mx-auto max-w-7xl">
        <div className="relative max-w-2xl">
          <Spark className="absolute -top-8 -left-3 size-9 rotate-[-15deg] text-marker" />
          <h2 id="setup-title" className="display text-[clamp(2.4rem,5vw,4.2rem)]">
            Set up in about two minutes
          </h2>
        </div>
        <ol data-pop className="relative mt-14 grid gap-5 md:grid-cols-3">
          <svg aria-hidden="true" viewBox="0 0 1000 40" preserveAspectRatio="none" className="pointer-events-none absolute top-[52px] left-[8%] hidden h-10 w-[84%] text-pair/40 md:block" fill="none">
            <path data-draw d="M0 20 C 160 0, 330 40, 500 20 S 840 0, 1000 20" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" />
          </svg>
          {STEPS.map((s, k) => (
            <li key={s.title} data-pop-item className="relative rounded-[28px] bg-white p-7 shadow-[0_30px_60px_-40px_rgba(31,58,120,.45)]">
              <div className="flex items-center justify-between">
                <span className="grid size-14 place-items-center rounded-2xl bg-pair text-white shadow-[0_12px_24px_-10px_var(--color-pair)]">
                  <svg viewBox="0 0 24 24" className="size-6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                    <path d={s.icon} />
                  </svg>
                </span>
                <span className="hand text-5xl text-marker" aria-hidden="true">
                  {k + 1}
                </span>
              </div>
              <h3 className="mt-6 text-2xl font-semibold tracking-tight">
                <span className="sr-only">Step {k + 1}: </span>
                {s.title}
              </h3>
              <p className="mt-2 text-slate">{s.body}</p>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}

const SHOTS = [
  { src: "/screenshots/1_computers.png", caption: "Your computers" },
  { src: "/screenshots/2_touchpad.png", caption: "Touchpad" },
  { src: "/screenshots/3_buttons.png", caption: "Shortcut buttons" },
  { src: "/screenshots/4_apps.png", caption: "The computer's apps" },
  { src: "/screenshots/5_clipboard_files.png", caption: "Clipboard and files" },
];

const MORE = [
  { title: "App launcher", body: "Open the computer's apps, websites and folders from your phone." },
  { title: "Power", body: "Lock, sleep, turn off the screen, restart or shut down, when you allow it." },
  { title: "App lock", body: "Open PairDesk with your fingerprint, face or screen lock." },
  { title: "Several computers", body: "Pair the laptop, the desktop and the media PC, and switch with a tap." },
  { title: "Updates itself", body: "The computer installs new versions; the phone tells you when one is out." },
  { title: "Wayland and X11", body: "Works on GNOME and KDE, on Wayland or X11, and on Windows 10 and 11." },
];

export function Tour() {
  return (
    <section aria-labelledby="tour-title" className="overflow-hidden">
      <div className="mx-auto max-w-7xl px-4 sm:px-6">
        <h2 id="tour-title" className="display max-w-2xl text-[clamp(2.4rem,5vw,4.2rem)]">
          The phone app, up close
        </h2>
      </div>
      <div className="mx-auto max-w-7xl px-4 sm:px-6">
        <div data-pop className="mt-12 flex flex-wrap justify-center gap-x-5 gap-y-10 lg:flex-nowrap lg:justify-between">
          {SHOTS.map((s, i) => (
            <figure key={s.src} data-pop-item className={`w-[calc(50%-0.625rem)] max-w-[240px] sm:w-[calc(33.333%-0.84rem)] lg:w-auto lg:flex-1 ${i % 2 ? "lg:mt-12" : ""}`}>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src={s.src}
                alt={s.caption}
                width={540}
                height={1170}
                loading="lazy"
                className="w-full rounded-[30px] border-[6px] border-[#10131d] bg-white shadow-[0_40px_70px_-40px_rgba(20,30,70,.6)] transition-transform duration-500 ease-[var(--ease-out-quint)] hover:-translate-y-2 hover:rotate-[-1.5deg]"
              />
              <figcaption className="mt-4 text-center font-medium text-slate">{s.caption}</figcaption>
            </figure>
          ))}
        </div>
      </div>
      <div className="mx-auto max-w-7xl px-4 sm:px-6">
        <ul className="mt-16 grid gap-x-10 gap-y-8 sm:grid-cols-2 lg:grid-cols-3">
          {MORE.map((m) => (
            <li key={m.title} className="border-t-2 border-line pt-5">
              <h3 className="text-xl font-semibold tracking-tight">{m.title}</h3>
              <p className="mt-1.5 text-slate">{m.body}</p>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

const FACTS = [
  {
    title: "No account, no tracking",
    body: "There's nothing to sign up for. The apps contain no analytics, ads or crash reporting.",
  },
  {
    title: "Encrypted end to end",
    body: "Phone and computer check each other's keys on every connection. Even through the relay, only the two of them can read what passes.",
  },
  {
    title: "You set the rules",
    body: "Choose on the computer what phones may do, and remove a phone at any time. A help link works once and gives two hours at most.",
  },
];

export function Trust() {
  return (
    <section aria-labelledby="trust-title" className="px-3 sm:px-6">
      <div data-sheet className="mx-auto max-w-7xl rounded-[clamp(28px,4vw,44px)] bg-ink text-white">
        <div className="grid gap-12 p-7 sm:p-12 lg:grid-cols-[1fr_1.15fr] lg:gap-20 lg:p-16">
          <div>
            <h2 id="trust-title" className="display text-[clamp(2.2rem,4.4vw,3.6rem)]">
              Nobody sits in the middle
            </h2>
            <p className="mt-5 max-w-md text-lg text-white/70">
              Your phone talks to your computer directly. When it can&apos;t, the relay only passes sealed data along.
              Read the{" "}
              <Link href="/privacy" className="text-white underline decoration-marker decoration-2 underline-offset-4 hover:text-marker">
                privacy policy
              </Link>
              .
            </p>
          </div>
          <dl data-pop className="grid gap-4">
            {FACTS.map((f) => (
              <div key={f.title} data-pop-item className="rounded-3xl bg-white/[0.06] p-6 ring-1 ring-white/10">
                <dt className="text-xl font-semibold tracking-tight">{f.title}</dt>
                <dd className="mt-1.5 text-white/70">{f.body}</dd>
              </div>
            ))}
          </dl>
        </div>
      </div>
    </section>
  );
}

const QUESTIONS: { q: string; a: React.ReactNode }[] = [
  {
    q: "Is it safe? Could someone else control my computer?",
    a: "Only phones you paired can connect, and pairing needs the code or link shown on the computer, which works once and expires in ten minutes. Every connection is encrypted and both sides check each other's keys. On the computer you choose what paired phones may do, and you can remove a phone at any time.",
  },
  {
    q: "Does my data go through a server?",
    a: (
      <>
        Not when the phone can reach the computer directly, at home or through Tailscale. Otherwise it goes through
        the PairDesk relay, which only passes the encrypted connection along: it can&apos;t see your screen, what you
        type, files or sound. There&apos;s no account. See the{" "}
        <Link href="/privacy" className="link">
          privacy policy
        </Link>
        .
      </>
    ),
  },
  {
    q: "Can I use it away from home?",
    a: "Yes. Open the app once at home so it learns the way to the computer; after that it connects from anywhere, through Tailscale if you use it, or else through the PairDesk relay. The computer must be awake.",
  },
  {
    q: "Can I help a friend with their computer?",
    a: "Yes. They install PairDesk on their computer, press Get help and send you the link. You can see and control their screen, but not turn it off, take files or listen. It ends after two hours, when you leave, or when they press End help.",
  },
  {
    q: "Windows says the setup is from an unknown publisher.",
    a: (
      <>
        PairDesk isn&apos;t code-signed yet (that&apos;s coming through the SignPath Foundation&apos;s free signing for
        open-source projects). Choose <i>More info</i>, then <i>Run anyway</i>. You can check the download against{" "}
        <code className="rounded bg-sky px-1.5 py-0.5 text-[0.9em]">SHA256SUMS.txt</code> on the release page.
      </>
    ),
  },
  {
    q: "Wayland asks me to allow remote control.",
    a: "On GNOME and KDE Wayland the desktop asks once whether PairDesk may share the screen and control the pointer and keyboard. Allow it, and PairDesk keeps the permission so it doesn't ask again after a restart.",
  },
  {
    q: "iPhone or Mac?",
    a: "Not yet. PairDesk is Android plus Windows and Linux for now.",
  },
];

export function Questions() {
  return (
    <section id="questions" aria-labelledby="questions-title" className="scroll-mt-20 px-3 sm:px-6">
      <div data-sheet className="sheet mx-auto max-w-7xl">
        <div className="grid gap-12 p-7 sm:p-12 lg:grid-cols-[0.8fr_1.2fr] lg:gap-20 lg:p-16">
          <div>
            <h2 id="questions-title" className="display text-[clamp(2.2rem,4.4vw,3.6rem)]">
              Questions people ask
            </h2>
            <p className="mt-5 max-w-sm text-lg text-slate">
              Something else on your mind? Ask on GitHub and you&apos;ll get an answer there.
            </p>
            <a href={`${GITHUB}/issues`} className="btn btn-ink mt-8">
              Ask a question
            </a>
          </div>
          <div className="divide-y divide-line">
            {QUESTIONS.map((item) => (
              <details key={item.q} className="group">
                <summary className="flex items-center justify-between gap-6 py-5 text-lg font-medium transition-colors hover:text-pair">
                  {item.q}
                  <span
                    aria-hidden="true"
                    className="faq-mark grid size-9 shrink-0 place-items-center rounded-full bg-pair-soft text-pair transition-[transform,background-color,color] duration-300"
                  >
                    <svg viewBox="0 0 24 24" className="size-4" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M5 12h14m-5-5 5 5-5 5" />
                    </svg>
                  </span>
                </summary>
                <p className="max-w-2xl pb-6 text-slate">{item.a}</p>
              </details>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
