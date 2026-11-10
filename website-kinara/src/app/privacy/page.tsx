import type { Metadata } from 'next';
import { LegalPage } from '@/components/LegalPage';
import { legal } from '@/data/site';

export const metadata: Metadata = {
  title: legal.privacy.title,
  description: legal.privacy.intro,
};

export default function Page() {
  return <LegalPage doc={legal.privacy} />;
}
