// SPDX-License-Identifier: GPL-3.0-or-later
"use client";

import { useEffect } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";

/**
 * Scroll motion for the whole page, driven by data attributes so the
 * sections themselves stay plain markup:
 *
 *  data-sheet       the white sheet tilts up from the page as it arrives
 *  data-pop         its [data-pop-item] children pop in, one after another
 *  data-count="n"   counts up to n (data-suffix is appended)
 *  data-draw        an SVG path draws itself
 *  data-parallax=k  drifts at k × the scroll speed
 *
 * With reduced motion nothing moves and everything shows in its final state.
 */
export default function Motion() {
  useEffect(() => {
    gsap.registerPlugin(ScrollTrigger);
    const mm = gsap.matchMedia();

    mm.add("(prefers-reduced-motion: no-preference)", () => {
      gsap.utils.toArray<HTMLElement>("[data-sheet]").forEach((el) => {
        gsap.fromTo(
          el,
          { rotateX: 16, y: 120, scale: 0.9, transformPerspective: 1400 },
          {
            rotateX: 0,
            y: 0,
            scale: 1,
            ease: "none",
            scrollTrigger: { trigger: el, start: "top bottom", end: "top 30%", scrub: 0.8 },
          },
        );
      });

      gsap.utils.toArray<HTMLElement>("[data-pop]").forEach((group) => {
        const items = group.querySelectorAll("[data-pop-item]");
        if (!items.length) return;
        gsap.from(items, {
          scale: 0.6,
          y: 24,
          opacity: 0,
          duration: 0.7,
          ease: "back.out(1.7)",
          stagger: 0.09,
          scrollTrigger: { trigger: group, start: "top 78%", once: true },
        });
      });

      gsap.utils.toArray<HTMLElement>("[data-count]").forEach((el) => {
        const end = Number(el.dataset.count);
        const suffix = el.dataset.suffix ?? "";
        const v = { n: 0 };
        gsap.to(v, {
          n: end,
          duration: 1.6,
          ease: "power3.out",
          scrollTrigger: { trigger: el, start: "top 88%", once: true },
          onUpdate: () => {
            el.textContent = `${Math.round(v.n)}${suffix}`;
          },
        });
      });

      gsap.utils.toArray<SVGPathElement>("[data-draw]").forEach((path) => {
        if (path.getAttribute("stroke-dasharray")) return;
        const len = path.getTotalLength();
        gsap.fromTo(
          path,
          { strokeDasharray: len, strokeDashoffset: len },
          {
            strokeDashoffset: 0,
            duration: 1.1,
            ease: "power2.inOut",
            scrollTrigger: { trigger: path, start: "top 92%", once: true },
          },
        );
      });

      gsap.utils.toArray<HTMLElement>("[data-parallax]").forEach((el) => {
        const k = Number(el.dataset.parallax) || 0.15;
        gsap.to(el, {
          yPercent: -100 * k,
          ease: "none",
          scrollTrigger: { trigger: el.parentElement ?? el, start: "top bottom", end: "bottom top", scrub: true },
        });
      });
    });

    // Fonts and images change heights after first paint.
    const refresh = () => ScrollTrigger.refresh();
    document.fonts?.ready.then(refresh);
    window.addEventListener("load", refresh);
    return () => {
      mm.revert();
      window.removeEventListener("load", refresh);
    };
  }, []);
  return null;
}
