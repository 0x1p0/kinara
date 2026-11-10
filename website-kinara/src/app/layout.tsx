import type { Metadata, Viewport } from 'next';
import { Footer } from '@/components/Footer';
import { Header } from '@/components/Header';
import { Motion } from '@/components/Motion';
import { ScrollEdge } from '@/components/ScrollEdge';
import { site } from '@/data/site';
import { switzer } from './fonts';
import '@/engine/engine.css';
import './globals.css';

export const metadata: Metadata = {
  metadataBase: new URL(site.url),
  title: { default: `${site.name}: ${site.tagline}`, template: `%s | ${site.name}` },
  description: site.description,
  alternates: { canonical: './' },
  openGraph: { type: 'website', siteName: site.name, title: `${site.name}: ${site.tagline}`, description: site.description, images: ['/og.png'] },
  twitter: { card: 'summary_large_image', title: `${site.name}: ${site.tagline}`, description: site.description, images: ['/og.png'] },
};

export const viewport: Viewport = {
  themeColor: [{ media: '(prefers-color-scheme: light)', color: '#ffffff' }, { media: '(prefers-color-scheme: dark)', color: '#000000' }],
  colorScheme: 'light dark',
};

// Runs before first paint: hidden-until-revealed styles only apply when JS and motion are on.
// Also restores a theme chosen with the toggle (stored only in this browser); otherwise the
// system setting decides.
const flags = `document.documentElement.classList.add('js');if(!matchMedia('(prefers-reduced-motion: reduce)').matches)document.documentElement.classList.add('motion');try{var t=localStorage.getItem('kinara-theme');if(t==='light'||t==='dark')document.documentElement.dataset.theme=t}catch(e){}`;

const jsonLd = {
  '@context': 'https://schema.org',
  '@type': 'SoftwareApplication',
  name: site.name,
  operatingSystem: 'macOS 13 or later',
  applicationCategory: 'UtilitiesApplication',
  description: site.description,
  offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
  isAccessibleForFree: true,
  license: 'https://opensource.org/license/mit',
  downloadUrl: site.downloadUrl,
  author: { '@type': 'Person', name: site.maker },
  url: site.url,
};

export default function RootLayout({ children }: LayoutProps<'/'>) {
  return (
    <html lang="en" className={switzer.variable} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: flags }} />
      </head>
      <body>
        <a className="skip-link" href="#main">Skip to content</a>
        <div id="curtain" aria-hidden="true"><div className="curtain__panel"><span className="curtain__edge" /></div></div>
        <Header />
        <ScrollEdge />
        <main id="main" tabIndex={-1}>{children}</main>
        <Footer />
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd).replace(/</g, '\\u003c') }} />
        <Motion />
      </body>
    </html>
  );
}
