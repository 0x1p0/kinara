// Renders the website hero (hero.html, src/hero.js) as a scroll-scrubbed image
// sequence: 12 s at 24 fps, frame i at t = i / 24. Each frame is rendered at
// 1920×1080 in headless Chrome, downscaled with Lanczos, and encoded to WebP
// at two sizes. Frames are pure functions of time, so workers render in
// parallel and any frame can be re-rendered on its own.
//
//   node render-hero.mjs                     all 288 frames → website-kinara/public/media/hero-seq/{d,m}/
//   node render-hero.mjs --stills 0.5,3.6    PNG stills → build/DemoVideo/hero-stills/
//   node render-hero.mjs --serve             scrub it at http://127.0.0.1:4174/hero.html?scrub
import { createServer } from "node:http";
import { readFile, mkdir, writeFile, rm, readdir, stat } from "node:fs/promises";
import { spawn } from "node:child_process";
import { extname, join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { cpus } from "node:os";
import puppeteer from "puppeteer-core";

const here = dirname(fileURLToPath(import.meta.url));
const build = resolve(here, "../../build/DemoVideo");
const site = resolve(here, "../../website-kinara/public/media/hero-seq");
const chrome = process.env.CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const cwebp = process.env.CWEBP_PATH || "/opt/homebrew/bin/cwebp";
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index < 0 ? fallback : args[index + 1];
};

const FPS = 24, DURATION = 12, WIDTH = 1920, HEIGHT = 1080;
const FRAMES = Math.round(FPS * DURATION); // 288
const SETS = [
  { name: "d", width: 1600, height: 900, quality: 72 },
  { name: "m", width: 960, height: 540, quality: 68 },
];

const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".png": "image/png", ".json": "application/json" };
function serve(port = 0) {
  const server = createServer(async (request, response) => {
    const path = decodeURIComponent(new URL(request.url, "http://x").pathname);
    const file = join(here, path === "/" ? "hero.html" : path);
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

function launch() {
  return puppeteer.launch({
    executablePath: chrome,
    headless: true,
    protocolTimeout: 45000,
    args: ["--hide-scrollbars", "--force-color-profile=srgb", "--disable-background-timer-throttling",
      "--disable-renderer-backgrounding", "--enable-gpu-rasterization", "--ignore-gpu-blocklist", "--use-angle=metal"],
  });
}

async function openPage(browser, origin) {
  const page = await browser.newPage();
  await page.setViewport({ width: WIDTH, height: HEIGHT, deviceScaleFactor: 1 });
  page.on("pageerror", (error) => console.error("page error:", error.message));
  page.on("console", (message) => { if (message.type() === "error") console.error("console:", message.text()); });
  await page.goto(`${origin}/hero.html`, { waitUntil: "load" });
  await page.waitForFunction("window.__ready === true", { timeout: 60000 });
  return page;
}

async function frame(page, t) {
  await page.evaluate((time) => window.__seek(time), t);
  return page.screenshot({ type: "png", clip: { x: 0, y: 0, width: WIDTH, height: HEIGHT }, captureBeyondViewport: false });
}

function run(command, commandArgs) {
  return new Promise((done, fail) => {
    const child = spawn(command, commandArgs, { stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => (code === 0 ? done() : fail(new Error(`${command} exited ${code}: ${err.trim()}`))));
  });
}

/** A tiny pool so CPU-bound encodes don't swamp the renderers. */
function pool(size) {
  let active = 0;
  const queue = [];
  const next = () => {
    if (active >= size || !queue.length) return;
    active++;
    const { job, done, fail } = queue.shift();
    job().then(done, fail).finally(() => { active--; next(); });
  };
  return (job) => new Promise((done, fail) => { queue.push({ job, done, fail }); next(); });
}

/** 1920×1080 PNG → Lanczos downscale (in RGB) → one WebP per set. */
// -sns 0 keeps the graphite's smooth gradients from turning blocky at these qualities.
async function encode(png, index, scratch) {
  const name = `f${String(index).padStart(3, "0")}`;
  const source = join(scratch, `${name}.png`);
  await writeFile(source, png);
  const scaled = SETS.map((s) => join(scratch, `${name}-${s.name}.png`));
  const graph = `[0:v]format=gbrp,split=${SETS.length}${SETS.map((_, k) => `[s${k}]`).join("")};` +
    SETS.map((s, k) => `[s${k}]scale=${s.width}:${s.height}:flags=lanczos+accurate_rnd+full_chroma_int,format=rgb24[o${k}]`).join(";");
  await run("ffmpeg", ["-y", "-loglevel", "error", "-i", source, "-filter_complex", graph, ...SETS.flatMap((_, k) => ["-map", `[o${k}]`, "-frames:v", "1", scaled[k]])]);
  await Promise.all(SETS.map((s, k) => run(cwebp, ["-quiet", "-q", String(s.quality), "-m", "6", "-sharp_yuv", "-sns", "0", "-metadata", "none", scaled[k], "-o", join(site, s.name, `${name}.webp`)])));
  await Promise.all([source, ...scaled].map((f) => rm(f, { force: true })));
}

async function stills(times) {
  const server = await serve();
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await launch();
  const page = await openPage(browser, origin);
  const out = join(build, "hero-stills");
  await mkdir(out, { recursive: true });
  for (const t of times) {
    const png = await frame(page, t);
    const file = join(out, `t${t.toFixed(2).padStart(5, "0")}.png`);
    await writeFile(file, png);
    const box = await page.evaluate(() => window.__hero.bounds());
    console.log(`${file}  pad ${(box.widthFraction * 100).toFixed(1)}% wide, top ${(box.topFraction * 100).toFixed(1)}%, bottom ${(box.bottomFraction * 100).toFixed(1)}%, centre ${(box.centreX * 100).toFixed(1)}%`);
  }
  await browser.close();
  server.close();
}

async function sequence() {
  const first = Number(option("from", 0));
  const last = Math.min(Number(option("to", FRAMES)), FRAMES);
  const total = last - first;
  const workers = Math.max(1, Math.min(Number(option("workers", 4)), total));
  const encodes = pool(Number(option("encoders", Math.max(2, cpus().length - workers))));
  const scratch = join(build, "hero-frames");
  await mkdir(scratch, { recursive: true });
  for (const s of SETS) {
    await mkdir(join(site, s.name), { recursive: true });
    if (first === 0 && last === FRAMES) {
      for (const f of await readdir(join(site, s.name))) if (/^f\d{3}\.webp$/.test(f)) await rm(join(site, s.name, f));
    }
  }

  const server = await serve();
  const origin = `http://127.0.0.1:${server.address().port}`;
  const started = performance.now();
  let rendered = 0, encoded = 0;
  const pending = [];
  const progress = () => process.stdout.write(`\rrendered ${rendered}/${total} · encoded ${encoded}/${total} · ${((performance.now() - started) / 1000).toFixed(0)} s   `);
  await Promise.all(Array.from({ length: workers }, async (_, worker) => {
    let browser = await launch();
    let page = await openPage(browser, origin);
    // Interleave frames across workers so they all finish together.
    for (let index = first + worker; index < last; index += workers) {
      let png;
      for (let attempt = 1; !png; attempt++) {
        try {
          png = await frame(page, index / FPS);
        } catch (error) {
          if (attempt >= 4) throw error;
          console.error(`\nworker ${worker}: frame ${index} failed (${error.message.split("\n")[0]}); restarting its browser`);
          await browser.close().catch(() => {});
          browser = await launch();
          page = await openPage(browser, origin);
        }
      }
      rendered++;
      progress();
      pending.push(encodes(() => encode(png, index, scratch)).then(() => { encoded++; progress(); }));
    }
    await browser.close();
  }));
  await Promise.all(pending);
  server.close();
  await rm(scratch, { recursive: true, force: true });
  console.log(`\n${total} frames in ${((performance.now() - started) / 1000).toFixed(0)} s`);

  for (const s of SETS) {
    const files = (await readdir(join(site, s.name))).filter((f) => /^f\d{3}\.webp$/.test(f));
    let bytes = 0;
    for (const f of files) bytes += (await stat(join(site, s.name, f))).size;
    console.log(`${join(site, s.name)}  ${files.length} frames  ${(bytes / 1024 / 1024).toFixed(2)} MB  (${s.width}×${s.height}, q${s.quality})`);
  }
}

if (args.includes("--serve")) {
  const server = await serve(4174);
  console.log(`http://127.0.0.1:${server.address().port}/hero.html?scrub`);
} else {
  if (args.includes("--stills")) await stills(option("stills", "0").split(",").map(Number));
  else await sequence();
  process.exit(0);
}
