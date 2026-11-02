// SPDX-License-Identifier: GPL-3.0-or-later
import * as THREE from "three";

const DEG = Math.PI / 180;

export function toVec(lat: number, lng: number, r = 1) {
  const phi = (90 - lat) * DEG;
  const theta = (lng + 180) * DEG;
  return new THREE.Vector3(-r * Math.sin(phi) * Math.cos(theta), r * Math.cos(phi), r * Math.sin(phi) * Math.sin(theta));
}

export type Pin = { lat: number; lng: number; color: number };

/**
 * A dotted globe: land as round blue dots that fade towards the back, a few
 * pins, and an arc from the first pin to the last through the others, with
 * packets travelling along it.
 */
export class Globe {
  private renderer: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private camera = new THREE.PerspectiveCamera(32, 1, 0.1, 50);
  private world = new THREE.Group();
  private spin = new THREE.Group();
  private tilt = new THREE.Group();
  private arcs: { geo: THREE.TubeGeometry; total: number }[] = [];
  private packets: { mesh: THREE.Mesh; curve: THREE.Curve<THREE.Vector3>; offset: number }[] = [];
  private rings: THREE.Mesh[] = [];
  private pinTips: THREE.Vector3[] = [];
  private raf = 0;
  private running = false;
  private clock = new THREE.Clock();
  private reveal = 0;
  private dotMat: THREE.ShaderMaterial;
  onFrame: ((screen: { x: number; y: number; front: boolean }[]) => void) | null = null;

  constructor(
    private canvas: HTMLCanvasElement,
    dots: number[],
    pins: Pin[],
    private reduced: boolean,
  ) {
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: "low-power" });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.setClearColor(0x000000, 0);
    this.camera.position.set(0, 0, 4.4);
    this.scene.add(this.tilt);
    this.tilt.add(this.spin);
    this.spin.add(this.world);

    // a pale disc so back dots read as "behind"
    const ball = new THREE.Mesh(
      new THREE.SphereGeometry(0.985, 64, 48),
      new THREE.MeshBasicMaterial({ color: 0xf3f6fd, transparent: true, opacity: 0.92 }),
    );
    this.world.add(ball);

    const pos = new Float32Array((dots.length / 2) * 3);
    for (let i = 0; i < dots.length; i += 2) {
      const v = toVec(dots[i], dots[i + 1]);
      pos.set([v.x, v.y, v.z], (i / 2) * 3);
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    this.dotMat = new THREE.ShaderMaterial({
      transparent: true,
      depthWrite: false,
      uniforms: {
        uSize: { value: 3.9 * Math.min(window.devicePixelRatio, 2) },
        uColor: { value: new THREE.Color(0x3d6ff5) },
        uReveal: { value: reduced ? 1 : 0 },
      },
      vertexShader: /* glsl */ `
        uniform float uSize;
        uniform float uReveal;
        varying float vFace;
        varying float vShow;
        void main() {
          vec4 mv = modelViewMatrix * vec4(position, 1.0);
          vec3 n = normalize(normalMatrix * position);
          vFace = dot(n, normalize(-mv.xyz));
          // land appears from top to bottom as the globe is revealed
          vShow = smoothstep(position.y - 0.25, position.y, uReveal * 2.6 - 1.3);
          gl_PointSize = uSize * (4.4 / -mv.z);
          gl_Position = projectionMatrix * mv;
        }`,
      fragmentShader: /* glsl */ `
        uniform vec3 uColor;
        varying float vFace;
        varying float vShow;
        void main() {
          vec2 c = gl_PointCoord - 0.5;
          float d = length(c);
          if (d > 0.5) discard;
          float a = smoothstep(0.5, 0.36, d) * mix(0.1, 0.78, smoothstep(-0.15, 0.6, vFace)) * vShow;
          gl_FragColor = vec4(uColor, a);
        }`,
    });
    this.world.add(new THREE.Points(geo, this.dotMat));

    // pins
    const pts = pins.map((p) => toVec(p.lat, p.lng));
    pins.forEach((p, i) => {
      const base = pts[i];
      const tip = base.clone().multiplyScalar(1.09);
      const col = new THREE.MeshBasicMaterial({ color: p.color });
      const stem = new THREE.Mesh(new THREE.CylinderGeometry(0.006, 0.006, 0.09, 8), col);
      stem.position.copy(base.clone().multiplyScalar(1.045));
      stem.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), base.clone().normalize());
      const head = new THREE.Mesh(new THREE.SphereGeometry(0.03, 20, 14), col);
      head.position.copy(tip);
      const ring = new THREE.Mesh(
        new THREE.RingGeometry(0.03, 0.045, 40),
        new THREE.MeshBasicMaterial({ color: p.color, transparent: true, side: THREE.DoubleSide, depthWrite: false }),
      );
      ring.position.copy(base.clone().multiplyScalar(1.003));
      ring.lookAt(base.clone().multiplyScalar(2));
      this.world.add(stem, head, ring);
      this.rings.push(ring);
      this.pinTips.push(tip);
    });

    // arcs between consecutive pins
    for (let i = 0; i < pts.length - 1; i++) {
      const a = pts[i];
      const b = pts[i + 1];
      const mid = a.clone().add(b).normalize().multiplyScalar(1 + a.distanceTo(b) * 0.45);
      const curve = new THREE.QuadraticBezierCurve3(a.clone().multiplyScalar(1.01), mid, b.clone().multiplyScalar(1.01));
      const tube = new THREE.TubeGeometry(curve, 96, 0.0075, 8, false);
      const total = tube.index ? tube.index.count : 0;
      tube.setDrawRange(0, reduced ? total : 0);
      this.world.add(new THREE.Mesh(tube, new THREE.MeshBasicMaterial({ color: 0xff7a1a })));
      this.arcs.push({ geo: tube, total });
      for (let k = 0; k < 2; k++) {
        const m = new THREE.Mesh(new THREE.SphereGeometry(0.022, 16, 12), new THREE.MeshBasicMaterial({ color: 0xff7a1a }));
        m.visible = false;
        this.world.add(m);
        this.packets.push({ mesh: m, curve, offset: k * 0.5 + i * 0.25 });
      }
    }

    // Turn the globe so the middle of the pins faces the camera, north up,
    // tipped a little so they sit just above the centre.
    const centre = pts.reduce((s, v) => s.add(v), new THREE.Vector3()).normalize();
    this.world.rotation.y = Math.atan2(-centre.x, centre.z);
    this.tilt.rotation.x = Math.asin(centre.y) - 0.22;
  }

  resize(w: number, h: number) {
    this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
  }

  /** 0 → 1: dots appear, then the arcs draw. Driven by scroll. */
  setReveal(v: number) {
    this.reveal = Math.min(1, Math.max(0, v));
    if (!this.running) this.render(0);
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.clock.getDelta();
    const loop = () => {
      if (!this.running) return;
      this.render(this.clock.getElapsedTime());
      this.raf = requestAnimationFrame(loop);
    };
    loop();
  }

  stop() {
    this.running = false;
    cancelAnimationFrame(this.raf);
  }

  private render(t: number) {
    const r = this.reduced ? 1 : this.reveal;
    this.dotMat.uniforms.uReveal.value = Math.min(1, r * 1.6);
    const arcT = Math.min(1, Math.max(0, (r - 0.45) / 0.45));
    this.arcs.forEach(({ geo, total }, i) => {
      const local = Math.min(1, Math.max(0, arcT * this.arcs.length - i));
      geo.setDrawRange(0, Math.floor((total * local) / 3) * 3);
    });
    const live = arcT >= 1;
    this.packets.forEach((p) => {
      p.mesh.visible = live && !this.reduced;
      if (p.mesh.visible) p.mesh.position.copy(p.curve.getPoint((t * 0.32 + p.offset) % 1));
    });
    this.rings.forEach((ring, i) => {
      const k = this.reduced ? 0.5 : (t * 0.6 + i * 0.33) % 1;
      ring.scale.setScalar(1 + k * 2.4);
      (ring.material as THREE.MeshBasicMaterial).opacity = 0.8 * (1 - k);
    });
    if (!this.reduced) this.spin.rotation.y = Math.sin(t * 0.25) * 0.22;

    this.renderer.render(this.scene, this.camera);

    if (this.onFrame) {
      const w = this.canvas.clientWidth;
      const h = this.canvas.clientHeight;
      const camDir = this.camera.position.clone().normalize();
      this.onFrame(
        this.pinTips.map((tip) => {
          const world = tip.clone().applyMatrix4(this.world.matrixWorld);
          const front = world.clone().normalize().dot(camDir) > 0.15;
          const ndc = world.project(this.camera);
          return { x: (ndc.x * 0.5 + 0.5) * w, y: (-ndc.y * 0.5 + 0.5) * h, front };
        }),
      );
    }
  }

  dispose() {
    this.stop();
    this.scene.traverse((o) => {
      const m = o as THREE.Mesh;
      m.geometry?.dispose();
      const mat = m.material as THREE.Material | THREE.Material[] | undefined;
      if (Array.isArray(mat)) mat.forEach((x) => x.dispose());
      else mat?.dispose();
    });
    this.renderer.dispose();
  }
}
