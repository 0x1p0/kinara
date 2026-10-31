// Boots the film and exposes window.__seek(t): every frame is a pure function
// of time, so headless capture and the scrub preview always agree.
import { FILM, SCENES, seeded, prog, ease, clamp } from "./timeline.js";
import { createGL } from "./gl.js";
import intro from "./scenes/intro.js";
import logo from "./scenes/logo.js";
import slide from "./scenes/slide.js";
import feel from "./scenes/feel.js";
import actions from "./scenes/actions.js";
import taps from "./scenes/taps.js";
import clipboard from "./scenes/clipboard.js";
import aware from "./scenes/aware.js";
import sound from "./scenes/sound.js";
import details from "./scenes/details.js";
import light from "./scenes/light.js";
import end from "./scenes/end.js";

const stage = document.getElementById("stage");
const dom = document.getElementById("dom");
const bg = document.getElementById("bg");
const shade = document.getElementById("shade");
const grainCanvas = document.getElementById("grain");
const grain = grainCanvas.getContext("2d");
const gl = await createGL(document.getElementById("gl"));
const ctx = { gl, stage, tint: document.getElementById("tint"), bg };

const modules = [intro, logo, slide, feel, actions, taps, clipboard, aware, sound, details, light, end];
const timing = Object.fromEntries(SCENES.map((s) => [s.id, s]));
for (const m of modules) {
  m.root = document.createElement("div");
  m.root.className = "scene";
  m.root.dataset.scene = m.id;
  dom.append(m.root);
  m.scene = timing[m.id];
  // Each scene may draw a little before it starts and after it ends, so
  // transitions can overlap.
  m.from = m.scene.start - (m.pre ?? 0.6);
  m.to = m.scene.end + (m.post ?? 0.6);
  m.mount(m.root, ctx);
}

// Grain: a few pre-baked noise tiles, picked deterministically per frame.
const tiles = Array.from({ length: 8 }, (_, k) => {
  const random = seeded(101 + k);
  const image = grain.createImageData(960, 540);
  for (let i = 0; i < image.data.length; i += 4) {
    const v = 128 + (random() + random() + random() - 1.5) * 120;
    image.data[i] = image.data[i + 1] = image.data[i + 2] = v;
    image.data[i + 3] = 255;
  }
  return image;
});

function seek(t) {
  t = clamp(t, 0, FILM.duration);
  let glUsed = false;
  for (const m of modules) {
    const active = t >= m.from && t <= m.to;
    if (active !== m.active) {
      m.root.style.display = active ? "" : "none";
      m.active = active;
    }
    if (active) {
      m.update(t, ctx);
      if (m.usesGL && m.usesGL(t)) glUsed = true;
    }
  }
  gl.canvas.style.visibility = glUsed ? "visible" : "hidden";
  if (glUsed) gl.render(t);
  const frame = Math.round(t * FILM.fps);
  grain.putImageData(tiles[frame % tiles.length], 0, 0);
  // Open from black and close to black.
  const open = 1 - ease.out(prog(t, 0, 0.9));
  const close = ease.inOut(prog(t, FILM.duration - 1.4, FILM.duration - 0.05));
  shade.style.opacity = String(Math.max(open, close));
}

window.__seek = seek;
await document.fonts.ready;
seek(0);
window.__ready = true;

// Scrub preview: http://127.0.0.1:4173/?scrub
if (location.search.includes("scrub")) {
  document.body.classList.add("scrub");
  const fit = () => (stage.style.transform = `scale(${Math.min(innerWidth / 1920, (innerHeight - 60) / 1080)})`);
  fit();
  addEventListener("resize", fit);
  const bar = document.createElement("div");
  bar.id = "scrubber";
  bar.innerHTML = `<button id="play">Play</button><input type="range" min="0" max="${FILM.duration}" step="0.0166" value="0"><span id="time">0.00</span>`;
  document.body.append(bar);
  const range = bar.querySelector("input"), label = bar.querySelector("#time"), play = bar.querySelector("#play");
  let playing = false, origin = 0, offset = 0;
  const show = (t) => { seek(t); range.value = t; label.textContent = t.toFixed(2); };
  range.addEventListener("input", () => { playing = false; show(Number(range.value)); });
  play.addEventListener("click", () => { playing = !playing; origin = performance.now(); offset = Number(range.value); tick(); });
  const tick = () => { if (!playing) return; const t = offset + (performance.now() - origin) / 1000; show(t % FILM.duration); requestAnimationFrame(tick); };
  const start = Number(new URLSearchParams(location.search).get("t") || 0);
  show(start);
}
