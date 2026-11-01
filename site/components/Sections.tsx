// SPDX-License-Identifier: GPL-3.0-or-later
import Link from "next/link";

function Container({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <div className={`mx-auto max-w-7xl px-4 sm:px-6 ${className}`}>{children}</div>;
}

function Heading({ children, id }: { children: React.ReactNode; id?: string }) {
  return (
    <h2 id={id} className="display max-w-[16ch] text-[clamp(2.4rem,5.6vw,4.6rem)]">
      {children}
    </h2>
  );
}

const STEPS = [
  {
    title: "Install PairDesk on your computer",
    body: "Run the Windows setup or install the Linux package. PairDesk opens and shows a pairing code.",
  },
  {
    title: "Get the app on your phone",
    body: "Install PairDesk for Android. It asks for the camera only to read the code.",
  },
  {
    title: "Scan the code, or tap a link",
    body: "Point the camera at the code, or send yourself the link under it. After that the app connects whenever you open it, even after a restart.",
  },
];

export function Setup() {
  return (
    <section id="setup" aria-labelledby="setup-title" className="scroll-mt-16 py-28 sm:py-36">
      <Container>
        <Heading id="setup-title">Set up in about two minutes</Heading>
        <ol className="mt-16 grid gap-12 md:grid-cols-3 md:gap-10">
          {STEPS.map((s, k) => (
            <li key={s.title} className="relative">
              <div className="flex items-center gap-4">
                <span className="font-display text-5xl font-bold text-signal tabular-nums">{k + 1}</span>
                <span className="h-px flex-1 bg-gradient-to-r from-signal/60 to-line" aria-hidden="true" />
              </div>
              <h3 className="mt-5 text-2xl font-semibold tracking-tight">{s.title}</h3>
              <p className="mt-3 max-w-sm text-mist">{s.body}</p>
            </li>
          ))}
        </ol>
      </Container>
    </section>
  );
}

const FACTS = [
  {
    title: "No account, no tracking",
    body: "There's nothing to sign up for. PairDesk contains no analytics, ads or crash reporting.",
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
    <section aria-labelledby="trust-title" className="border-y border-line/70 bg-deep py-28 sm:py-36">
      <Container className="grid gap-14 lg:grid-cols-[1fr_1.1fr] lg:gap-20">
        <div>
          <Heading id="trust-title">Nobody sits in the middle</Heading>
          <p className="mt-6 max-w-md text-lg text-mist">
            Your phone talks to your computer directly. When it can&apos;t, the relay only passes sealed data
            along. Read the{" "}
            <Link href="/privacy" className="link">
              privacy policy
            </Link>
            .
          </p>
        </div>
        <dl className="grid gap-10">
          {FACTS.map((f) => (
            <div key={f.title} className="border-t border-line pt-6">
              <dt className="font-display text-2xl font-semibold tracking-tight">{f.title}</dt>
              <dd className="mt-2 max-w-lg text-mist">{f.body}</dd>
            </div>
          ))}
        </dl>
      </Container>
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
  { title: "Your own buttons", body: "Make buttons for the shortcuts you use, next to the media and volume keys." },
  { title: "Sign-in screen", body: "On Windows, unlock the computer and answer admin prompts from the phone." },
  { title: "App lock", body: "Open PairDesk with your fingerprint, face or screen lock." },
  { title: "Several computers", body: "Pair the laptop, the desktop and the media PC, and switch with a tap." },
  { title: "Updates itself", body: "The computer installs new versions; the phone tells you when one is out." },
  { title: "Wayland and X11", body: "Works on GNOME and KDE, on Wayland or X11, and on Windows 10 and 11." },
];

export function More() {
  return (
    <section aria-labelledby="more-title" className="py-28 sm:py-36">
      <Container>
        <Heading id="more-title">The phone app, up close</Heading>
      </Container>
      <div
        className="mt-14 flex snap-x snap-mandatory gap-5 overflow-x-auto px-4 pb-6 sm:px-6 lg:px-[max(1.5rem,calc((100vw-80rem)/2+1.5rem))]"
        tabIndex={0}
        aria-label="Screenshots of the phone app"
      >
        {SHOTS.map((s) => (
          <figure key={s.src} className="w-[min(62vw,230px)] shrink-0 snap-start">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={s.src}
              alt={s.caption}
              width={540}
              height={1170}
              loading="lazy"
              className="rounded-[26px] border border-white/10 shadow-[0_30px_60px_-30px_rgba(0,0,0,.8)]"
            />
            <figcaption className="mt-3 text-center text-[0.95rem] text-mist">{s.caption}</figcaption>
          </figure>
        ))}
      </div>
      <Container>
        <ul className="mt-20 grid gap-x-10 gap-y-10 sm:grid-cols-2 lg:grid-cols-4">
          {MORE.map((m) => (
            <li key={m.title}>
              <h3 className="text-xl font-semibold tracking-tight">{m.title}</h3>
              <p className="mt-2 text-mist">{m.body}</p>
            </li>
          ))}
        </ul>
      </Container>
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
        Not when the phone can reach the computer directly, at home or through Tailscale. Otherwise it goes
        through the PairDesk relay, which only passes the encrypted connection along: it can&apos;t see your
        screen, what you type, files or sound. There&apos;s no account. See the{" "}
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
        PairDesk isn&apos;t code-signed yet (that&apos;s coming through the SignPath Foundation&apos;s free signing
        for open-source projects). Choose <i>More info</i>, then <i>Run anyway</i>. You can check the download
        against <code className="rounded bg-panel px-1.5 py-0.5 text-[0.9em]">SHA256SUMS.txt</code> on the release
        page.
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
    <section id="questions" aria-labelledby="questions-title" className="scroll-mt-16 py-28 sm:py-36">
      <Container className="grid gap-12 lg:grid-cols-[0.8fr_1.2fr] lg:gap-20">
        <Heading id="questions-title">Questions</Heading>
        <div className="divide-y divide-line border-y border-line">
          {QUESTIONS.map((item) => (
            <details key={item.q} className="group py-1">
              <summary className="flex items-start justify-between gap-6 py-5 text-lg font-semibold">
                {item.q}
                <span
                  aria-hidden="true"
                  className="faq-mark mt-1 text-2xl leading-none text-signal transition-transform duration-300"
                >
                  +
                </span>
              </summary>
              <p className="max-w-2xl pb-6 text-mist">{item.a}</p>
            </details>
          ))}
        </div>
      </Container>
    </section>
  );
}
