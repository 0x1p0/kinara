// The one WebGL set piece: a graphite trackpad in a studio, with Kinara's
// luminous swipe drawn onto its surface. Scenes describe what should be on
// screen through gl.pad; render() draws it for the current frame.
import * as THREE from "three";
import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
import { OutputPass } from "three/addons/postprocessing/OutputPass.js";
import { lerp, ease, clamp } from "./timeline.js";

export const PAD = { w: 16, d: 10, r: 1.15, depth: 0.3, bevel: 0.07 };
const TEX = { w: 2048, h: 1280 };
// Edge zones in surface-canvas pixels.
export const ZONES = { left: 118, right: TEX.w - 118, top: 150, bottom: TEX.h - 150 };

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
  strip(1.4, 20, 1.6, -24, 8, 0, 0, Math.PI / 2); // tall strip to the left
  strip(1.4, 20, 1.2, 24, 8, 4, 0, -Math.PI / 2); // and to the right
  strip(18, 0.8, 0.5, 0, 14, 10, Math.PI / 2.2, 0); // faint front fill
  return room;
}

export async function createGL(canvas) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true, powerPreference: "high-performance" });
  renderer.setPixelRatio(1);
  renderer.setSize(1920, 1080, false);
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.outputColorSpace = THREE.SRGBColorSpace;

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x060607);
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(studio(), 0.02).texture;
  scene.environmentIntensity = 1;

  const camera = new THREE.PerspectiveCamera(28, 1920 / 1080, 0.1, 400);

  // Floor: a soft pool of light under the trackpad, fading to black.
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(140, 140), new THREE.MeshBasicMaterial({
    map: gradientTexture(1024, [[0, "#1c1d21"], [0.18, "#141518"], [0.45, "#0a0a0b"], [1, "#060607"]]), toneMapped: false,
  }));
  floor.rotation.x = -Math.PI / 2;
  floor.position.y = -0.12;
  scene.add(floor);
  const shadow = new THREE.Mesh(new THREE.PlaneGeometry(26, 18), new THREE.MeshBasicMaterial({
    map: gradientTexture(512, [[0, "rgba(0,0,0,0.85)"], [0.55, "rgba(0,0,0,0.5)"], [1, "rgba(0,0,0,0)"]]), transparent: true, depthWrite: false, toneMapped: false,
  }));
  shadow.rotation.x = -Math.PI / 2;
  shadow.position.set(0, -0.1, 0.5);
  scene.add(shadow);

  // The trackpad body: extruded rounded rectangle with a soft bevel.
  const shape = roundedRect(PAD.w, PAD.d, PAD.r);
  const bodyGeometry = new THREE.ExtrudeGeometry(shape, { depth: PAD.depth, bevelEnabled: true, bevelThickness: PAD.bevel, bevelSize: PAD.bevel, bevelSegments: 8, curveSegments: 64 });
  bodyGeometry.rotateX(-Math.PI / 2);
  const body = new THREE.Mesh(bodyGeometry, new THREE.MeshPhysicalMaterial({
    color: 0x0f1012, metalness: 0.7, roughness: 0.42, clearcoat: 0.7, clearcoatRoughness: 0.2, envMapIntensity: 1,
  }));
  scene.add(body);
  const top = PAD.depth + PAD.bevel;

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
  const overlay = new THREE.Mesh(overlayGeometry, new THREE.MeshBasicMaterial({ map: surfaceTexture, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false }));
  overlay.position.y = top + 0.004;
  scene.add(overlay);

  const key = new THREE.DirectionalLight(0xffffff, 0.35);
  key.position.set(-8, 14, 10);
  scene.add(key);
  const rim = new THREE.DirectionalLight(0xdfe7ff, 0.9);
  rim.position.set(6, 4, -14);
  scene.add(rim);

  const composer = new EffectComposer(renderer, new THREE.WebGLRenderTarget(1920, 1080, { type: THREE.HalfFloatType, samples: 4 }));
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(new THREE.Vector2(1920, 1080), 0.9, 0.6, 0.8);
  composer.addPass(bloom);
  composer.addPass(new OutputPass());

  // What the scenes control.
  const pad = {
    elevation: 90, azimuth: 0, distance: 19, target: [0, 0, 0], fov: 28,
    exposure: 1, bloom: 0.9,
    zones: { left: 0.5, right: 0.5 }, labels: { left: "BRIGHTNESS", right: "VOLUME", o: 0 },
    contacts: [], ripples: [], tracks: 1,
  };

  function drawSurface() {
    sg.clearRect(0, 0, TEX.w, TEX.h);
    const zoneW = 150;
    for (const side of ["left", "right"]) {
      const x = side === "left" ? ZONES.left : ZONES.right;
      const a = pad.zones[side];
      // The edge zone and its quiet track.
      sg.fillStyle = `rgba(255,255,255,${0.018 + a * 0.03})`;
      sg.beginPath();
      sg.roundRect(x - zoneW / 2, ZONES.top - 40, zoneW, ZONES.bottom - ZONES.top + 80, 60);
      sg.fill();
      sg.fillStyle = `rgba(255,255,255,${(0.035 + a * 0.05) * pad.tracks})`;
      sg.beginPath();
      sg.roundRect(x - 17, ZONES.top, 34, ZONES.bottom - ZONES.top, 17);
      sg.fill();
      // Label along the inner side of the zone.
      sg.save();
      sg.translate(side === "left" ? x + 128 : x - 128, TEX.h / 2);
      sg.rotate(side === "left" ? -Math.PI / 2 : Math.PI / 2);
      sg.font = "600 34px -apple-system, 'SF Pro Text', sans-serif";
      sg.letterSpacing = "12px";
      sg.textAlign = "center";
      sg.textBaseline = "middle";
      sg.fillStyle = `rgba(235,240,255,${pad.labels.o * (0.16 + a * 0.4)})`;
      sg.fillText(pad.labels[side], 0, 0);
      sg.restore();
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
        gradient.addColorStop(0, "rgba(150,170,220,0)");
        gradient.addColorStop(1, `rgba(236,242,255,${0.85 * c.o})`);
        sg.fillStyle = gradient;
        sg.beginPath();
        const y0 = Math.min(c.fromY, c.y), y1 = Math.max(c.fromY, c.y);
        sg.roundRect(c.x - 17, y0 - 17, 34, y1 - y0 + 34, 17);
        sg.fill();
      }
      const glow = sg.createRadialGradient(c.x, c.y, 0, c.x, c.y, 260 * (c.size ?? 1));
      glow.addColorStop(0, `rgba(225,233,255,${0.42 * c.o})`);
      glow.addColorStop(0.3, `rgba(200,214,255,${0.14 * c.o})`);
      glow.addColorStop(1, "rgba(200,214,255,0)");
      sg.fillStyle = glow;
      sg.fillRect(c.x - 300, c.y - 300, 600, 600);
      sg.fillStyle = `rgba(255,255,255,${c.o})`;
      sg.beginPath();
      sg.arc(c.x, c.y, 31 * (c.size ?? 1), 0, Math.PI * 2);
      sg.fill();
    }
    surfaceTexture.needsUpdate = true;
  }

  function render() {
    const e = THREE.MathUtils.degToRad(pad.elevation), a = THREE.MathUtils.degToRad(pad.azimuth);
    const [tx, ty, tz] = pad.target;
    camera.fov = pad.fov;
    camera.updateProjectionMatrix();
    camera.position.set(tx + pad.distance * Math.cos(e) * Math.sin(a), ty + pad.distance * Math.sin(e), tz + pad.distance * Math.cos(e) * Math.cos(a) + 0.0001);
    camera.lookAt(tx, ty, tz);
    renderer.toneMappingExposure = pad.exposure;
    bloom.strength = pad.bloom;
    drawSurface();
    composer.render();
  }

  return { canvas, render, pad, TEX };
}

/** Surface-canvas coordinates for a point on an edge (side) at level p (0 bottom … 1 top). */
export function edgePoint(side, p) {
  return { x: side === "left" ? ZONES.left : ZONES.right, y: lerp(ZONES.bottom - 40, ZONES.top + 40, clamp(p)) };
}
export const easeCam = ease.inOut;
