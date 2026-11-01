// SPDX-License-Identifier: GPL-3.0-or-later
// The home page's 3D scene: a laptop and a phone joined by a beam of data.
// Scroll moves it through five moments (hero, touchpad, screen view,
// files, from anywhere); `setProgress` takes 0..1 across them.

import * as THREE from "three";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
import { OutputPass } from "three/addons/postprocessing/OutputPass.js";

type V3 = [number, number, number];
interface Pose {
  pos: V3;
  rot: V3;
}
interface Key {
  cam: V3;
  look: V3;
  laptop: Pose;
  phone: Pose;
  relay: number;
}

const SIGNAL = new THREE.Color("#ffb648");
const RETURN = new THREE.Color("#9cc0ff");

// One pose per moment of the story.
const KEYS: Key[] = [
  {
    // hero
    cam: [0.3, 1.7, 9.0],
    look: [0.2, 0.75, 0],
    laptop: { pos: [1.25, 0, -0.5], rot: [0, -0.4, 0] },
    phone: { pos: [-0.1, 0.7, 1.9], rot: [-0.08, 0.4, 0.06] },
    relay: 0,
  },
  {
    // touchpad and keyboard
    cam: [0.1, 1.45, 7.6],
    look: [0.45, 0.8, 0],
    laptop: { pos: [1.15, 0, -0.8], rot: [0, -0.3, 0] },
    phone: { pos: [-0.3, 0.85, 2.2], rot: [-0.2, 0.3, 0.02] },
    relay: 0,
  },
  {
    // the screen in your hand: the phone turns sideways
    cam: [0.4, 1.35, 7.4],
    look: [0.4, 0.85, 0],
    laptop: { pos: [1.85, 0, -1.4], rot: [0, -0.5, 0] },
    phone: { pos: [0.05, 0.9, 2.1], rot: [-0.12, 0.22, Math.PI / 2] },
    relay: 0,
  },
  {
    // files, clipboard and sound
    cam: [0.2, 1.9, 8.6],
    look: [0.2, 0.7, 0],
    laptop: { pos: [1.4, 0, -0.5], rot: [0, -0.55, 0] },
    phone: { pos: [-0.8, 0.7, 1.3], rot: [-0.1, 0.55, 0.04] },
    relay: 0,
  },
  {
    // from anywhere: far apart, joined through the relay
    cam: [0.3, 2.4, 12.2],
    look: [0.3, 1.0, 0],
    laptop: { pos: [2.5, -0.2, -1.8], rot: [0, -0.7, 0] },
    phone: { pos: [-1.7, 0.5, 1.6], rot: [-0.1, 0.6, 0.05] },
    relay: 1,
  },
];

const smooth = (t: number) => t * t * (3 - 2 * t);
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
const lerp3 = (a: V3, b: V3, t: number): V3 => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];
const clamp01 = (v: number) => Math.min(1, Math.max(0, v));
/** 1 at stage `at`, falling to 0 one stage away. */
const near = (s: number, at: number) => clamp01(1 - Math.abs(s - at));

function roundRect(g: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  g.beginPath();
  g.roundRect(x, y, w, h, r);
}

function loadImage(src: string): HTMLImageElement {
  const img = new Image();
  img.decoding = "async";
  img.src = src;
  return img;
}

export interface SceneOptions {
  reducedMotion: boolean;
  lowPower: boolean;
}

export class PairScene {
  private renderer: THREE.WebGLRenderer;
  private composer: EffectComposer | null = null;
  private bloom: UnrealBloomPass | null = null;
  private scene = new THREE.Scene();
  private camera = new THREE.PerspectiveCamera(35, 1, 0.1, 100);
  private laptop = new THREE.Group();
  private lidPivot = new THREE.Group();
  private phone = new THREE.Group();
  private phoneTop = new THREE.Object3D();
  private laptopScreenPoint = new THREE.Object3D();
  private relay = new THREE.Group();
  private relayMats: THREE.Material[] = [];
  private beam: THREE.Line;
  private beamGeo: THREE.BufferGeometry;
  private packets: THREE.InstancedMesh;
  private cards: THREE.Mesh[] = [];
  private laptopCanvas: HTMLCanvasElement;
  private phoneCanvas: HTMLCanvasElement;
  private laptopTex: THREE.CanvasTexture;
  private phoneTex: THREE.CanvasTexture;
  private images: Record<string, HTMLImageElement>;
  private trail: { x: number; y: number }[] = [];

  private progress = 0;
  private intro = 0;
  private pointer = { x: 0, y: 0, tx: 0, ty: 0 };
  private time = 0;
  private last = 0;
  private raf = 0;
  private running = false;
  private size = { w: 1, h: 1 };
  private opts: SceneOptions;

  private static BEAM_POINTS = 96;
  private static PACKETS = 30;

  constructor(private canvas: HTMLCanvasElement, opts: SceneOptions) {
    this.opts = opts;
    this.renderer = new THREE.WebGLRenderer({
      canvas,
      antialias: !opts.lowPower,
      alpha: true,
      powerPreference: "high-performance",
    });
    this.renderer.setClearColor(0x000000, 0);
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.05;
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;

    const pmrem = new THREE.PMREMGenerator(this.renderer);
    this.scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
    this.scene.environmentIntensity = 0.75;
    pmrem.dispose();

    const key = new THREE.DirectionalLight("#dfe6ff", 1.6);
    key.position.set(-3, 5, 6);
    this.scene.add(key);
    const rim = new THREE.DirectionalLight("#ffb648", 1.1);
    rim.position.set(4, 2.5, -5);
    this.scene.add(rim);

    this.images = {
      touchpad: loadImage("/screenshots/2_touchpad.png"),
      files: loadImage("/screenshots/5_clipboard_files.png"),
      computers: loadImage("/screenshots/1_computers.png"),
    };

    this.laptopCanvas = document.createElement("canvas");
    this.laptopCanvas.width = 768;
    this.laptopCanvas.height = 480;
    this.phoneCanvas = document.createElement("canvas");
    this.phoneCanvas.width = 360;
    this.phoneCanvas.height = 780;
    this.laptopTex = this.screenTexture(this.laptopCanvas);
    this.phoneTex = this.screenTexture(this.phoneCanvas);

    this.buildLaptop();
    this.buildPhone();
    this.buildRelay();
    this.buildShadow();

    this.beamGeo = new THREE.BufferGeometry();
    this.beamGeo.setAttribute(
      "position",
      new THREE.BufferAttribute(new Float32Array(PairScene.BEAM_POINTS * 3), 3),
    );
    this.beam = new THREE.Line(
      this.beamGeo,
      new THREE.LineBasicMaterial({ color: SIGNAL, transparent: true, opacity: 0.45 }),
    );
    this.scene.add(this.beam);

    const dot = new THREE.SphereGeometry(0.034, 12, 8);
    const dotMat = new THREE.MeshBasicMaterial({ toneMapped: false });
    this.packets = new THREE.InstancedMesh(dot, dotMat, PairScene.PACKETS);
    this.packets.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    for (let i = 0; i < PairScene.PACKETS; i++) this.packets.setColorAt(i, SIGNAL);
    this.scene.add(this.packets);

    this.cards = [this.fileCard("photo"), this.fileCard("doc")];
    this.cards.forEach((c) => this.scene.add(c));

    if (!opts.lowPower) {
      this.composer = new EffectComposer(this.renderer);
      this.composer.addPass(new RenderPass(this.scene, this.camera));
      this.bloom = new UnrealBloomPass(new THREE.Vector2(1, 1), 0.55, 0.5, 0.82);
      this.composer.addPass(this.bloom);
      this.composer.addPass(new OutputPass());
    }

    if (opts.reducedMotion) this.intro = 1;
  }

  // ---------------------------------------------------------------- build

  private screenTexture(c: HTMLCanvasElement) {
    const t = new THREE.CanvasTexture(c);
    t.colorSpace = THREE.SRGBColorSpace;
    t.anisotropy = 4;
    return t;
  }

  private buildLaptop() {
    const W = 3.2,
      D = 2.15,
      baseH = 0.11,
      lidH = 2.05,
      lidT = 0.07;
    const alu = new THREE.MeshStandardMaterial({ color: "#b9c2d9", metalness: 0.85, roughness: 0.3 });
    const base = new THREE.Mesh(new RoundedBoxGeometry(W, baseH, D, 4, 0.05), alu);
    this.laptop.add(base);

    const deck = new THREE.Mesh(
      new THREE.PlaneGeometry(W * 0.86, D * 0.42),
      new THREE.MeshStandardMaterial({ color: "#1a2142", roughness: 0.7, metalness: 0.2 }),
    );
    deck.rotation.x = -Math.PI / 2;
    deck.position.set(0, baseH / 2 + 0.002, -D * 0.16);
    this.laptop.add(deck);

    const pad = new THREE.Mesh(
      new THREE.PlaneGeometry(W * 0.3, D * 0.26),
      new THREE.MeshStandardMaterial({ color: "#a8b1c9", metalness: 0.7, roughness: 0.45 }),
    );
    pad.rotation.x = -Math.PI / 2;
    pad.position.set(0, baseH / 2 + 0.002, D * 0.28);
    this.laptop.add(pad);

    this.lidPivot.position.set(0, baseH / 2, -D / 2 + 0.04);
    const lid = new THREE.Mesh(new RoundedBoxGeometry(W, lidH, lidT, 4, 0.035), alu);
    lid.position.set(0, lidH / 2, 0);
    this.lidPivot.add(lid);

    const bezel = new THREE.Mesh(
      new THREE.PlaneGeometry(W - 0.1, lidH - 0.1),
      new THREE.MeshBasicMaterial({ color: "#05070f" }),
    );
    bezel.position.set(0, lidH / 2, lidT / 2 + 0.001);
    this.lidPivot.add(bezel);

    const screen = new THREE.Mesh(
      new THREE.PlaneGeometry(W - 0.28, (W - 0.28) / 1.6),
      new THREE.MeshBasicMaterial({ map: this.laptopTex, toneMapped: false }),
    );
    screen.position.set(0, lidH / 2 + 0.03, lidT / 2 + 0.002);
    this.lidPivot.add(screen);
    this.laptopScreenPoint.position.set(0, lidH / 2 - 0.25, lidT / 2 + 0.05);
    this.lidPivot.add(this.laptopScreenPoint);

    this.laptop.add(this.lidPivot);
    this.scene.add(this.laptop);
  }

  private buildPhone() {
    const W = 0.9,
      H = 1.9,
      T = 0.09;
    const body = new THREE.Mesh(
      new RoundedBoxGeometry(W, H, T, 5, 0.11),
      new THREE.MeshStandardMaterial({ color: "#2a56c9", metalness: 0.55, roughness: 0.32 }),
    );
    this.phone.add(body);
    const glass = new THREE.Mesh(
      new THREE.PlaneGeometry(W - 0.05, H - 0.05),
      new THREE.MeshBasicMaterial({ color: "#05070f" }),
    );
    glass.position.z = T / 2 + 0.001;
    this.phone.add(glass);
    const screen = new THREE.Mesh(
      new THREE.PlaneGeometry(W - 0.09, (W - 0.09) * (780 / 360)),
      new THREE.MeshBasicMaterial({ map: this.phoneTex, toneMapped: false }),
    );
    screen.position.z = T / 2 + 0.002;
    this.phone.add(screen);
    this.phoneTop.position.set(0, H / 2 - 0.1, T / 2 + 0.05);
    this.phone.add(this.phoneTop);
    this.scene.add(this.phone);
  }

  private buildRelay() {
    const shell = new THREE.MeshBasicMaterial({
      color: "#9cc0ff",
      wireframe: true,
      transparent: true,
      opacity: 0,
    });
    const core = new THREE.MeshBasicMaterial({ color: SIGNAL, transparent: true, opacity: 0, toneMapped: false });
    this.relay.add(new THREE.Mesh(new THREE.IcosahedronGeometry(0.42, 1), shell));
    this.relay.add(new THREE.Mesh(new THREE.SphereGeometry(0.12, 16, 12), core));
    this.relayMats = [shell, core];
    this.relay.position.set(0.4, 3.0, -0.4);
    this.relay.visible = false;
    this.scene.add(this.relay);
  }

  private buildShadow() {
    const c = document.createElement("canvas");
    c.width = c.height = 128;
    const g = c.getContext("2d")!;
    const grd = g.createRadialGradient(64, 64, 4, 64, 64, 64);
    grd.addColorStop(0, "rgba(0,0,0,0.55)");
    grd.addColorStop(1, "rgba(0,0,0,0)");
    g.fillStyle = grd;
    g.fillRect(0, 0, 128, 128);
    const shadow = new THREE.Mesh(
      new THREE.PlaneGeometry(4.6, 3.2),
      new THREE.MeshBasicMaterial({ map: new THREE.CanvasTexture(c), transparent: true, depthWrite: false }),
    );
    shadow.rotation.x = -Math.PI / 2;
    shadow.position.y = -0.06;
    this.laptop.add(shadow);
  }

  private fileCard(kind: "photo" | "doc") {
    const c = document.createElement("canvas");
    c.width = 160;
    c.height = 200;
    const g = c.getContext("2d")!;
    roundRect(g, 4, 4, 152, 192, 18);
    g.fillStyle = "#f4f6fd";
    g.fill();
    if (kind === "photo") {
      const grd = g.createLinearGradient(0, 20, 0, 140);
      grd.addColorStop(0, "#ffb648");
      grd.addColorStop(1, "#3a74f0");
      roundRect(g, 18, 18, 124, 124, 10);
      g.fillStyle = grd;
      g.fill();
      g.fillStyle = "#0a0f24";
      g.beginPath();
      g.moveTo(26, 132);
      g.lineTo(70, 80);
      g.lineTo(100, 112);
      g.lineTo(118, 96);
      g.lineTo(136, 132);
      g.fill();
    } else {
      g.fillStyle = "#3a74f0";
      roundRect(g, 18, 20, 70, 14, 7);
      g.fill();
      g.fillStyle = "#c5cce0";
      for (let i = 0; i < 7; i++) {
        roundRect(g, 18, 50 + i * 18, i % 3 === 2 ? 80 : 124, 8, 4);
        g.fill();
      }
    }
    g.fillStyle = "#0a0f24";
    g.font = "600 17px sans-serif";
    g.fillText(kind === "photo" ? "photo.jpg" : "notes.pdf", 18, 178);
    const tex = new THREE.CanvasTexture(c);
    tex.colorSpace = THREE.SRGBColorSpace;
    const card = new THREE.Mesh(
      new THREE.PlaneGeometry(0.34, 0.425),
      new THREE.MeshBasicMaterial({ map: tex, transparent: true, side: THREE.DoubleSide, toneMapped: false }),
    );
    card.visible = false;
    return card;
  }

  // ---------------------------------------------------------------- input

  setProgress(p: number) {
    this.progress = clamp01(p);
    if (!this.running) this.frame(performance.now());
  }

  setIntro(v: number) {
    this.intro = clamp01(v);
  }

  setPointer(x: number, y: number) {
    this.pointer.tx = x;
    this.pointer.ty = y;
  }

  resize(w: number, h: number) {
    this.size = { w, h };
    const dpr = Math.min(window.devicePixelRatio || 1, this.opts.lowPower ? 1.5 : 2);
    this.renderer.setPixelRatio(dpr);
    this.renderer.setSize(w, h, false);
    this.composer?.setPixelRatio(dpr);
    this.composer?.setSize(w, h);
    this.camera.aspect = w / h;
    // Wide screens: the devices sit right of the text. Tall screens: above it.
    const a = w / h;
    if (a >= 1.1) this.camera.setViewOffset(w, h, -w * 0.16, 0, w, h);
    else this.camera.setViewOffset(w, h, w * 0.13, h * 0.26, w, h);
    this.camera.updateProjectionMatrix();
    if (!this.running) this.frame(performance.now());
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.last = performance.now();
    const loop = (t: number) => {
      if (!this.running) return;
      this.frame(t);
      this.raf = requestAnimationFrame(loop);
    };
    this.raf = requestAnimationFrame(loop);
  }

  stop() {
    this.running = false;
    cancelAnimationFrame(this.raf);
  }

  dispose() {
    this.stop();
    this.renderer.dispose();
    this.composer?.dispose();
    this.scene.traverse((o) => {
      const m = o as THREE.Mesh;
      m.geometry?.dispose();
      const mat = m.material as THREE.Material | THREE.Material[] | undefined;
      (Array.isArray(mat) ? mat : mat ? [mat] : []).forEach((x) => {
        (x as THREE.MeshBasicMaterial).map?.dispose();
        x.dispose();
      });
    });
  }

  // ---------------------------------------------------------------- frame

  private frame(now: number) {
    const dt = Math.min(0.05, (now - this.last) / 1000);
    this.last = now;
    if (!this.opts.reducedMotion) this.time += dt;
    const t = this.time;

    const s = this.progress * (KEYS.length - 1);
    const i = Math.min(KEYS.length - 2, Math.floor(s));
    const f = smooth(clamp01(s - i));
    const a = KEYS[i],
      b = KEYS[i + 1];

    // Devices
    const intro = smooth(this.intro);
    const lp = lerp3(a.laptop.pos, b.laptop.pos, f);
    const lr = lerp3(a.laptop.rot, b.laptop.rot, f);
    this.laptop.position.set(lp[0], lp[1] - (1 - intro) * 1.2, lp[2]);
    this.laptop.rotation.set(lr[0], lr[1] - (1 - intro) * 0.5, lr[2]);
    this.lidPivot.rotation.x = lerp(Math.PI / 2, -0.2, smooth(clamp01(this.intro * 1.4 - 0.2)));

    const pp = lerp3(a.phone.pos, b.phone.pos, f);
    const pr = lerp3(a.phone.rot, b.phone.rot, f);
    const bob = Math.sin(t * 1.1) * 0.06;
    const phoneIn = smooth(clamp01(this.intro * 1.6 - 0.35));
    this.phone.position.set(pp[0] - (1 - phoneIn) * 1.5, pp[1] + bob - (1 - phoneIn) * 0.8, pp[2]);
    this.phone.rotation.set(pr[0] + Math.sin(t * 0.7) * 0.03, pr[1] + Math.sin(t * 0.5) * 0.04, pr[2]);

    // Camera, with a little pointer parallax. Tall screens step back.
    this.pointer.x += (this.pointer.tx - this.pointer.x) * 0.05;
    this.pointer.y += (this.pointer.ty - this.pointer.y) * 0.05;
    const aspect = this.size.w / this.size.h;
    const back = aspect >= 1.2 ? 1 : 1 + (1.2 - aspect) * 1.35;
    const cam = lerp3(a.cam, b.cam, f);
    const look = lerp3(a.look, b.look, f);
    this.camera.position.set(
      look[0] + (cam[0] - look[0]) * back + this.pointer.x * 0.35,
      look[1] + (cam[1] - look[1]) * back - this.pointer.y * 0.2,
      look[2] + (cam[2] - look[2]) * back,
    );
    this.camera.lookAt(look[0], look[1], look[2]);

    // Relay
    const relayAmt = lerp(a.relay, b.relay, f);
    this.relay.visible = relayAmt > 0.01;
    (this.relayMats[0] as THREE.MeshBasicMaterial).opacity = relayAmt * 0.55;
    (this.relayMats[1] as THREE.MeshBasicMaterial).opacity = relayAmt;
    this.relay.rotation.set(t * 0.3, t * 0.45, 0);
    this.relay.scale.setScalar(0.6 + relayAmt * 0.4);

    this.scene.updateMatrixWorld(true);

    // The beam: a curve from the phone to the laptop's screen, through the
    // relay when the two are far apart.
    const start = this.phoneTop.getWorldPosition(new THREE.Vector3());
    const end = this.laptopScreenPoint.getWorldPosition(new THREE.Vector3());
    const mid = start.clone().lerp(end, 0.5);
    mid.y += 0.9 + start.distanceTo(end) * 0.12;
    mid.lerp(this.relay.position, relayAmt);
    const ctrl = mid.clone().multiplyScalar(2).sub(start.clone().add(end).multiplyScalar(0.5));
    const curve = new THREE.QuadraticBezierCurve3(start, ctrl, end);
    const pos = this.beamGeo.getAttribute("position") as THREE.BufferAttribute;
    const v = new THREE.Vector3();
    for (let k = 0; k < PairScene.BEAM_POINTS; k++) {
      curve.getPoint(k / (PairScene.BEAM_POINTS - 1), v);
      pos.setXYZ(k, v.x, v.y, v.z);
    }
    pos.needsUpdate = true;
    const drawn = smooth(clamp01(this.intro * 2 - 1));
    this.beamGeo.setDrawRange(0, Math.round(PairScene.BEAM_POINTS * drawn));

    // Packets: amber from the phone, blue back from the computer.
    const forward = [1, 1, 0.15, 0.5, 0.5];
    const share = lerp(forward[i], forward[i + 1], f);
    const speed = 0.32 + near(s, 2) * 0.25;
    const m = new THREE.Matrix4();
    const on = clamp01(this.intro * 3 - 2);
    for (let k = 0; k < PairScene.PACKETS; k++) {
      const fwd = k / PairScene.PACKETS < share;
      const phase = (t * speed + k / PairScene.PACKETS + (k % 3) * 0.013) % 1;
      curve.getPoint(fwd ? phase : 1 - phase, v);
      const fade = Math.sin(Math.PI * phase);
      m.makeScale(on * fade, on * fade, on * fade).setPosition(v);
      this.packets.setMatrixAt(k, m);
      this.packets.setColorAt(k, fwd ? SIGNAL : RETURN);
    }
    this.packets.instanceMatrix.needsUpdate = true;
    if (this.packets.instanceColor) this.packets.instanceColor.needsUpdate = true;

    // Files riding the beam, both ways.
    const filesAmt = near(s, 3);
    this.cards.forEach((card, k) => {
      card.visible = filesAmt > 0.02;
      if (!card.visible) return;
      const ph = (t * 0.22 + k * 0.5) % 1;
      curve.getPoint(k === 0 ? ph : 1 - ph, v);
      card.position.copy(v);
      card.lookAt(this.camera.position);
      card.scale.setScalar(filesAmt * Math.min(1, Math.sin(Math.PI * ph) * 2.2));
    });

    this.drawLaptop(t, s);
    this.drawPhone(t, s);

    if (this.composer) this.composer.render();
    else this.renderer.render(this.scene, this.camera);
  }

  // ---------------------------------------------------------------- screens

  /** Where the finger is on the touchpad, 0..1 both ways. */
  private finger(t: number) {
    return {
      x: 0.5 + 0.32 * Math.sin(t * 0.9) * Math.cos(t * 0.31),
      y: 0.5 + 0.3 * Math.sin(t * 1.27 + 1.1),
    };
  }

  private drawLaptop(t: number, s: number) {
    const c = this.laptopCanvas;
    const g = c.getContext("2d")!;
    const W = c.width,
      H = c.height;

    const bg = g.createLinearGradient(0, 0, W, H);
    bg.addColorStop(0, "#1c2b66");
    bg.addColorStop(1, "#0b1230");
    g.fillStyle = bg;
    g.fillRect(0, 0, W, H);
    const glow = g.createRadialGradient(W * 0.78, H * 0.2, 10, W * 0.78, H * 0.2, W * 0.55);
    glow.addColorStop(0, "rgba(255,182,72,0.28)");
    glow.addColorStop(1, "rgba(255,182,72,0)");
    g.fillStyle = glow;
    g.fillRect(0, 0, W, H);

    // A notes window
    roundRect(g, 70, 56, 400, 270, 14);
    g.fillStyle = "#f3f5fc";
    g.fill();
    g.fillStyle = "#dde2f0";
    g.fillRect(70, 56, 400, 34);
    g.fillStyle = "#ff6b6b";
    g.beginPath();
    g.arc(92, 73, 6, 0, 7);
    g.fill();
    g.fillStyle = "#ffb648";
    g.beginPath();
    g.arc(112, 73, 6, 0, 7);
    g.fill();
    g.fillStyle = "#2a3157";
    g.font = "600 22px sans-serif";
    g.fillText("Slides for Monday", 96, 128);
    g.fillStyle = "#c5cce0";
    for (let k = 0; k < 6; k++) {
      roundRect(g, 96, 150 + k * 26, k % 3 === 2 ? 200 : 330, 10, 5);
      g.fill();
    }

    // A media player
    roundRect(g, 420, 230, 300, 180, 14);
    g.fillStyle = "#121a3c";
    g.fill();
    g.strokeStyle = "rgba(255,255,255,0.08)";
    g.lineWidth = 2;
    g.stroke();
    const art = g.createLinearGradient(440, 250, 520, 330);
    art.addColorStop(0, "#3a74f0");
    art.addColorStop(1, "#ffb648");
    roundRect(g, 440, 250, 84, 84, 10);
    g.fillStyle = art;
    g.fill();
    g.fillStyle = "#e9edfa";
    g.font = "600 18px sans-serif";
    g.fillText("Now playing", 540, 280);
    g.fillStyle = "#93a0c6";
    g.font = "15px sans-serif";
    g.fillText("Evening mix", 540, 304);
    roundRect(g, 440, 360, 260, 6, 3);
    g.fillStyle = "#2a3463";
    g.fill();
    roundRect(g, 440, 360, 260 * ((t * 0.05) % 1), 6, 3);
    g.fillStyle = "#ffb648";
    g.fill();

    // Taskbar
    g.fillStyle = "rgba(6,10,26,0.82)";
    g.fillRect(0, H - 38, W, 38);
    for (let k = 0; k < 6; k++) {
      roundRect(g, W / 2 - 108 + k * 38, H - 30, 24, 24, 7);
      g.fillStyle = k === 2 ? "#3a74f0" : "rgba(233,237,250,0.25)";
      g.fill();
    }

    // "File received" note
    const filesAmt = near(s, 3);
    if (filesAmt > 0.02) {
      g.globalAlpha = filesAmt;
      roundRect(g, W - 270, 20, 250, 64, 12);
      g.fillStyle = "#e9edfa";
      g.fill();
      g.fillStyle = "#0a0f24";
      g.font = "600 17px sans-serif";
      g.fillText("photo.jpg received", W - 252, 48);
      g.fillStyle = "#5d6787";
      g.font = "14px sans-serif";
      g.fillText("Saved in Downloads/PairDesk", W - 252, 70);
      g.globalAlpha = 1;
    }

    // "Helping" banner (Get help)
    const helpAmt = near(s, 4);
    if (helpAmt > 0.02) {
      g.globalAlpha = helpAmt;
      g.fillStyle = "#ffb648";
      g.fillRect(0, 0, W, 34);
      g.fillStyle = "#0a0f24";
      g.font = "600 16px sans-serif";
      g.fillText("A friend is helping until 18:40", 16, 23);
      roundRect(g, W - 104, 5, 92, 24, 12);
      g.fillStyle = "#0a0f24";
      g.fill();
      g.fillStyle = "#ffb648";
      g.font = "600 13px sans-serif";
      g.fillText("End help", W - 86, 22);
      g.globalAlpha = 1;
    }

    // Pointer: follows the finger on the touchpad.
    const fp = this.finger(t);
    const cx = 60 + fp.x * (W - 120);
    const cy = 50 + fp.y * (H - 120);
    g.save();
    g.translate(cx, cy);
    g.scale(1.25, 1.25);
    g.beginPath();
    g.moveTo(0, 0);
    g.lineTo(0, 22);
    g.lineTo(6, 17);
    g.lineTo(10, 26);
    g.lineTo(14, 24);
    g.lineTo(10, 15);
    g.lineTo(17, 15);
    g.closePath();
    g.fillStyle = "#ffffff";
    g.strokeStyle = "#0a0f24";
    g.lineWidth = 1.6;
    g.fill();
    g.stroke();
    g.restore();

    this.laptopTex.needsUpdate = true;
  }

  private drawPhone(t: number, s: number) {
    const c = this.phoneCanvas;
    const g = c.getContext("2d")!;
    const W = c.width,
      H = c.height;
    g.fillStyle = "#f7f8fd";
    g.fillRect(0, 0, W, H);

    const draw = (img: HTMLImageElement, alpha: number) => {
      if (alpha <= 0.01 || !img.complete || !img.naturalWidth) return;
      g.globalAlpha = alpha;
      g.drawImage(img, 0, 0, W, H);
      g.globalAlpha = 1;
    };

    const touch = clamp01(1 - Math.abs(s - 0.5) * 1.33); // hero + touchpad
    const screen = near(s, 2);
    const files = near(s, 3);
    const computers = clamp01(s - 3);

    draw(this.images.touchpad, Math.max(touch, s < 1 ? 1 : 0));
    draw(this.images.files, files);
    draw(this.images.computers, computers);

    // Finger on the touchpad (the pad is the big rounded area).
    if (touch > 0.02) {
      const fp = this.finger(t);
      const px = W * (0.08 + fp.x * 0.84);
      const py = H * (0.18 + fp.y * 0.6);
      this.trail.push({ x: px, y: py });
      if (this.trail.length > 26) this.trail.shift();
      g.globalAlpha = touch;
      g.lineCap = "round";
      for (let k = 1; k < this.trail.length; k++) {
        g.strokeStyle = `rgba(255,182,72,${(k / this.trail.length) * 0.55})`;
        g.lineWidth = 4 + (k / this.trail.length) * 10;
        g.beginPath();
        g.moveTo(this.trail[k - 1].x, this.trail[k - 1].y);
        g.lineTo(this.trail[k].x, this.trail[k].y);
        g.stroke();
      }
      g.fillStyle = "rgba(255,182,72,0.9)";
      g.beginPath();
      g.arc(px, py, 20, 0, 7);
      g.fill();
      g.globalAlpha = 1;
    }

    // Screen view: the phone is sideways, showing the computer's screen.
    if (screen > 0.02) {
      g.globalAlpha = screen;
      g.fillStyle = "#05070f";
      g.fillRect(0, 0, W, H);
      g.save();
      g.translate(W, 0);
      g.rotate(Math.PI / 2);
      // Now drawing in a H x W landscape frame.
      const lw = H,
        lh = W;
      const fit = Math.min(lw / this.laptopCanvas.width, lh / this.laptopCanvas.height);
      const dw = this.laptopCanvas.width * fit,
        dh = this.laptopCanvas.height * fit;
      g.drawImage(this.laptopCanvas, (lw - dw) / 2, (lh - dh) / 2, dw, dh);
      g.restore();
      g.globalAlpha = 1;
    }

    this.phoneTex.needsUpdate = true;
  }
}
