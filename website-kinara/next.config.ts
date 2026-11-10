import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Plain HTML, CSS and JS in out/, served by Cloudflare Pages. No server runs.
  output: 'export',
};

export default nextConfig;
