import { Hero } from '@/components/Hero';
import { Cinema } from '@/components/Cinema';
import { Highlights } from '@/components/Highlights';
import { LittleThings } from '@/components/LittleThings';
import { audioApps, details, download, mixer, questions, site } from '@/data/site';

const Chevron = () => (
  <svg width="8" height="12" viewBox="0 0 8 12" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M2 1.5L6.5 6 2 10.5" /></svg>
);
const Plus = () => (
  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" aria-hidden="true"><path d="M9 3v12M3 9h12" /></svg>
);
const icons = [
  <svg key="free" width="34" height="34" viewBox="0 0 34 34" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><rect x="5" y="13" width="24" height="16" rx="2.5" /><path d="M3.5 9.5h27v3.5h-27zM17 9.5V29" /><path d="M17 9.5c-1.6-3.6-6.6-5-7.6-2.4-.9 2.4 3.6 2.4 7.6 2.4zM17 9.5c1.6-3.6 6.6-5 7.6-2.4.9 2.4-3.6 2.4-7.6 2.4z" /></svg>,
  <svg key="source" width="34" height="34" viewBox="0 0 34 34" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M12 10l-7 7 7 7M22 10l7 7-7 7M19.5 7l-5 20" /></svg>,
  <svg key="updates" width="34" height="34" viewBox="0 0 34 34" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M27 17a10 10 0 1 1-3-7.1" /><path d="M27 6v6h-6" /></svg>,
];

export default function Home() {
  return (
    <>
      <Hero />
      <Highlights />
      <Cinema />

      <section id="mixer" className="section" aria-labelledby="mixer-title">
        <div className="wrap head">
          <p className="t-eyebrow grad">{mixer.eyebrow}</p>
          <h2 id="mixer-title" className="t-headline" data-split="lines">{mixer.title}</h2>
          <p className="t-intro" data-reveal="up">{mixer.lead}</p>
        </div>
        <div className="mx__shot" data-reveal="up">
          {/* eslint-disable @next/next/no-img-element */}
          <img className="only-light" src="/media/desktop-light.webp" width={2560} height={1600} loading="lazy"
            alt="A Mac desktop with Kinara's settings open on Sound & display and the Kinara menu open below the menu bar, each app with its own volume" />
          <img className="only-dark" src="/media/desktop-dark.webp" width={2560} height={1600} loading="lazy"
            alt="A Mac desktop in dark mode with Kinara's settings open on Sound & display and the Kinara menu open below the menu bar, each app with its own volume" />
          {/* eslint-enable @next/next/no-img-element */}
        </div>
        <div className="wrap">
          <ul className="mx__points" data-reveal="up">
            {mixer.points.map((p) => <li key={p.title}><b>{p.title}</b><span>{p.body}</span></li>)}
          </ul>
          <p className="t-small mx__note">{mixer.note}</p>
        </div>

        <div className="wrap aud">
          <div className="aud__copy">
            <p className="t-eyebrow grad">{audioApps.eyebrow}</p>
            <h3 className="aud__title" data-split="lines">{audioApps.title}</h3>
            <p className="t-intro" data-reveal="up">{audioApps.lead}</p>
            <ul className="aud__points" data-reveal="up">
              {audioApps.points.map((p) => <li key={p.title}><b>{p.title}</b><span>{p.body}</span></li>)}
            </ul>
          </div>
          <div className="aud__shot" data-reveal="up">
            {/* eslint-disable @next/next/no-img-element */}
            <img className="only-light" src="/media/audio-picker-light.webp" width={1240} height={960} loading="lazy"
              alt="Kinara's audio picker on a Mac desktop: Music and Safari playing, FaceTime muted, Podcasts quiet, with Safari highlighted and ready to mute" />
            <img className="only-dark" src="/media/audio-picker-dark.webp" width={1240} height={960} loading="lazy"
              alt="Kinara's audio picker in dark mode: Music and Safari playing, FaceTime muted, Podcasts quiet, with Safari highlighted and ready to mute" />
            {/* eslint-enable @next/next/no-img-element */}
          </div>
        </div>
      </section>

      <LittleThings />

      <section id="details" className="section section--alt" aria-labelledby="details-title">
        <div className="wrap head">
          <h2 id="details-title" className="t-headline" data-split="lines">{details.title}</h2>
        </div>
        <div className="wrap">
          <ul className="bento">
            {details.tiles.map((t) => (
              <li key={t.title} data-size={t.size} data-reveal="up">
                <div>
                  <span className="bento__stat grad">{t.stat}</span>
                  <span className="bento__title">{t.title}</span>
                </div>
                <p>{t.body}</p>
              </li>
            ))}
          </ul>
        </div>
      </section>

      <section id="download" className="section" aria-labelledby="download-title">
        <div className="wrap get">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img className="get__icon" src="/media/kinara-icon-256.webp" width={112} height={112} alt="" loading="lazy" />
          <h2 id="download-title" className="t-headline">{download.title}</h2>
          <p className="get__price">{download.price} <span>{download.priceNote}</span></p>
          <div className="ctas">
            <a className="btn" href={site.downloadUrl} data-no-transition>Download</a>
            <a className="link" href={site.sourceUrl} data-no-transition>View the source on GitHub <Chevron /></a>
          </div>
          <ul className="get__points">
            {download.points.map((p, i) => <li key={p.title}>{icons[i]}<b>{p.title}</b><span>{p.body}</span></li>)}
          </ul>
        </div>
      </section>

      <section id="faq" className="section section--alt" aria-labelledby="faq-title">
        <div className="wrap head">
          <h2 id="faq-title" className="t-headline" data-split="lines">Questions? Answers.</h2>
        </div>
        <div className="wrap faq">
          {questions.map((item) => (
            <details key={item.q}>
              <summary>{item.q}<Plus /></summary>
              <p>{item.a}</p>
            </details>
          ))}
        </div>
      </section>
    </>
  );
}
