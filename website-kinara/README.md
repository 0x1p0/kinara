# Kinara website

Kinara's product page, built with Next.js as plain static files and served by Cloudflare
Pages at https://kinara-app.pages.dev. No server runs: `next build` writes the whole site to
`out/`. Design notes are in `DESIGN.md`; every word on the site is in `src/data/site.ts`.

```bash
npm install
npm run dev                          # work on it at http://localhost:3000
npm run build                        # the static site → out/
npm run preview -- --port 4400       # serve out/ the way Cloudflare Pages does
npm run check:theme                  # light, dark and Reduced Motion, against the preview
npm run deploy                       # build, then publish to Cloudflare Pages
```

`preview` and `deploy` use Cloudflare's `wrangler` (`npm install -g wrangler`), and `deploy`
needs `wrangler login` once. Response headers, such as
caching, are set in `public/_headers`.

Cloudflare Pages takes files up to 25 MiB, so the film in `public/media/` must stay under it;
`Design/DemoVideo/tools/site-media.sh` checks this when it cuts the site's media.

To use another address, set `NEXT_PUBLIC_SITE_URL` when building; links, the sitemap and
social previews follow it.
