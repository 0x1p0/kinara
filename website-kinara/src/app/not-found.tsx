import type { Metadata } from 'next';

export const metadata: Metadata = { title: 'Nothing on this edge', description: 'This page does not exist.' };

/** The 404 is the trackpad with the light gone out: nothing assigned here. */
export default function NotFound() {
  return (
    <section className="lost" aria-labelledby="lost-title">
      <div>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img className="lost__pad" src="/media/lost-pad.jpg" width={968} height={402} alt="" />
        <h1 id="lost-title" className="t-headline">Nothing is assigned to this edge.</h1>
        <p className="t-intro">The page you were reaching for doesn’t exist.</p>
        <a className="btn" href="/">Back to Kinara</a>
      </div>
    </section>
  );
}
