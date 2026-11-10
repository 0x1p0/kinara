// Renders the Kinara demo film frame by frame in headless Chrome and encodes it
// with ffmpeg. Every frame is a pure function of time (window.__seek), so the
// output is identical on every run and workers can render ranges in parallel.
//
//   node render.mjs                 full film → build/DemoVideo/kinara-film.mp4
//   node render.mjs --stills 3,12.4 PNG stills → build/DemoVideo/stills/
//   node render.mjs --from 40 --to 60   render only part of the film
//   node render.mjs --serve         open http://localhost:4173/?scrub to scrub
import { createServer } from "node:http";
import { readFile, mkdir, writeFile, rm } from "node:fs/promises";
import { spawn } from "node:child_process";
import { extname, join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { cpus } from "node:os";
import puppeteer from "puppeteer-core";
import { FILM } from "./src/timeline.js";
import { renderSoundtrack } from "./soundtrack.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const output = resolve(here, "../../build/DemoVideo");
const chrome = process.env.CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index < 0 ? fallback : args[index + 1];
};
const fps = Number(option("fps", FILM.fps));
const width = Number(option("width", FILM.width));
const height = Number(option("height", FILM.height));
const scale = Number(option("scale", 1));
// Extra page options, e.g. --query "scenes=open,title" to load only some scenes.
const query = option("query", "");

const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".png": "image/png", ".json": "application/json", ".wav": "audio/wav" };
function serve(port = 0) {
  const server = createServer(async (request, response) => {
    const path = decodeURIComponent(new URL(request.url, "http://x").pathname);
    const file = join(here, path === "/" ? "index.html" : path);
    if (!file.startsWith(here)) return response.writeHead(403).end();
    try {
      const body = await readFile(file);
      response.writeHead(200, { "content-type": types[extname(file)] || "application/octet-stream", "cache-control": "no-store" }).end(body);
    } catch {
      response.writeHead(404).end();
    }
  });
  return new Promise((done) => server.listen(port, "127.0.0.1", () => done(server)));
}

async function openPage(browser, origin, zoom = 1) {
  const page = await browser.newPage();
  await page.setViewport({ width, height, deviceScaleFactor: scale });
  page.on("pageerror", (error) => console.error("page error:", error.message));
  page.on("console", (message) => { if (message.type() === "error") console.error("console:", message.text()); });
  await page.goto(`${origin}/?render&zoom=${zoom}${query ? `&${query}` : ""}`, { waitUntil: "load" });
  await page.waitForFunction("window.__ready === true", { timeout: 60000 });
  return page;
}

/**
 * The film's screen is laid out larger for close shots (its zoom). A page keeps
 * one zoom for life, so a camera is a page that is replaced whenever the next
 * frame needs another zoom.
 */
async function camera(browser, origin) {
  let page = await openPage(browser, origin);
  const runs = await page.evaluate("window.__runs");
  const zoomAt = (t) => runs.reduce((z, r) => (r.from <= t + 1e-6 ? r.zoom : z), runs[0].zoom);
  let zoom = 1;
  return {
    async shoot(t) {
      const wanted = zoomAt(t);
      if (wanted !== zoom) {
        await page.close();
        page = await openPage(browser, origin, wanted);
        zoom = wanted;
      }
      return frame(page, t);
    },
  };
}

function launch() {
  return puppeteer.launch({
    executablePath: chrome,
    headless: true,
    // A stalled frame should fail fast so the worker can recover.
    protocolTimeout: 45000,
    // The compositor must finish every stage, rasterising included, before it
    // draws: otherwise a frame can be captured with part of a layer not painted
    // yet, which shows up in the film as a one-frame flicker.
    args: ["--hide-scrollbars", "--force-color-profile=srgb", "--disable-background-timer-throttling",
      "--disable-renderer-backgrounding", "--enable-gpu-rasterization", "--ignore-gpu-blocklist", "--use-angle=metal",
      "--run-all-compositor-stages-before-draw", "--disable-checker-imaging", "--disable-threaded-animation", "--disable-threaded-scrolling",
      // The screen's layers are large when it is laid out for a close shot. With
      // Chrome's usual budget some of them are dropped for a few frames at a time.
      "--force-gpu-mem-available-mb=8192"],
  });
}

async function frame(page, t, settle = 2) {
  // Seek, then let the page produce the frame before it is captured.
  await page.evaluate((time, frames) => {
    window.__seek(time);
    return new Promise((done) => { const next = (n) => (n <= 0 ? done() : requestAnimationFrame(() => next(n - 1))); next(frames); });
  }, t, settle);
  return page.screenshot({ type: "png", optimizeForSpeed: true, captureBeyondViewport: false });
}

function encoder(file) {
  const ffmpeg = spawn("ffmpeg", ["-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", String(fps), "-c:v", "png", "-i", "-",
    "-c:v", "libx264", "-preset", "slow", "-crf", "13", "-pix_fmt", "yuv420p", "-profile:v", "high", "-g", String(fps * 2),
    "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", file], { stdio: ["pipe", "inherit", "inherit"] });
  const closed = new Promise((done, fail) => ffmpeg.on("close", (code) => (code === 0 ? done() : fail(new Error(`ffmpeg exited ${code}`)))));
  return { write: (buffer) => new Promise((done) => (ffmpeg.stdin.write(buffer) ? done() : ffmpeg.stdin.once("drain", done))), end: () => (ffmpeg.stdin.end(), closed) };
}

function run(command, commandArgs) {
  return new Promise((done, fail) => {
    const child = spawn(command, commandArgs, { stdio: ["ignore", "inherit", "inherit"] });
    child.on("close", (code) => (code === 0 ? done() : fail(new Error(`${command} exited ${code}`))));
  });
}

async function stills(times) {
  const server = await serve();
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await launch();
  const cam = await camera(browser, origin);
  await mkdir(join(output, "stills"), { recursive: true });
  for (const t of times) {
    const started = performance.now();
    const png = await cam.shoot(t);
    const file = join(output, "stills", `t${t.toFixed(2).padStart(6, "0")}.png`);
    await writeFile(file, png);
    console.log(`${file}  (${Math.round(performance.now() - started)} ms)`);
  }
  await browser.close();
  server.close();
}

async function film() {
  const from = Number(option("from", 0));
  const to = Math.min(Number(option("to", FILM.duration)), FILM.duration);
  const first = Math.round(from * fps);
  const last = Math.round(to * fps);
  const total = last - first;
  const workers = Math.max(1, Math.min(Number(option("workers", Math.min(6, cpus().length - 2))), total));
  await mkdir(join(output, "parts"), { recursive: true });

  const audio = join(output, "soundtrack.wav");
  console.log("Composing soundtrack…");
  await writeFile(audio, renderSoundtrack({ from, to }));

  const server = await serve();
  const origin = `http://127.0.0.1:${server.address().port}`;
  const size = Math.ceil(total / workers);
  let done = 0;
  const started = performance.now();
  const parts = [];
  await Promise.all(Array.from({ length: workers }, async (_, worker) => {
    const start = first + worker * size;
    const end = Math.min(last, start + size);
    if (start >= end) return;
    const file = join(output, "parts", `part-${String(worker).padStart(2, "0")}.mp4`);
    parts[worker] = file;
    let browser = await launch();
    let cam = await camera(browser, origin);
    const sink = encoder(file);
    for (let index = start; index < end; index++) {
      let png;
      // Headless Chrome occasionally stalls a capture; restart it and retry
      // the same frame. Frames are pure functions of time, so nothing is lost.
      for (let attempt = 1; !png; attempt++) {
        try {
          png = await cam.shoot(index / fps);
        } catch (error) {
          if (attempt >= 4) throw error;
          console.error(`\nworker ${worker}: frame ${index} failed (${error.message.split("\n")[0]}); restarting its browser`);
          await browser.close().catch(() => {});
          browser = await launch();
          cam = await camera(browser, origin);
        }
      }
      await sink.write(png);
      done++;
      if (done % fps === 0) {
        const elapsed = (performance.now() - started) / 1000;
        process.stdout.write(`\r${done}/${total} frames · ${(done / elapsed).toFixed(1)} fps · ${Math.round((total - done) / (done / elapsed))} s left   `);
      }
    }
    await sink.end();
    await browser.close();
  }));
  server.close();
  console.log(`\nRendered ${total} frames in ${((performance.now() - started) / 1000).toFixed(0)} s`);

  const list = join(output, "parts", "list.txt");
  await writeFile(list, parts.filter(Boolean).map((file) => `file '${file}'`).join("\n"));
  const name = option("out", from === 0 && to === FILM.duration ? "kinara-film.mp4" : `kinara-film-${from}-${to}.mp4`);
  const result = join(output, name);
  await run("ffmpeg", ["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", list, "-i", audio,
    "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "320k", "-shortest", "-movflags", "+faststart", result]);
  await rm(join(output, "parts"), { recursive: true, force: true });
  console.log(result);
}

// node render.mjs --check 26,40.5   draws each time twice, cold and after other
// frames, and reports whether the two captures match: they must, exactly.
async function check(times) {
  const server = await serve();
  const browser = await launch();
  const cam = await camera(browser, `http://127.0.0.1:${server.address().port}`);
  let bad = 0;
  for (const t of times) {
    await cam.shoot((t + 31.7) % FILM.duration);
    const a = Buffer.from(await cam.shoot(t));
    await cam.shoot((t + 12.3) % FILM.duration);
    await cam.shoot(t - 1 / fps);
    const b = Buffer.from(await cam.shoot(t));
    // A few pixels a single step apart is the browser's own rounding; more is a bad frame.
    const same = Math.abs(a.length - b.length) < Math.max(a.length, b.length) * 0.002;
    if (!same) bad++;
    console.log(`${t.toFixed(2)} s: ${same ? "same" : `DIFFERENT (${a.length} vs ${b.length} bytes)`}`);
  }
  console.log(bad ? `${bad} of ${times.length} frames differ.` : "Every frame came out the same both ways.");
  await browser.close();
  server.close();
}

if (args.includes("--check")) {
  await check(option("check", "1").split(",").map(Number));
  process.exit(0);
} else if (args.includes("--serve")) {
  const server = await serve(4173);
  console.log(`http://127.0.0.1:${server.address().port}/?scrub`);
} else {
  if (args.includes("--stills")) await stills(option("stills", "1").split(",").map(Number));
  else await film();
  // Don't let a lingering browser or socket keep the process alive.
  process.exit(0);
}
