// The hero, live: the film's graphite trackpad and studio (Design/DemoVideo/src/gl.js) with the
// hero choreography (Design/DemoVideo/src/hero.js), rendered in the page at the screen's own
// resolution. pose(t) is a pure function of the sequence clock (seconds), so scroll can drive it
// continuously instead of stepping through pictures.
//
//   0.0–1.6   the camera dives from straight down to a calm 3/4 view while a band of light runs
//             once around the rim; the edges power on
//   2.2–4.6   clipboard: double-tap the bottom-right corner, slide down the right edge, lift
//   5.0–7.4   per-app volume: lean right, slide the right edge down
//   7.8–10.0  brightness: lean left, slide the left edge down, the scene dims
//   10.0–12.0 corner taps (top right, top left), then pull back and settle
import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { ease, bezier, lerp, prog, ep, clamp, spring, seeded, swipe, levelAt, crossings } from './motion.js';

export const DURATION = 12;
/** The camera frames a 16:9 picture; the page places that picture (see render's rect). */
const ASPECT = 16 / 9;

const PAD = { w: 16, d: 10, r: 1.15, depth: 0.3, bevel: 0.07 };
const TEX = { w: 2048, h: 1280 };
// Edge zones in surface-canvas pixels.
const ZONES = { left: 118, right: TEX.w - 118, top: 150, bottom: TEX.h - 150 };

// ------------------------------------------------------------------ look

const LOOK = {
  exposure: 0.92,
  bloom: 0.85,
  tracks: 0.7,
  zone: 0.45, // resting edge-zone glow once the pad is on
  off: -0.35, // …and before it powers on
  offTracks: 0.3,
  edgeLight: 0.11, // soft light around each edge track, scaled by its zone glow
  finger: 1.3,
  // A soft bloom knee, so glows fade in instead of popping across the threshold.
  knee: { threshold: 0.66, width: 0.3 },
};

// Camera poses: the film's own path (straight down, then a 3/4 view), with a wider lens.
const OPEN = { elevation: 88, azimuth: 0, distance: 17.5, target: [0, 0, 0], fov: 38 };
const CALM = { elevation: 31, azimuth: -4.5, distance: 25.5, target: [0, -0.4, 0.9], fov: 38 };
const WIDE = { elevation: 1.5, distance: 2.2, target: [0, 0, 0] };
const LEAN = { right: 1.6, left: 4.5, x: 1.3, distance: 0.8 };
const SWAY = { azimuth: 0.6, elevation: 0.22 };

// ------------------------------------------------------------------ score

/** A one-finger edge slide. Levels are 0 (bottom of the edge) … 100 (top). */
const slideGesture = (side, appear, start, end, lift, liftEnd, from, to, ticks) => {
  const g = { side, appear, liftEnd, ticks, ...swipe(appear, start, end, lift, from, to, ease.inOut) };
  g.crossings = crossings(g, ticks.step, ticks.notch);
  return g;
};
const GESTURES = [
  slideGesture('right', 2.9, 3.0, 4.2, 4.3, 4.5, 88, 22, { step: 15, notch: -1 }), // clipboard
  slideGesture('right', 5.05, 5.2, 6.8, 6.9, 7.2, 80, 30, { step: 100 / 16, notch: 50 }), // volume
  slideGesture('left', 7.86, 8.0, 9.5, 9.5, 9.8, 80, 45, { step: 100 / 16, notch: 50 }), // brightness
];
const [CLIPBOARD, VOLUME, BRIGHTNESS] = GESTURES;

// Double taps just inside a corner (surface-canvas pixels).
const TAPS = [
  { x: 1876, y: 1108, at: [2.4, 2.55] }, // bottom right: clipboard
  { x: 1876, y: 174, at: [10.3, 10.45] }, // top right
  { x: 172, y: 174, at: [10.9, 11.05] }, // top left
];
const RIM_RUN = { from: 0, to: 1.5, tail: 0.2, startTail: 0.05, overshoot: 0.12 };
const POWER = [1.36, 1.66];

// ------------------------------------------------------------------ studio

function roundedRect(w, d, r) {
  const s = new THREE.Shape();
  const x = -w / 2, y = -d / 2;
  s.moveTo(x + r, y);
  s.lineTo(x + w - r, y);
  s.absarc(x + w - r, y + r, r, -Math.PI / 2, 0);
  s.lineTo(x + w, y + d - r);
  s.absarc(x + w - r, y + d - r, r, 0, Math.PI / 2);
  s.lineTo(x + r, y + d);
  s.absarc(x + r, y + d - r, r, Math.PI / 2, Math.PI);
  s.lineTo(x, y + r);
  s.absarc(x + r, y + r, r, Math.PI, Math.PI * 1.5);
  return s;
}

function gradientCanvas(size, stops) {
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d');
  const gradient = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  for (const [o, color] of stops) gradient.addColorStop(o, color);
  g.fillStyle = gradient;
  g.fillRect(0, 0, size, size);
  return c;
}
function gradientTexture(size, stops) {
  const texture = new THREE.CanvasTexture(gradientCanvas(size, stops));
  texture.colorSpace = THREE.SRGBColorSpace;
  return texture;
}

/** A dark studio with a few soft strip lights, so reflections read as clean highlights along the
 * bevels instead of a grey wash. */
function studio() {
  const room = new THREE.Scene();
  room.add(new THREE.Mesh(new THREE.BoxGeometry(60, 30, 60), new THREE.MeshBasicMaterial({ color: 0x030304, side: THREE.BackSide })));
  const strip = (w, hgt, intensity, x, y, z, rx, ry) => {
    const mesh = new THREE.Mesh(new THREE.PlaneGeometry(w, hgt), new THREE.MeshBasicMaterial({ color: new THREE.Color(intensity, intensity, intensity * 1.04), side: THREE.DoubleSide }));
    mesh.position.set(x, y, z);
    mesh.rotation.set(rx, ry, 0);
    room.add(mesh);
  };
  strip(26, 1.2, 2.3, 0, 13, -16, Math.PI / 2.6, 0); // long strip behind, catches the far bevel
  strip(1.4, 20, 1.6, -24, 8, 0, 0, Math.PI / 2); // tall strip to the left
  strip(1.4, 20, 1.2, 24, 8, 4, 0, -Math.PI / 2); // and to the right
  strip(18, 0.8, 0.5, 0, 14, 10, Math.PI / 2.2, 0); // faint front fill
  return room;
}

// ------------------------------------------------------------------ surface light

/** Surface-canvas coordinates for a point on an edge (side) at level p (0 bottom … 1 top). */
const edgePoint = (side, p) => ({ x: side === 'left' ? ZONES.left : ZONES.right, y: lerp(ZONES.bottom - 40, ZONES.top + 40, clamp(p)) });

// A soft light around each edge track, so a lit zone glows instead of reading as a flat bar. Built
// once at full strength with a fixed dither (so faint falloff never bands), then drawn with the
// zone's strength as alpha.
function edgeGlow() {
  const margin = 150, w = 70, h = ZONES.bottom - ZONES.top;
  const width = w + margin * 2, height = h + margin * 2;
  const c = document.createElement('canvas');
  c.width = width;
  c.height = height;
  const g = c.getContext('2d', { willReadFrequently: true });
  g.filter = 'blur(44px)';
  g.fillStyle = '#fff';
  g.beginPath();
  g.roundRect(margin, margin, w, h, w / 2);
  g.fill();
  const alpha = g.getImageData(0, 0, width, height).data;
  const random = seeded(7);
  const out = document.createElement('canvas');
  out.width = width;
  out.height = height;
  const og = out.getContext('2d');
  const image = og.createImageData(width, height);
  const d = image.data, k = 255 * LOOK.edgeLight;
  for (let i = 0, j = 0; i < alpha.length / 4; i++, j += 4) {
    const v = (alpha[i * 4 + 3] / 255) * k;
    d[j] = d[j + 1] = d[j + 2] = 255;
    d[j + 3] = v + (random() - random()) * Math.min(1, v);
  }
  og.putImageData(image, 0, 0);
  return { canvas: out, ox: margin + w / 2, oy: margin };
}

// The rim band's path, clockwise from the middle of the near edge.
function rimPath() {
  const inset = 24;
  const x0 = inset, y0 = inset, x1 = TEX.w - inset, y1 = TEX.h - inset;
  const r = (PAD.r * TEX.w) / PAD.w - inset;
  const cx = TEX.w / 2;
  const q = (Math.PI * r) / 2;
  const arc = (x, y, angle) => [x + r * Math.cos(angle), y + r * Math.sin(angle)];
  const parts = [
    { len: cx - (x0 + r), at: (u) => [cx - u, y1] },
    { len: q, at: (u) => arc(x0 + r, y1 - r, Math.PI / 2 + u / r) },
    { len: y1 - y0 - 2 * r, at: (u) => [x0, y1 - r - u] },
    { len: q, at: (u) => arc(x0 + r, y0 + r, Math.PI + u / r) },
    { len: x1 - x0 - 2 * r, at: (u) => [x0 + r + u, y0] },
    { len: q, at: (u) => arc(x1 - r, y0 + r, Math.PI * 1.5 + u / r) },
    { len: y1 - y0 - 2 * r, at: (u) => [x1, y0 + r + u] },
    { len: q, at: (u) => arc(x1 - r, y1 - r, u / r) },
    { len: x1 - r - cx, at: (u) => [x1 - r - u, y1] },
  ];
  const length = parts.reduce((sum, p) => sum + p.len, 0);
  const point = (s) => {
    s = ((s % length) + length) % length;
    for (const p of parts) {
      if (s <= p.len) return p.at(s);
      s -= p.len;
    }
    return parts[0].at(0);
  };
  return { length, point };
}
const RIM_EASE = bezier(0.4, 0, 0.6, 1);

// ------------------------------------------------------------------ the scene

export function createHero(canvas, { surfaceScale = 1, samples = 4 } = {}) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance' });
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.outputColorSpace = THREE.SRGBColorSpace;

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x060607);
  const pmrem = new THREE.PMREMGenerator(renderer);
  const env = pmrem.fromScene(studio(), 0.02);
  scene.environment = env.texture;
  pmrem.dispose();

  const camera = new THREE.PerspectiveCamera(OPEN.fov, ASPECT, 0.1, 400);

  // Floor: a soft pool of light under the trackpad, fading to the stage (black, or the page's
  // light grey in the light theme).
  const floorDark = gradientTexture(1024, [[0, '#1c1d21'], [0.18, '#141518'], [0.45, '#0a0a0b'], [1, '#060607']]);
  const floorLight = gradientTexture(1024, [[0, '#fbfbfd'], [0.45, '#f6f6f8'], [1, '#f5f5f7']]);
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(140, 140), new THREE.MeshBasicMaterial({ map: floorDark, toneMapped: false }));
  floor.rotation.x = -Math.PI / 2;
  floor.position.y = -0.12;
  scene.add(floor);
  const shadow = new THREE.Mesh(new THREE.PlaneGeometry(26, 18), new THREE.MeshBasicMaterial({
    map: gradientTexture(512, [[0, 'rgba(0,0,0,0.85)'], [0.55, 'rgba(0,0,0,0.5)'], [1, 'rgba(0,0,0,0)']]), transparent: true, depthWrite: false, toneMapped: false,
  }));
  shadow.rotation.x = -Math.PI / 2;
  shadow.position.set(0, -0.1, 0.5);
  scene.add(shadow);

  // The trackpad body: an extruded rounded rectangle with a soft bevel.
  const shape = roundedRect(PAD.w, PAD.d, PAD.r);
  const bodyGeometry = new THREE.ExtrudeGeometry(shape, { depth: PAD.depth, bevelEnabled: true, bevelThickness: PAD.bevel, bevelSize: PAD.bevel, bevelSegments: 8, curveSegments: 64 });
  bodyGeometry.rotateX(-Math.PI / 2);
  const body = new THREE.Mesh(bodyGeometry, new THREE.MeshPhysicalMaterial({
    color: 0x0f1012, metalness: 0.7, roughness: 0.42, clearcoat: 0.7, clearcoatRoughness: 0.2, envMapIntensity: 1,
  }));
  scene.add(body);

  // Surface graphics: a canvas mapped exactly onto the top face, drawn in TEX units.
  const surface = document.createElement('canvas');
  surface.width = Math.round(TEX.w * surfaceScale);
  surface.height = Math.round(TEX.h * surfaceScale);
  const sg = surface.getContext('2d');
  const surfaceTexture = new THREE.CanvasTexture(surface);
  surfaceTexture.colorSpace = THREE.SRGBColorSpace;
  surfaceTexture.anisotropy = renderer.capabilities.getMaxAnisotropy();
  const overlayGeometry = new THREE.ShapeGeometry(shape, 64);
  const uv = overlayGeometry.attributes.uv;
  for (let i = 0; i < uv.count; i++) uv.setXY(i, (uv.getX(i) + PAD.w / 2) / PAD.w, (uv.getY(i) + PAD.d / 2) / PAD.d);
  overlayGeometry.rotateX(-Math.PI / 2);
  const overlay = new THREE.Mesh(overlayGeometry, new THREE.MeshBasicMaterial({ map: surfaceTexture, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false }));
  overlay.position.y = PAD.depth + PAD.bevel + 0.004;
  scene.add(overlay);

  const key = new THREE.DirectionalLight(0xffffff, 0.35);
  key.position.set(-8, 14, 10);
  scene.add(key);
  const rim = new THREE.DirectionalLight(0xdfe7ff, 0.9);
  rim.position.set(6, 4, -14);
  scene.add(rim);

  const composer = new EffectComposer(renderer, new THREE.WebGLRenderTarget(16, 9, { type: THREE.HalfFloatType, samples }));
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(new THREE.Vector2(16, 9), LOOK.bloom, 0.6, LOOK.knee.threshold);
  bloom.highPassUniforms.smoothWidth.value = LOOK.knee.width;
  composer.addPass(bloom);
  composer.addPass(new OutputPass());

  const glow = edgeGlow();
  const RIM = rimPath();
  const CORE = gradientCanvas(64, [[0, 'rgba(255,255,255,1)'], [0.35, 'rgba(246,249,255,0.85)'], [0.7, 'rgba(230,238,255,0.25)'], [1, 'rgba(230,238,255,0)']]);
  const HALO = gradientCanvas(128, [[0, 'rgba(220,230,255,1)'], [0.4, 'rgba(205,218,255,0.35)'], [1, 'rgba(200,214,255,0)']]);

  // What the choreography controls.
  const pad = { elevation: 90, azimuth: 0, distance: 19, target: [0, 0, 0], fov: 38, exposure: 1, zones: { left: 0.5, right: 0.5 }, contacts: [], ripples: [], tracks: 1, rim: null };

  // ---------------------------------------------------------------- pose(t)

  function gesture(g, t) {
    const now = edgePoint(g.side, levelAt(g, t) / 100);
    const down = edgePoint(g.side, g.from / 100);
    const o = Math.min(ep(t, g.appear, g.appear + 0.2, ease.smooth), 1 - ease.smooth(prog(t, g.lift, g.liftEnd)));
    if (o > 0.001) {
      const press = 1 + 0.25 * (1 - spring(t - g.appear, 0.32, 0.55));
      const fromY = lerp(down.y, now.y, ease.smooth(prog(t, g.lift, g.lift + 0.5)));
      pad.contacts.push({ x: now.x, y: now.y, fromY, o, size: press * LOOK.finger });
    }
    // A tick ripple as the level passes each step (the film's haptic ticks).
    for (const c of g.crossings) {
      const age = t - c.t;
      if (age < 0 || age > 0.6) continue;
      const p = ease.out(age / 0.6);
      const at = edgePoint(g.side, c.value / 100);
      const ro = (1 - p) * (c.notch ? 0.7 : 0.36) * ease.smooth(clamp(age / 0.07));
      pad.ripples.push({ x: at.x, y: at.y, r: 34 + p * (c.notch ? 150 : 85), o: ro, w: c.notch ? 7 : 4.5 });
    }
  }
  const zoneLight = (g, t) => Math.min(ep(t, g.appear, g.appear + 0.25, ease.smooth), 1 - ease.smooth(prog(t, g.lift, g.liftEnd + 0.35)));
  function taps(t) {
    for (const corner of TAPS) {
      const [first, last] = corner.at;
      // One soft glow held across both taps, so the double tap reads through its two rings.
      const press = Math.min(ep(t, first - 0.1, first, ease.smooth), 1 - ease.smooth(prog(t, last + 0.03, last + 0.32)));
      if (press > 0.001) pad.contacts.push({ x: corner.x, y: corner.y, o: press * 0.6, size: 0.72 * LOOK.finger });
      for (const tt of corner.at) {
        const age = t - tt;
        if (age < 0 || age > 0.8) continue;
        const p = ease.out(age / 0.8);
        pad.ripples.push({ x: corner.x, y: corner.y, r: 22 + p * 150, o: (1 - p) * 0.8 * ease.smooth(clamp(age / 0.07)), w: 5 * (1 - p) + 1.5 });
      }
    }
  }
  function rimAt(t) {
    const { from, to, tail, overshoot } = RIM_RUN;
    if (t < from || t >= to) return null;
    const p = prog(t, from, to);
    const head = RIM_EASE(p) * RIM.length * (1 + overshoot);
    const length = RIM.length * lerp(RIM_RUN.startTail, tail, ease.smooth(prog(p, 0, 0.35)));
    const o = Math.min(0.7 + 0.3 * ease.smooth(prog(p, 0, 0.15)), 1 - ease.smooth(prog(p, 0.7, 1)));
    return { head, tail: length, o };
  }
  function cameraAt(t) {
    // The dive: pull back from straight down while tilting to the 3/4 view.
    const back = ease.smooth(prog(t, 0, 1.55));
    const tilt = ease.smooth(prog(t, 0, 1.6));
    // Idle sway, breathing in after the dive and out before the last frames.
    const sway = ease.smooth(prog(t, 1.3, 2.4)) * (1 - ease.smooth(prog(t, 10.9, 11.9)));
    const swayA = Math.sin(((t - 1.3) / 6.4) * Math.PI * 2) * SWAY.azimuth * sway;
    const swayE = Math.sin(((t - 1.3) / 8.6) * Math.PI * 2) * SWAY.elevation * sway;
    // Leans toward the edge in use.
    const right = Math.min(ease.inOut(prog(t, 4.95, 5.95)), 1 - ease.inOut(prog(t, 6.85, 7.4)));
    const left = Math.min(ease.inOut(prog(t, 7.75, 8.75)), 1 - ease.inOut(prog(t, 9.45, 10.0)));
    const wide = ease.smooth(prog(t, 11.0, 11.95));
    pad.fov = lerp(OPEN.fov, CALM.fov, back);
    pad.elevation = lerp(OPEN.elevation, CALM.elevation, tilt) + swayE + wide * WIDE.elevation;
    pad.azimuth = lerp(OPEN.azimuth, CALM.azimuth, tilt) + swayA - right * LEAN.right + left * LEAN.left;
    pad.distance = lerp(OPEN.distance, CALM.distance, back) - (right + left) * LEAN.distance + wide * WIDE.distance;
    pad.target = [
      (right - left) * LEAN.x,
      lerp(OPEN.target[1], CALM.target[1], back) + wide * WIDE.target[1],
      lerp(OPEN.target[2], CALM.target[2], back) + wide * WIDE.target[2],
    ];
  }
  function pose(t) {
    t = clamp(t, 0, DURATION);
    cameraAt(t);
    // Power on: the edge zones start dark and glow up as the rim light closes its loop.
    const on = ease.smooth(prog(t, POWER[0], POWER[1]));
    const rest = lerp(LOOK.off, LOOK.zone, on);
    pad.tracks = lerp(LOOK.offTracks, LOOK.tracks, on);
    pad.zones.right = rest + (1 - rest) * Math.max(zoneLight(CLIPBOARD, t), zoneLight(VOLUME, t));
    pad.zones.left = rest + (1 - rest) * zoneLight(BRIGHTNESS, t);
    pad.contacts = [];
    pad.ripples = [];
    taps(t);
    for (const g of GESTURES) gesture(g, t);
    pad.rim = rimAt(t);
    // Brightness dims the whole picture as the left edge slides down, then eases back.
    const dim = ((BRIGHTNESS.from - levelAt(BRIGHTNESS, t)) / (BRIGHTNESS.from - BRIGHTNESS.to)) * (1 - ease.inOut(prog(t, 9.55, 10.0)));
    pad.exposure = LOOK.exposure * (1 - 0.3 * dim);
  }

  // ---------------------------------------------------------------- surface

  function drawRim({ head, tail, o }) {
    if (o <= 0.002) return;
    const step = 3, n = Math.ceil(tail / step);
    for (let k = n; k >= 0; k--) {
      const u = (k * step) / tail;
      if (u >= 1) continue;
      const fall = Math.pow(1 - u, 2.4);
      if (fall <= 0.001) continue;
      const [x, y] = RIM.point(head - k * step);
      sg.globalAlpha = clamp(0.05 * fall * o);
      sg.drawImage(HALO, x - 46, y - 46, 92, 92);
      sg.globalAlpha = clamp(0.16 * fall * o);
      sg.drawImage(CORE, x - 13, y - 13, 26, 26);
    }
    const [hx, hy] = RIM.point(head);
    sg.globalAlpha = clamp(0.4 * o);
    sg.drawImage(HALO, hx - 75, hy - 75, 150, 150);
    sg.globalAlpha = clamp(0.9 * o);
    sg.drawImage(CORE, hx - 24, hy - 24, 48, 48);
    sg.globalAlpha = 1;
  }

  // The surface only changes during gestures, taps and the rim run; redrawing and re-uploading
  // it only then keeps the camera-only stretches cheap.
  let surfaceKey = '';
  const r2 = (v) => Math.round(v * 100) / 100;
  function drawSurface() {
    const keyNow = JSON.stringify([
      r2(pad.zones.left), r2(pad.zones.right), r2(pad.tracks),
      pad.contacts.map((c) => [r2(c.x), r2(c.y), r2(c.fromY ?? 0), r2(c.o), r2(c.size ?? 1)]),
      pad.ripples.map((r) => [r2(r.r), r2(r.o), r2(r.w ?? 5)]),
      pad.rim && [r2(pad.rim.head), r2(pad.rim.o)],
    ]);
    if (keyNow === surfaceKey) return;
    surfaceKey = keyNow;
    sg.setTransform(surfaceScale, 0, 0, surfaceScale, 0, 0);
    sg.clearRect(0, 0, TEX.w, TEX.h);
    sg.globalCompositeOperation = 'lighter';
    for (const side of ['left', 'right']) {
      const a = clamp(pad.zones[side], 0, 1);
      if (a <= 0.01) continue;
      sg.globalAlpha = a;
      sg.drawImage(glow.canvas, ZONES[side] - glow.ox, ZONES.top - glow.oy);
    }
    sg.globalAlpha = 1;
    if (pad.rim) drawRim(pad.rim);
    sg.globalCompositeOperation = 'source-over';
    const zoneW = 150;
    for (const side of ['left', 'right']) {
      const x = side === 'left' ? ZONES.left : ZONES.right;
      const a = pad.zones[side];
      sg.fillStyle = `rgba(255,255,255,${Math.max(0, 0.018 + a * 0.03)})`;
      sg.beginPath();
      sg.roundRect(x - zoneW / 2, ZONES.top - 40, zoneW, ZONES.bottom - ZONES.top + 80, 60);
      sg.fill();
      sg.fillStyle = `rgba(255,255,255,${Math.max(0, (0.035 + a * 0.05) * pad.tracks)})`;
      sg.beginPath();
      sg.roundRect(x - 17, ZONES.top, 34, ZONES.bottom - ZONES.top, 17);
      sg.fill();
    }
    for (const r of pad.ripples) {
      sg.strokeStyle = `rgba(238,243,255,${r.o})`;
      sg.lineWidth = r.w ?? 5;
      sg.beginPath();
      sg.arc(r.x, r.y, r.r, 0, Math.PI * 2);
      sg.stroke();
    }
    for (const c of pad.contacts) {
      if (c.o <= 0.001) continue;
      if (c.fromY != null && Math.abs(c.fromY - c.y) > 2) {
        const gradient = sg.createLinearGradient(c.x, c.fromY, c.x, c.y);
        gradient.addColorStop(0, 'rgba(150,170,220,0)');
        gradient.addColorStop(1, `rgba(236,242,255,${0.85 * c.o})`);
        sg.fillStyle = gradient;
        sg.beginPath();
        const y0 = Math.min(c.fromY, c.y), y1 = Math.max(c.fromY, c.y);
        sg.roundRect(c.x - 17, y0 - 17, 34, y1 - y0 + 34, 17);
        sg.fill();
      }
      const g = sg.createRadialGradient(c.x, c.y, 0, c.x, c.y, 260 * (c.size ?? 1));
      g.addColorStop(0, `rgba(225,233,255,${0.42 * c.o})`);
      g.addColorStop(0.3, `rgba(200,214,255,${0.14 * c.o})`);
      g.addColorStop(1, 'rgba(200,214,255,0)');
      sg.fillStyle = g;
      sg.fillRect(c.x - 300, c.y - 300, 600, 600);
      sg.fillStyle = `rgba(255,255,255,${c.o})`;
      sg.beginPath();
      sg.arc(c.x, c.y, 31 * (c.size ?? 1), 0, Math.PI * 2);
      sg.fill();
    }
    surfaceTexture.needsUpdate = true;
  }

  // ---------------------------------------------------------------- frame

  let view = { w: 1, h: 1 };
  function resize(w, h, dpr) {
    view = { w, h };
    renderer.setPixelRatio(dpr);
    renderer.setSize(w, h, false);
    composer.setPixelRatio(dpr);
    composer.setSize(w, h);
  }

  /** Draws the pose at t. rect is where the camera's 16:9 picture sits on the canvas (CSS px);
   * the canvas shows that picture and the studio around it, with the film's perspective. */
  function render(t, rect) {
    pose(t);
    const e = THREE.MathUtils.degToRad(pad.elevation), a = THREE.MathUtils.degToRad(pad.azimuth);
    const [tx, ty, tz] = pad.target;
    camera.fov = pad.fov;
    camera.aspect = ASPECT;
    camera.position.set(tx + pad.distance * Math.cos(e) * Math.sin(a), ty + pad.distance * Math.sin(e), tz + pad.distance * Math.cos(e) * Math.cos(a) + 0.0001);
    camera.lookAt(tx, ty, tz);
    camera.setViewOffset(rect.w, rect.h, -rect.x, -rect.y, view.w, view.h);
    renderer.toneMappingExposure = pad.exposure;
    drawSurface();
    composer.render();
  }

  /** The rendered colour at the canvas's bottom-left corner, for the stage around it. */
  function corner() {
    const gl = renderer.getContext();
    const px = new Uint8Array(4);
    gl.readPixels(1, 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
    return [px[0], px[1], px[2]];
  }

  /** Light or dark studio. In light, the floor is the page's grey and bloom takes only the edge
   * light, never the bright floor. */
  let darkStudio = true;
  // Filmic tone mapping greys a plain #f5f5f7 to about #dadada; solving its curve backwards, ~2.7×
  // (linear) lands on the page's #f5f5f7, so the studio meets the next section with no seam.
  const LIGHT_STAGE = 2.95;
  function setTheme(dark) {
    darkStudio = dark;
    scene.background = dark ? new THREE.Color(0x060607) : new THREE.Color().setRGB(2.71, 2.71, 3.0);
    floor.material.map = dark ? floorDark : floorLight;
    floor.material.color.setScalar(dark ? 1 : LIGHT_STAGE);
    floor.material.needsUpdate = true;
    shadow.material.opacity = dark ? 1 : 0.42;
    // Bloom only above the bright stage, so in light it never washes the floor.
    bloom.threshold = dark ? LOOK.knee.threshold : 3.4;
    bloom.strength = dark ? LOOK.bloom : 0.5;
  }

  function dispose() {
    composer.dispose();
    env.dispose();
    (darkStudio ? floorLight : floorDark).dispose();
    surfaceTexture.dispose();
    scene.traverse((o) => {
      if (o.geometry) o.geometry.dispose();
      if (o.material) { o.material.map?.dispose(); o.material.dispose(); }
    });
    renderer.dispose();
  }

  return { resize, render, corner, setTheme, dispose };
}
