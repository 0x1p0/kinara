// The film's one set: a graphite trackpad on a black gloss floor, and a screen
// floating behind it. The screen's picture is real DOM (src/desktop.js), laid
// onto the screen's face with the camera's own matrix, so its text stays
// sharp; WebGL draws everything that light does: the slab, the glow the
// screen throws on the trackpad, its reflection in the floor, and the bloom.
import * as THREE from "three";
import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
import { ShaderPass } from "three/addons/postprocessing/ShaderPass.js";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
import { OutputPass } from "three/addons/postprocessing/OutputPass.js";
import { Reflector } from "three/addons/objects/Reflector.js";
import { RectAreaLightUniformsLib } from "three/addons/lights/RectAreaLightUniformsLib.js";
import { lerp, clamp } from "./timeline.js";

export const PAD = { w: 16, d: 10, r: 1.15, depth: 0.3, bevel: 0.07 };
export const PAD_TOP = PAD.depth + PAD.bevel;
export const TEX = { w: 2048, h: 1280 };
// Edge zones in surface-canvas pixels.
export const ZONES = { left: 118, right: TEX.w - 118, top: 150, bottom: TEX.h - 150 };
// The screen, in points, and where it floats. One point is UNIT world units.
export const SCREEN = { w: 1280, h: 800, bezel: 20, radius: 15 };
export const UNIT = 30 / SCREEN.w;
export const DISPLAY = { x: 0, y: 11.3, z: -13.5, tilt: 5 };
const FRAME = { w: 1920, h: 1080 };

/** Surface-canvas coordinates for a point on an edge (side) at level p (0 bottom … 1 top). */
export function edgePoint(side, p) {
  return { x: side === "left" ? ZONES.left : ZONES.right, y: lerp(ZONES.bottom - 40, ZONES.top + 40, clamp(p)) };
}
/** Where a surface-canvas point is in the world. */
export const padPoint = (x, y, lift = 0) => [(x / TEX.w - 0.5) * PAD.w, PAD_TOP + lift, (y / TEX.h - 0.5) * PAD.d];
/** Where a point on the screen (in points, from its top-left) is in the world. */
export function screenPoint(x, y) {
  const a = THREE.MathUtils.degToRad(-DISPLAY.tilt);
  const lx = (x - SCREEN.w / 2) * UNIT, ly = -(y - SCREEN.h / 2) * UNIT;
  return [DISPLAY.x + lx, DISPLAY.y + ly * Math.cos(a), DISPLAY.z + ly * Math.sin(a)];
}

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

function gradientTexture(size, stops) {
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const g = c.getContext("2d");
  const gradient = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  for (const [o, color] of stops) gradient.addColorStop(o, color);
  g.fillStyle = gradient;
  g.fillRect(0, 0, size, size);
  const texture = new THREE.CanvasTexture(c);
  texture.colorSpace = THREE.SRGBColorSpace;
  return texture;
}

/** A dark studio with a few soft strip lights, so reflections read as clean
 * highlights along the bevels instead of a grey wash. */
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
  strip(1.4, 20, 1.2, -24, 8, 0, 0, Math.PI / 2); // tall strip to the left
  strip(1.4, 20, 0.75, 24, 8, 4, 0, -Math.PI / 2); // and to the right
  strip(18, 0.8, 0.5, 0, 14, 10, Math.PI / 2.2, 0); // faint front fill
  return room;
}

// The floor: black gloss. It mirrors the set, softly, more at grazing angles,
// and less the further the reflection is from the middle of the set.
const FloorShader = {
  name: "FloorShader",
  uniforms: {
    color: { value: null }, tDiffuse: { value: null }, textureMatrix: { value: null },
    strength: { value: 1.5 }, pool: { value: 1 }, texel: { value: new THREE.Vector2(1 / 960, 1 / 540) },
  },
  vertexShader: /* glsl */ `
    uniform mat4 textureMatrix;
    varying vec4 vUv;
    varying vec3 vWorld;
    void main() {
      vUv = textureMatrix * vec4(position, 1.0);
      vec4 world = modelMatrix * vec4(position, 1.0);
      vWorld = world.xyz;
      gl_Position = projectionMatrix * viewMatrix * world;
    }`,
  fragmentShader: /* glsl */ `
    uniform sampler2D tDiffuse;
    uniform float strength;
    uniform float pool;
    uniform vec2 texel;
    varying vec4 vUv;
    varying vec3 vWorld;
    void main() {
      vec2 uv = vUv.xy / vUv.w;
      // Soft, from the mirror's smaller copies, so a bright point never breaks into dots.
      vec3 sum = vec3(0.0);
      float total = 0.0;
      for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
          float w = exp(-float(i * i + j * j) / 4.0);
          sum += min(textureLod(tDiffuse, uv + vec2(float(i), float(j)) * texel * 6.0, 3.6).rgb, vec3(2.5)) * w;
          total += w;
        }
      }
      vec3 mirror = sum / total;
      vec3 view = normalize(cameraPosition - vWorld);
      float fresnel = 0.16 + 0.84 * pow(1.0 - clamp(view.y, 0.0, 1.0), 3.0);
      float reach = 1.0 - smoothstep(18.0, 62.0, length(vWorld.xz - vec2(0.0, -6.0)));
      float d = length(vWorld.xz);
      vec3 base = mix(vec3(0.0105, 0.011, 0.0125), vec3(0.0012), smoothstep(1.0, 34.0, d)) * pool;
      gl_FragColor = vec4(base + mirror * strength * fresnel * reach, 1.0);
    }`,
};

// A lens that is only sharp around one height of the frame: on a floor seen
// at an angle, that is what depth of field looks like.
const FocusShader = {
  name: "FocusShader",
  uniforms: { tDiffuse: { value: null }, focus: { value: 0.5 }, range: { value: 0.4 }, amount: { value: 0 }, aspect: { value: FRAME.h / FRAME.w } },
  vertexShader: /* glsl */ `varying vec2 vUv; void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
  fragmentShader: /* glsl */ `
    uniform sampler2D tDiffuse;
    uniform float focus;
    uniform float range;
    uniform float amount;
    uniform float aspect;
    varying vec2 vUv;
    void main() {
      float r = amount * smoothstep(0.02, range, abs(vUv.y - focus));
      if (r < 0.0004) { gl_FragColor = texture2D(tDiffuse, vUv); return; }
      vec3 sum = vec3(0.0);
      for (int i = 0; i < 56; i++) {
        float f = float(i);
        float a = f * 2.39996323;
        float rr = sqrt((f + 0.5) / 56.0) * r;
        sum += texture2D(tDiffuse, vUv + vec2(cos(a) * aspect, sin(a)) * rr).rgb;
      }
      gl_FragColor = vec4(sum / 56.0, 1.0);
    }`,
};

// The last thing the lens does: a grain finer than one step of brightness, so
// the studio's dark gradients reach the 8-bit frame without banding.
const DitherShader = {
  name: "DitherShader",
  uniforms: { tDiffuse: { value: null }, seed: { value: 0 } },
  vertexShader: /* glsl */ `varying vec2 vUv; void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
  fragmentShader: /* glsl */ `
    uniform sampler2D tDiffuse;
    uniform float seed;
    varying vec2 vUv;
    float hash(vec2 p) { vec3 q = fract(vec3(p.xyx) * 0.1031); q += dot(q, q.yzx + 33.33); return fract((q.x + q.y) * q.z); }
    void main() {
      vec4 color = texture2D(tDiffuse, vUv);
      float n = hash(gl_FragCoord.xy + seed) + hash(gl_FragCoord.xy + seed + 17.0) - 1.0;
      gl_FragColor = vec4(color.rgb + n / 255.0, color.a);
    }`,
};

const rgb = (c) => `rgb(${c[0] | 0},${c[1] | 0},${c[2] | 0})`;
const rgba = (c, a) => `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},${a})`;

export async function createWorld(canvas) {
  const ratio = window.devicePixelRatio || 1;
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true, powerPreference: "high-performance" });
  renderer.setPixelRatio(ratio);
  renderer.setSize(FRAME.w, FRAME.h, false);
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  RectAreaLightUniformsLib.init();

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x030304);
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(studio(), 0.02).texture;
  // Nothing is ever within a few units of the lens, and a distant near plane keeps
  // depth precise enough that what lies on a surface never fights it for pixels.
  const camera = new THREE.PerspectiveCamera(30, FRAME.w / FRAME.h, 3, 400);

  // ---------------------------------------------------------------- floor
  const floor = new Reflector(new THREE.PlaneGeometry(400, 400), { textureWidth: 960, textureHeight: 540, shader: FloorShader, clipBias: 0.003, multisample: 0 });
  floor.rotation.x = -Math.PI / 2;
  floor.position.y = -0.12;
  floor.getRenderTarget().texture.generateMipmaps = true;
  floor.getRenderTarget().texture.minFilter = THREE.LinearMipmapLinearFilter;
  scene.add(floor);
  // A contact shadow, close under the trackpad.
  const shadow = new THREE.Mesh(new THREE.PlaneGeometry(20.5, 14), new THREE.MeshBasicMaterial({
    map: gradientTexture(512, [[0, "rgba(0,0,0,0.95)"], [0.62, "rgba(0,0,0,0.7)"], [1, "rgba(0,0,0,0)"]]), transparent: true, depthWrite: false, toneMapped: false, polygonOffset: true, polygonOffsetFactor: -4, polygonOffsetUnits: -8,
  }));
  shadow.rotation.x = -Math.PI / 2;
  shadow.position.set(0, -0.1, 0.3);
  scene.add(shadow);

  // ---------------------------------------------------------------- trackpad
  const shape = roundedRect(PAD.w, PAD.d, PAD.r);
  const bodyGeometry = new THREE.ExtrudeGeometry(shape, { depth: PAD.depth, bevelEnabled: true, bevelThickness: PAD.bevel, bevelSize: PAD.bevel, bevelSegments: 8, curveSegments: 64 });
  bodyGeometry.rotateX(-Math.PI / 2);
  const body = new THREE.Mesh(bodyGeometry, new THREE.MeshPhysicalMaterial({ color: 0x0f1012, metalness: 0.7, roughness: 0.4, clearcoat: 0.7, clearcoatRoughness: 0.2, envMapIntensity: 1 }));
  scene.add(body);

  // Surface graphics: a canvas mapped exactly onto the top face.
  const surface = document.createElement("canvas");
  surface.width = TEX.w;
  surface.height = TEX.h;
  const sg = surface.getContext("2d");
  const surfaceTexture = new THREE.CanvasTexture(surface);
  surfaceTexture.colorSpace = THREE.SRGBColorSpace;
  surfaceTexture.anisotropy = renderer.capabilities.getMaxAnisotropy();
  const overlayGeometry = new THREE.ShapeGeometry(shape, 64);
  const uv = overlayGeometry.attributes.uv;
  for (let i = 0; i < uv.count; i++) uv.setXY(i, (uv.getX(i) + PAD.w / 2) / PAD.w, (uv.getY(i) + PAD.d / 2) / PAD.d);
  overlayGeometry.rotateX(-Math.PI / 2);
  const overlay = new THREE.Mesh(overlayGeometry, new THREE.MeshBasicMaterial({ map: surfaceTexture, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false, polygonOffset: true, polygonOffsetFactor: -4, polygonOffsetUnits: -8 }));
  overlay.position.y = PAD_TOP + 0.012;
  scene.add(overlay);

  // ---------------------------------------------------------------- screen
  const display = new THREE.Group();
  display.position.set(DISPLAY.x, DISPLAY.y, DISPLAY.z);
  display.rotation.x = THREE.MathUtils.degToRad(-DISPLAY.tilt);
  scene.add(display);
  const faceW = (SCREEN.w + SCREEN.bezel * 2) * UNIT, faceH = (SCREEN.h + SCREEN.bezel * 2) * UNIT;
  // The slab stays a hair inside the DOM face in front of it, bevel included: if
  // its bright rim showed round the screen's edge it would sparkle as the camera moves.
  const slabGeometry = new THREE.ExtrudeGeometry(roundedRect(faceW - 0.2, faceH - 0.2, 30 * UNIT - 0.06), { depth: 0.26, bevelEnabled: true, bevelThickness: 0.05, bevelSize: 0.05, bevelSegments: 6, curveSegments: 32 });
  slabGeometry.translate(0, 0, -0.31);
  const slab = new THREE.Mesh(slabGeometry, new THREE.MeshPhysicalMaterial({ color: 0x16171a, metalness: 0.85, roughness: 0.32, clearcoat: 0.4, clearcoatRoughness: 0.3 }));
  display.add(slab);
  // What the screen shines: a small picture of its wallpaper and lights. The
  // DOM covers it on the screen itself; it is what blooms and what the floor mirrors.
  const shine = document.createElement("canvas");
  shine.width = 640;
  shine.height = 400;
  const lg = shine.getContext("2d");
  const calm = document.createElement("canvas");
  calm.width = shine.width;
  calm.height = shine.height;
  const cg = calm.getContext("2d");
  const shineTexture = new THREE.CanvasTexture(shine);
  shineTexture.colorSpace = THREE.SRGBColorSpace;
  const shineMaterial = new THREE.MeshBasicMaterial({ map: shineTexture, toneMapped: false });
  const face = new THREE.Mesh(new THREE.PlaneGeometry(SCREEN.w * UNIT, SCREEN.h * UNIT), shineMaterial);
  face.position.z = 0.03;
  display.add(face);
  // The screen as a lamp, and a second small lamp wherever Kinara's light is.
  const lamp = new THREE.RectAreaLight(0xffffff, 0, SCREEN.w * UNIT, SCREEN.h * UNIT);
  lamp.position.z = 0.05;
  lamp.rotation.y = Math.PI;
  display.add(lamp);
  const neon = new THREE.RectAreaLight(0xffffff, 0, 1, 4);
  neon.rotation.y = Math.PI;
  display.add(neon);

  const key = new THREE.DirectionalLight(0xffffff, 0.35);
  key.position.set(-8, 14, 10);
  scene.add(key);
  const rim = new THREE.DirectionalLight(0xdfe7ff, 0.9);
  rim.position.set(6, 4, -14);
  scene.add(rim);

  // ---------------------------------------------------------------- lens
  const composer = new EffectComposer(renderer, new THREE.WebGLRenderTarget(FRAME.w * ratio, FRAME.h * ratio, { type: THREE.HalfFloatType, samples: 4 }));
  composer.addPass(new RenderPass(scene, camera));
  const focus = new ShaderPass(FocusShader);
  composer.addPass(focus);
  const bloom = new UnrealBloomPass(new THREE.Vector2(FRAME.w, FRAME.h), 0.9, 0.6, 0.8);
  composer.addPass(bloom);
  // The bloom works at the frame's size whatever the pixel density, so a 4K
  // render glows exactly like the 1080p preview.
  bloom.setSize(FRAME.w, FRAME.h);
  composer.addPass(new OutputPass());
  const dither = new ShaderPass(DitherShader);
  composer.addPass(dither);

  // What the scenes control.
  const fresh = () => ({
    exposure: 1, bloom: 0.85, env: 1, rim: 1, gloss: 0.3, face: 0,
    // Trackpad surface.
    zones: { left: 0.4, right: 0.4 }, labels: { left: "BRIGHTNESS", right: "VOLUME", o: 0 }, tracks: 1,
    contacts: [], corners: { tl: 0, tr: 0, bl: 0, br: 0 }, ruler: null, palm: null, pulse: 0,
    // Screen.
    display: 1, light: 1, wall: [], tint: [255, 255, 255], bars: [], spots: [],
  });
  let state = fresh();

  function drawSurface() {
    const s = state;
    sg.clearRect(0, 0, TEX.w, TEX.h);
    // The trackpad's glass mirrors the screen above it: its colours, upside down and soft.
    if (s.display > 0.01 && s.gloss > 0.002) {
      sg.save();
      sg.globalAlpha = s.gloss * s.display;
      sg.filter = "blur(30px)";
      sg.translate(0, TEX.h);
      sg.scale(1, -1);
      sg.drawImage(calm, -TEX.w * 0.12, -TEX.h * 0.25, TEX.w * 1.24, TEX.h * 1.5);
      sg.restore();
    }
    // Seen from straight above the glass reflects nothing, so the logo shots give it a sheen of its own.
    if (s.face > 0.002) {
      const sheen = sg.createLinearGradient(0, 0, 0, TEX.h);
      sheen.addColorStop(0, `rgba(255,255,255,${0.085 * s.face})`);
      sheen.addColorStop(0.6, `rgba(255,255,255,${0.03 * s.face})`);
      sheen.addColorStop(1, `rgba(255,255,255,${0.012 * s.face})`);
      sg.fillStyle = sheen;
      sg.fillRect(0, 0, TEX.w, TEX.h);
    }
    const zoneW = 150;
    for (const side of ["left", "right"]) {
      const x = side === "left" ? ZONES.left : ZONES.right;
      const a = s.zones[side];
      // The edge zone and its quiet track.
      sg.fillStyle = `rgba(255,255,255,${0.012 + a * 0.03})`;
      sg.beginPath();
      sg.roundRect(x - zoneW / 2, ZONES.top - 40, zoneW, ZONES.bottom - ZONES.top + 80, 60);
      sg.fill();
      sg.fillStyle = `rgba(255,255,255,${(0.03 + a * 0.05) * s.tracks})`;
      sg.beginPath();
      sg.roundRect(x - 17, ZONES.top, 34, ZONES.bottom - ZONES.top, 17);
      sg.fill();
      // Label along the inner side of the zone.
      const label = s.labels[side];
      const labels = Array.isArray(label) ? label : [[label, 1]];
      for (const [text, o] of labels) {
        if (!text || o * s.labels.o <= 0.002) continue;
        sg.save();
        sg.translate(side === "left" ? x + 128 : x - 128, TEX.h / 2);
        sg.rotate(side === "left" ? -Math.PI / 2 : Math.PI / 2);
        sg.font = "600 38px -apple-system, 'SF Pro Text', sans-serif";
        sg.letterSpacing = "13px";
        sg.textAlign = "center";
        sg.textBaseline = "middle";
        sg.fillStyle = `rgba(235,240,255,${s.labels.o * o * (0.2 + a * 0.5)})`;
        sg.fillText(text, 0, 0);
        sg.restore();
      }
    }
    // A corner that was tapped glows from the corner inward: no rings.
    const cornerAt = { tl: [0, 0], tr: [TEX.w, 0], bl: [0, TEX.h], br: [TEX.w, TEX.h] };
    for (const [id, o] of Object.entries(s.corners)) {
      if (o <= 0.002) continue;
      const [cx, cy] = cornerAt[id];
      const glow = sg.createRadialGradient(cx, cy, 0, cx, cy, 520);
      glow.addColorStop(0, `rgba(226,234,255,${0.5 * o})`);
      glow.addColorStop(0.4, `rgba(200,214,255,${0.14 * o})`);
      glow.addColorStop(1, "rgba(200,214,255,0)");
      sg.fillStyle = glow;
      sg.fillRect(cx - 520, cy - 520, 1040, 1040);
    }
    // The ruler: a mark for every step along an edge, lit where the level has passed.
    if (s.ruler && s.ruler.o > 0.002) {
      const r = s.ruler, x = r.side === "left" ? ZONES.left + 62 : ZONES.right - 62, dir = r.side === "left" ? 1 : -1;
      for (let v = Math.ceil(r.from); v <= r.to; v++) {
        const y = r.y(v);
        if (y < ZONES.top - 30 || y > ZONES.bottom + 30) continue;
        const major = v % 10 === 0, mid = v % 5 === 0, notch = v === r.notch;
        const lit = clamp(r.level - v + 1);
        const flash = Math.exp(-Math.max(0, r.level - v) * 0.9) * lit;
        const w = notch ? 150 : major ? 96 : mid ? 66 : 44;
        sg.fillStyle = `rgba(236,242,255,${r.o * clamp(0.13 + lit * 0.3 + flash * 0.57)})`;
        sg.beginPath();
        sg.roundRect(dir > 0 ? x : x - w, y - (notch ? 4 : 2.5), w, notch ? 8 : 5, 3);
        sg.fill();
      }
    }
    // A resting palm: a big soft patch that lights nothing.
    if (s.palm && s.palm.o > 0.002) {
      const p = s.palm;
      sg.save();
      sg.translate(p.x, p.y);
      sg.scale(p.rx / 100, p.ry / 100);
      const g = sg.createRadialGradient(0, 0, 0, 0, 0, 100);
      g.addColorStop(0, `rgba(200,206,222,${0.2 * p.o})`);
      g.addColorStop(0.7, `rgba(200,206,222,${0.1 * p.o})`);
      g.addColorStop(1, "rgba(200,206,222,0)");
      sg.fillStyle = g;
      sg.fillRect(-100, -100, 200, 200);
      sg.restore();
    }
    for (const c of s.contacts) {
      if (c.o <= 0.001) continue;
      const tint = c.color || [236, 242, 255];
      const size = c.size ?? 1;
      if (c.from && Math.hypot(c.from.x - c.x, c.from.y - c.y) > 2) {
        const gradient = sg.createLinearGradient(c.from.x, c.from.y, c.x, c.y);
        gradient.addColorStop(0, rgba(tint, 0));
        gradient.addColorStop(1, rgba(tint, 0.88 * c.o));
        sg.strokeStyle = gradient;
        sg.lineWidth = 34;
        sg.lineCap = "round";
        sg.beginPath();
        sg.moveTo(c.from.x, c.from.y);
        sg.lineTo(c.x, c.y);
        sg.stroke();
      }
      const glow = sg.createRadialGradient(c.x, c.y, 0, c.x, c.y, 260 * size);
      glow.addColorStop(0, rgba(tint, 0.42 * c.o));
      glow.addColorStop(0.3, rgba(tint, 0.14 * c.o));
      glow.addColorStop(1, rgba(tint, 0));
      sg.fillStyle = glow;
      sg.fillRect(c.x - 300 * size, c.y - 300 * size, 600 * size, 600 * size);
      sg.fillStyle = `rgba(255,255,255,${c.o})`;
      sg.beginPath();
      sg.arc(c.x, c.y, 31 * size, 0, Math.PI * 2);
      sg.fill();
    }
    // A haptic pulse: the whole surface breathes once.
    if (s.pulse > 0.002) {
      sg.fillStyle = `rgba(226,234,255,${0.055 * s.pulse})`;
      sg.fillRect(0, 0, TEX.w, TEX.h);
    }
    surfaceTexture.needsUpdate = true;
  }

  /** The screen's light: wallpaper blobs, then Kinara's lights on top. */
  function drawShine() {
    const s = state, W = shine.width, H = shine.height, k = W / SCREEN.w;
    lg.globalCompositeOperation = "source-over";
    lg.fillStyle = "#000";
    lg.fillRect(0, 0, W, H);
    lg.globalCompositeOperation = "lighter";
    for (const b of s.wall) {
      lg.save();
      lg.translate(b.x * W, b.y * H);
      lg.scale(b.rx * W, b.ry * H);
      const g = lg.createRadialGradient(0, 0, 0, 0, 0, 1);
      g.addColorStop(0, rgba(b.color, b.a * s.light));
      g.addColorStop(0.7, rgba(b.color, 0));
      lg.fillStyle = g;
      lg.fillRect(-1, -1, 2, 2);
      lg.restore();
    }
    // The trackpad's glass mirrors the picture so far, and Kinara's lights at a third.
    cg.globalCompositeOperation = "copy";
    cg.globalAlpha = 1;
    cg.drawImage(shine, 0, 0);
    // Edge light: a bar by the edge. Ambient light: a spot on the border.
    for (const bar of s.bars) {
      const vertical = bar.side === "left" || bar.side === "right";
      const cx = bar.side === "left" ? 3 : bar.side === "right" ? W - 3 : bar.at * k;
      const cy = vertical ? bar.at * k : bar.side === "top" ? 3 : H - 3;
      const len = bar.length * k;
      lg.save();
      lg.translate(cx, cy);
      lg.scale(vertical ? 0.16 : 1, vertical ? 1 : 0.16);
      const g = lg.createRadialGradient(0, 0, 0, 0, 0, len * 0.6);
      g.addColorStop(0, rgba(bar.color, bar.o));
      g.addColorStop(0.55, rgba(bar.color, bar.o * 0.5));
      g.addColorStop(1, rgba(bar.color, 0));
      lg.fillStyle = g;
      lg.fillRect(-len, -len, len * 2, len * 2);
      lg.restore();
    }
    for (const spot of s.spots) {
      const g = lg.createRadialGradient(spot.x * k, spot.y * k, 0, spot.x * k, spot.y * k, spot.r * k);
      g.addColorStop(0, rgba(spot.color, spot.o));
      g.addColorStop(0.4, rgba(spot.color, spot.o * 0.4));
      g.addColorStop(1, rgba(spot.color, 0));
      lg.fillStyle = g;
      lg.fillRect(0, 0, W, H);
    }
    cg.globalCompositeOperation = "lighter";
    cg.globalAlpha = 0.3;
    cg.drawImage(shine, 0, 0);
    shineTexture.needsUpdate = true;
  }

  const css = new THREE.Matrix4(), model = new THREE.Matrix4(), viewport = new THREE.Matrix4();
  viewport.set(FRAME.w / 2, 0, 0, FRAME.w / 2, 0, -FRAME.h / 2, 0, FRAME.h / 2, 0, 0, 1, 0, 0, 0, 0, 1);
  const point = new THREE.Vector3();
  const domW = SCREEN.w + SCREEN.bezel * 2, domH = SCREEN.h + SCREEN.bezel * 2;
  /** Where a world point lands in the frame, in pixels. */
  function project(p) {
    point.set(p[0], p[1], p[2]).project(camera);
    return [(point.x * 0.5 + 0.5) * FRAME.w, (0.5 - point.y * 0.5) * FRAME.h];
  }

  /** Points the camera for a shot: { q: target, d: distance, el, az, fov, roll, focus: [x,y,z], dof }. */
  function aim(shot) {
    const e = THREE.MathUtils.degToRad(shot.el), a = THREE.MathUtils.degToRad(shot.az);
    const [tx, ty, tz] = shot.q;
    camera.fov = shot.fov;
    camera.up.set(0, 1, 0);
    camera.position.set(tx + shot.d * Math.cos(e) * Math.sin(a), ty + shot.d * Math.sin(e), tz + shot.d * Math.cos(e) * Math.cos(a) + 0.0001);
    camera.lookAt(tx, ty, tz);
    if (shot.roll) camera.rotateZ(THREE.MathUtils.degToRad(shot.roll));
    camera.updateProjectionMatrix();
    camera.updateMatrixWorld(true);
    display.updateMatrixWorld(true);
  }

  /** Draws the frame for a shot. */
  function render(shot) {
    const s = state;
    aim(shot);
    renderer.toneMappingExposure = s.exposure;
    bloom.strength = s.bloom;
    scene.environmentIntensity = s.env;
    key.intensity = 0.35 * s.env;
    rim.intensity = 0.9 * s.env * s.rim;
    // The screen and its lamps.
    display.visible = s.display > 0.01;
    const lum = s.wall.reduce((sum, b) => sum + b.a, 0) / Math.max(1, s.wall.length);
    let r = 0, g = 0, b = 0, w = 0;
    for (const blob of s.wall) { r += blob.color[0] * blob.a; g += blob.color[1] * blob.a; b += blob.color[2] * blob.a; w += blob.a; }
    if (w > 0) lamp.color.setRGB((r / w / 255) * (s.tint[0] / 255), (g / w / 255) * (s.tint[1] / 255), (b / w / 255) * (s.tint[2] / 255), THREE.SRGBColorSpace);
    lamp.intensity = display.visible ? 0.55 * s.light * (0.35 + lum) * s.display : 0;
    shineMaterial.color.setRGB(1.5 * (s.tint[0] / 255), 1.5 * (s.tint[1] / 255), 1.5 * (s.tint[2] / 255));
    // Kinara's light, as a lamp on the screen's face where the light is.
    const glowing = [...s.bars.map((bar) => ({ x: bar.side === "left" ? 0 : bar.side === "right" ? SCREEN.w : bar.at, y: bar.side === "top" ? 0 : bar.side === "bottom" ? SCREEN.h : bar.at, o: bar.o, color: bar.color })), ...s.spots];
    const lit = glowing.reduce((best, x) => (x.o > (best?.o ?? 0) ? x : best), null);
    if (lit && display.visible) {
      neon.position.set((lit.x - SCREEN.w / 2) * UNIT, -(lit.y - SCREEN.h / 2) * UNIT, 0.08);
      neon.color.setRGB(lit.color[0] / 255, lit.color[1] / 255, lit.color[2] / 255, THREE.SRGBColorSpace);
      neon.intensity = 70 * lit.o;
    } else neon.intensity = 0;
    // Focus.
    focus.uniforms.amount.value = (shot.dof ?? 0) * 0.011;
    focus.uniforms.focus.value = shot.focus ? 1 - project(shot.focus)[1] / FRAME.h : 0.5;
    focus.uniforms.range.value = shot.range ?? 0.42;
    drawShine();
    drawSurface();
    dither.uniforms.seed.value = (shot.frame ?? 0) % 251;
    composer.render();
  }

  /** The CSS transform that lays the screen's DOM (bezel and all) onto the slab's face. */
  function screenTransform(zoom = 1) {
    const k = UNIT / zoom;
    // The zoomed element is `zoom` times larger; its middle is still the screen's middle.
    model.set(k, 0, 0, (-domW / 2) * UNIT, 0, -k, 0, (domH / 2) * UNIT, 0, 0, 1, 0.04, 0, 0, 0, 1);
    css.copy(viewport).multiply(camera.projectionMatrix).multiply(camera.matrixWorldInverse).multiply(display.matrixWorld).multiply(model);
    return `matrix3d(${css.elements.map((v) => +v.toFixed(8)).join(",")})`;
  }
  /** How many frame pixels one screen point covers at the middle of the screen. */
  function screenScale() {
    const a = project(screenPoint(SCREEN.w / 2 - 50, SCREEN.h / 2)), b = project(screenPoint(SCREEN.w / 2 + 50, SCREEN.h / 2));
    return Math.hypot(b[0] - a[0], b[1] - a[1]) / 100;
  }

  return {
    canvas, aim, render, project, screenTransform, screenScale,
    get state() { return state; },
    reset() { state = fresh(); return state; },
    floor: floor.material.uniforms,
  };
}
