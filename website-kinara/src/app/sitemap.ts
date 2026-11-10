import type { MetadataRoute } from 'next';
import { site } from '@/data/site';

export const dynamic = 'force-static';

export default function sitemap(): MetadataRoute.Sitemap {
  return ['/', '/privacy', '/license'].map((path) => ({ url: `${site.url}${path}` }));
}
