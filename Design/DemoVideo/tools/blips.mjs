// Finds one-frame glitches in a video: a frame unlike both of its neighbours
// while those neighbours are alike. Usage: node blips.mjs film.mp4
import { spawn } from "node:child_process";
const W = 480, H = 270, SIZE = W * H;
const ff = spawn("ffmpeg", ["-loglevel", "error", "-i", process.argv[2], "-vf", `scale=${W}:${H}:flags=area,format=gray`, "-f", "rawvideo", "-"], { stdio: ["ignore", "pipe", "inherit"] });
let pending = Buffer.alloc(0), a = null, b = null, index = 0;
const found = [];
const consider = (c) => {
  if (a && b) {
    let score = 0;
    for (let i = 0; i < SIZE; i++) {
      const odd = Math.min(Math.abs(b[i] - a[i]), Math.abs(b[i] - c[i])) - Math.abs(a[i] - c[i]);
      if (odd > 12) score++;
    }
    if (score > 60) found.push([score, index - 1]);
  }
  a = b; b = c; index++;
};
ff.stdout.on("data", (chunk) => {
  pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
  while (pending.length >= SIZE) { consider(Buffer.from(pending.subarray(0, SIZE))); pending = pending.subarray(SIZE); }
});
ff.on("close", () => {
  console.log(`${index} frames, ${found.length} suspect`);
  for (const [score, i] of found.sort((x, y) => y[0] - x[0]).slice(0, Number(process.argv[3] || 30))) console.log(`  frame ${i} (${(i / 60).toFixed(3)} s): ${score} px`);
});
