# pairdesk.madhushan.me

The PairDesk website: Next.js (static export) with Tailwind CSS, GSAP
(ScrollTrigger), Three.js and Lenis.

```sh
npm ci
npm run dev     # http://localhost:3000
npm run build   # writes the site to out/
```

- `lib/scene.ts`: the 3D laptop and phone on the home page. Scroll moves it
  through five poses (`KEYS`); the screens are drawn on canvases each frame.
- `components/Story.tsx`: the sticky stage and the text that scrolls past it.
- `app/p/`: the page a pairing link opens when PairDesk didn't catch it. The
  pairing details stay after the `#` and never reach a server.
- `public/.well-known/assetlinks.json`: lets Android open
  `https://pairdesk.madhushan.me/p` links straight in the app.

`.github/workflows/pages.yml` builds and publishes it (only while the
repository is public).
