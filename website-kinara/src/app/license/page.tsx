import type { Metadata } from 'next';
import { LegalPage } from '@/components/LegalPage';
import { legal } from '@/data/site';

export const metadata: Metadata = {
  title: legal.license.title,
  description: legal.license.intro,
};

export default function Page() {
  return <LegalPage doc={legal.license} />;
}
