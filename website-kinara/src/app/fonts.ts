import localFont from 'next/font/local';

// SF Pro comes from the system on every Mac (the people who can buy Kinara). Switzer is the
// fallback elsewhere; it isn't preloaded, so Macs never download it.
export const switzer = localFont({
  src: [
    { path: '../fonts/switzer-400-normal.woff2', weight: '400', style: 'normal' },
    { path: '../fonts/switzer-500-normal.woff2', weight: '500', style: 'normal' },
    { path: '../fonts/switzer-600-normal.woff2', weight: '600', style: 'normal' },
    { path: '../fonts/switzer-700-normal.woff2', weight: '700', style: 'normal' },
  ],
  variable: '--font-switzer',
  display: 'swap',
  preload: false,
});
