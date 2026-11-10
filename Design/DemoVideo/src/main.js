// Boots the film and exposes window.__seek(t): every frame is a pure function
// of time, so headless capture and the scrub preview always agree.
import { FILM, SCENES, prog, ease, clamp } from "./timeline.js";
import { createWorld } from "./world.js";
import { createDesktop } from "./desktop.js";
import { shotAt, SHOTS, TRACK } from "./camera.js";

const params = new URLSearchParams(location.search);
const only = params.get("scenes");
const names = ["open", "title", "corners", "clip", "light", "mixer", "apps", "feel", "more", "end"].filter((n) => !only || only.split(",").includes(n));
const modules = (await Promise.all(names.map((n) => import(`./scenes/${n}.js`)))).map((m) => m.default);

const stage = document.getElementById("stage");
const dom = document.getElementById("dom");
const shade = document.getElementById("shade");
const world = await createWorld(document.getElementById("gl"));
const desk = createDesktop(document.getElementById("display"));
const ctx = { world, desk, stage };

const timing = Object.fromEntries(SCENES.map((s) => [s.id, s]));
for (const m of modules) {
  m.root = document.createElement("div");
  m.root.className = "scene";
  m.root.dataset.scene = m.id;
  dom.append(m.root);
  // What the scene puts on the screen lives in the screen's own DOM.
  m.screen = document.createElement("div");
  m.screen.className = "abs";
  m.screen.style.inset = "0";
  desk.content.append(m.screen);
  m.scene = timing[m.id];
  // A scene may draw a little before it starts and after it ends.
  m.from = m.scene.start - (m.pre ?? 0);
  m.to = m.scene.end + (m.post ?? 0);
  m.mount(m.root, ctx, m.screen);
}

// The screen's zoom (see desktop.js): what each continuous run of camera needs
// at its closest moment. A page never changes its zoom: doing so makes Chrome
// redraw the whole screen at a new size while it still holds the old drawing,
// and for a few frames parts of the screen go missing. So the renderer asks
// for these runs (window.__runs) and opens a fresh page, at ?zoom=N, for each.
const runs = [];
{
  let run = null;
  TRACK.forEach((entry, i) => {
    const end = i + 1 < TRACK.length ? TRACK[i + 1].t : FILM.duration;
    if (!entry.dur || !run) runs.push((run = { from: entry.t, scale: 0 }));
    for (const t of [entry.t + (entry.dur || 0), end - 1 / FILM.fps]) {
      world.aim(shotAt(t));
      run.scale = Math.max(run.scale, world.screenScale());
    }
  });
  // Up to three times the layout at 1080p, twice at 4K: beyond that the screen's layers outgrow Chrome's tile memory.
  const most = (window.devicePixelRatio || 1) > 1 ? 2 : 3;
  for (const r of runs) r.zoom = clamp(Math.ceil(r.scale - 0.25), 1, most);
}
window.__runs = runs;
desk.setZoom(Number(params.get("zoom")) || 1);

const fixedShot = params.get("shot");
function seek(t) {
  t = clamp(t, 0, FILM.duration);
  // Scenes describe the frame: the trackpad's surface (ctx.pad), the screen
  // (ctx.d) and anything of their own. Then the screen and the world draw it.
  ctx.pad = world.reset();
  ctx.d = desk.reset();
  ctx.gl = true;
  ctx.shot = fixedShot ? { range: 0.42, roll: 0, ...SHOTS[fixedShot] } : shotAt(t);
  // Aimed before the scenes run, so they can ask where things are in the frame.
  ctx.shot.frame = Math.round(t * FILM.fps);
  world.aim(ctx.shot);
  for (const m of modules) {
    const active = t >= m.from && t < m.to;
    if (active !== m.active) {
      m.root.style.display = active ? "" : "none";
      m.screen.style.display = active ? "" : "none";
      m.active = active;
    }
    if (active) m.update(t, ctx);
  }
  world.canvas.style.visibility = ctx.gl ? "visible" : "hidden";
  if (!ctx.gl) ctx.d.o = 0;
  desk.apply(t, world);
  if (ctx.gl) world.render(ctx.shot);
  desk.place(world);
  // Open from black and close to black.
  const open = 1 - ease.out(prog(t, 0, 1.4));
  const close = ease.inOut(prog(t, FILM.duration - 1.5, FILM.duration - 0.05));
  shade.style.opacity = String(Math.max(open, close));
}

window.__seek = seek;
await document.fonts.ready;
seek(0);
window.__ready = true;

// Scrub preview: http://127.0.0.1:4173/?scrub
if (params.has("scrub")) {
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
  show(Number(params.get("t") || 0));
}
