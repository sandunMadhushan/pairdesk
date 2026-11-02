// SPDX-License-Identifier: GPL-3.0-or-later
import type { CSSProperties, ReactNode, Ref } from "react";

/** A modern phone drawn in CSS; the screen holds whatever it is given. */
export function Phone({
  children,
  className = "",
  style,
  landscape = false,
}: {
  children: ReactNode;
  className?: string;
  style?: CSSProperties;
  landscape?: boolean;
}) {
  return (
    <div
      className={`relative bg-[#10131d] shadow-[0_50px_90px_-40px_rgba(20,30,70,.55),0_0_0_1.5px_#2a3042_inset,0_0_0_4px_#c9d2e3] ${
        landscape ? "aspect-[1170/540] rounded-[6.5%/14%] p-[1.6%]" : "aspect-[540/1170] rounded-[14%/6.5%] p-[3.2%]"
      } ${className}`}
      style={style}
    >
      <div
        className={`relative h-full w-full overflow-hidden bg-[#f6f6fb] ${
          landscape ? "rounded-[5.3%/11.5%]" : "rounded-[11.5%/5.3%]"
        }`}
      >
        {children}
        {/* camera island */}
        <span
          className={`absolute rounded-full bg-[#10131d] ${
            landscape
              ? "top-1/2 left-[1.6%] h-[28%] w-[3%] -translate-y-1/2"
              : "top-[1.6%] left-1/2 h-[3%] w-[28%] -translate-x-1/2"
          }`}
        />
      </div>
    </div>
  );
}

/** The computer's desktop as the phone sees it: wallpaper, a notes window,
 *  a music card and a taskbar. Pure markup so it scales with its box. */
export function Desktop({
  children,
  playing = true,
  className = "",
}: {
  children?: ReactNode;
  playing?: boolean;
  className?: string;
}) {
  return (
    <div className={`absolute inset-0 overflow-hidden [container-type:inline-size] ${className}`}>
      <div className="absolute inset-0 bg-[radial-gradient(120%_90%_at_15%_10%,#c8d8ff_0%,#9fb7f5_35%,#6d8ee8_70%,#4a6fd6_100%)]" />
      {/* soft hills */}
      <svg className="absolute inset-x-0 bottom-0 h-1/2 w-full" viewBox="0 0 400 100" preserveAspectRatio="none" aria-hidden="true">
        <path d="M0 60 C 80 30 140 70 220 45 S 360 40 400 55 V100 H0Z" fill="#ffffff" opacity=".18" />
        <path d="M0 80 C 90 55 170 90 260 68 S 360 70 400 76 V100 H0Z" fill="#ffffff" opacity=".22" />
      </svg>
      {/* notes window */}
      <div className="absolute top-[9%] left-[7%] w-[46%] rounded-[1.6cqw] bg-white/95 p-[2.2cqw] shadow-[0_2cqw_5cqw_-2cqw_rgba(20,30,80,.45)]">
        <div className="flex gap-[0.8cqw]">
          <i className="block size-[1.4cqw] rounded-full bg-[#ff6b5e]" />
          <i className="block size-[1.4cqw] rounded-full bg-[#ffc24a]" />
          <i className="block size-[1.4cqw] rounded-full bg-[#2fd17a]" />
        </div>
        <p className="mt-[1.8cqw] text-[2.6cqw] leading-tight font-semibold text-ink">Ideas for Monday</p>
        <div className="mt-[1.4cqw] space-y-[1cqw]">
          <i className="block h-[1cqw] w-[92%] rounded-full bg-[#dfe5f2]" />
          <i className="block h-[1cqw] w-[78%] rounded-full bg-[#dfe5f2]" />
          <i className="block h-[1cqw] w-[85%] rounded-full bg-[#dfe5f2]" />
          <i className="block h-[1cqw] w-[55%] rounded-full bg-[#dfe5f2]" />
        </div>
      </div>
      {/* music card */}
      <div
        data-target="play"
        className="absolute right-[7%] bottom-[22%] w-[34%] rounded-[1.8cqw] bg-white/90 p-[1.8cqw] shadow-[0_2cqw_5cqw_-2cqw_rgba(20,30,80,.45)]"
      >
        <div className="flex items-center gap-[1.4cqw]">
          <span className="grid size-[6cqw] shrink-0 place-items-center rounded-[1.2cqw] bg-[linear-gradient(135deg,#ffb36b,#ff7a1a)]">
            {playing ? (
              <span className="flex h-[2.4cqw] items-end gap-[0.4cqw]" aria-hidden="true">
                <i className="eq block w-[0.6cqw] rounded-full bg-white" />
                <i className="eq block w-[0.6cqw] rounded-full bg-white [animation-delay:-.3s]" />
                <i className="eq block w-[0.6cqw] rounded-full bg-white [animation-delay:-.6s]" />
              </span>
            ) : (
              <span className="ml-[0.4cqw] block size-0 border-y-[1.2cqw] border-l-[2cqw] border-y-transparent border-l-white" />
            )}
          </span>
          <span className="min-w-0">
            <span className="block truncate text-[2.2cqw] leading-tight font-semibold text-ink">
              {playing ? "Now playing" : "Paused"}
            </span>
            <span className="block truncate text-[1.8cqw] leading-tight text-slate">Evening mix</span>
          </span>
        </div>
        <span className="mt-[1.4cqw] block h-[0.7cqw] overflow-hidden rounded-full bg-[#e3e8f3]">
          <span className="prog block h-full w-[45%] rounded-full bg-marker" />
        </span>
      </div>
      {/* taskbar */}
      <div className="absolute bottom-[3.5%] left-1/2 flex -translate-x-1/2 gap-[1.2cqw] rounded-[1.6cqw] bg-white/70 px-[1.6cqw] py-[1.1cqw] backdrop-blur-sm">
        {["#1f5bff", "#ff7a1a", "#19b46b", "#8f5bff", "#ffc24a"].map((c) => (
          <i key={c} className="block size-[3cqw] rounded-[0.8cqw]" style={{ background: c }} />
        ))}
      </div>
      {children}
    </div>
  );
}

/** A laptop: lid with a screen, and a thin base. */
export function Laptop({
  children,
  className = "",
  screenRef,
}: {
  children: ReactNode;
  className?: string;
  screenRef?: Ref<HTMLDivElement>;
}) {
  return (
    <div className={`relative ${className}`}>
      <div className="rounded-[2.2%/3.4%] bg-[#151a28] p-[2.2%] pb-[3%] shadow-[0_60px_100px_-50px_rgba(20,30,70,.55),0_0_0_1.5px_#2c3347_inset]">
        <div ref={screenRef} className="relative aspect-[16/10] overflow-hidden rounded-[0.8%] bg-sky">
          {children}
        </div>
      </div>
      <div className="relative mx-[-6%] h-[3.2vmin] max-h-5 min-h-2.5 rounded-b-[40%_100%] bg-[linear-gradient(#e4e9f2,#b9c3d6)] shadow-[0_24px_40px_-20px_rgba(20,30,70,.5)]">
        <span className="absolute top-0 left-1/2 h-[45%] w-[16%] -translate-x-1/2 rounded-b-xl bg-[#a8b3c8]" />
      </div>
    </div>
  );
}

/** The computer's pointer. */
export function Cursor({
  className = "",
  style,
  ref,
}: {
  className?: string;
  style?: CSSProperties;
  ref?: Ref<SVGSVGElement>;
}) {
  return (
    <svg
      ref={ref}
      viewBox="0 0 24 24"
      className={`pointer-events-none absolute drop-shadow-[0_2px_3px_rgba(0,0,0,.35)] ${className}`}
      style={style}
      aria-hidden="true"
    >
      <path d="M4 2.5 L4 19 L8.6 14.8 L11.6 21.4 L14.6 20 L11.7 13.6 L18 13.4 Z" fill="#111827" stroke="#fff" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  );
}

/** A hand-drawn arrow, drawn on when it scrolls into view. */
export function Squiggle({ className = "", d, title }: { className?: string; d?: string; title?: string }) {
  return (
    <svg viewBox="0 0 120 80" className={className} fill="none" aria-hidden={title ? undefined : true}>
      {title && <title>{title}</title>}
      <path
        data-draw
        d={d ?? "M6 10 C 40 4, 78 18, 86 44 S 92 66, 104 70"}
        stroke="currentColor"
        strokeWidth="3"
        strokeLinecap="round"
      />
      <path data-draw d="M92 70 L105 71 L101 58" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

/** Three short strokes: the "spark" doodle from the reference. */
export function Spark({ className = "" }: { className?: string }) {
  return (
    <svg viewBox="0 0 40 40" className={className} fill="none" aria-hidden="true">
      <path data-draw d="M8 26 L2 22" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
      <path data-draw d="M16 16 L13 4" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
      <path data-draw d="M27 18 L35 9" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
    </svg>
  );
}
