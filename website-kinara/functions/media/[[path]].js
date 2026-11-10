/* global FixedLengthStream */
// Safari plays a video only from a server that answers byte-range requests with 206 Partial
// Content, and Cloudflare Pages' static file server answers every request with the whole file.
// This function runs for /media/* only: a GET with a Range header gets just the bytes it asked
// for; everything else is passed to the static files untouched.

export async function onRequest({ request, env, next }) {
  const range = request.headers.get('Range');
  if (request.method !== 'GET' || !range) return next();

  const asset = await env.ASSETS.fetch(new Request(request.url));
  const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
  if (asset.status !== 200 || !asset.body || !match || (match[1] === '' && match[2] === '')) {
    return asset;
  }
  // Cloudflare sends the file's size; the local preview server doesn't, so there the file is
  // read whole to learn it.
  let size = Number(asset.headers.get('Content-Length'));
  let whole = null;
  if (!size) {
    whole = await asset.arrayBuffer();
    size = whole.byteLength;
  }

  // bytes=a-b, bytes=a- (to the end) or bytes=-n (the last n bytes).
  let start = match[1] === '' ? Math.max(size - Number(match[2]), 0) : Number(match[1]);
  let end = match[1] === '' || match[2] === '' ? size - 1 : Math.min(Number(match[2]), size - 1);
  if (start >= size || start > end) {
    if (!whole) await asset.body.cancel();
    return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
  }

  const length = end - start + 1;
  const headers = new Headers(asset.headers);
  headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
  headers.set('Content-Length', String(length));
  headers.set('Accept-Ranges', 'bytes');
  headers.set('Cache-Control', 'public, max-age=86400');
  headers.delete('Transfer-Encoding');

  if (whole) return new Response(whole.slice(start, end + 1), { status: 206, headers });
  const { readable, writable } = new FixedLengthStream(length);
  slice(asset.body, start, end + 1).pipeTo(writable).catch(() => {});
  return new Response(readable, { status: 206, headers });
}

// The bytes [start, stop) of a stream, read in order and stopped as soon as they are through.
function slice(body, start, stop) {
  let offset = 0;
  return body.pipeThrough(
    new TransformStream({
      transform(chunk, controller) {
        const from = Math.max(start - offset, 0);
        const to = Math.min(stop - offset, chunk.byteLength);
        offset += chunk.byteLength;
        if (to > from) controller.enqueue(chunk.subarray(from, to));
        if (offset >= stop) controller.terminate();
      },
    }),
  );
}
