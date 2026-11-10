import { site } from '@/data/site';

type Doc = { title: string; intro: string; sections: { h: string; p: string[]; link?: { text: string; href: string } }[] };

/** A plain page for policy text: title on the left, readable column on the right. */
export function LegalPage({ doc }: { doc: Doc }) {
  return (
    <article className="legal" aria-labelledby="doc-title">
      <div className="wrap legal__in">
        <header>
          <h1 id="doc-title" data-split="lines" data-intro>{doc.title}</h1>
          <p className="t-small" style={{ marginTop: 12 }}>Updated {site.updated}</p>
        </header>
        <div className="legal__body">
          <p className="t-intro" data-reveal="up" data-intro>{doc.intro}</p>
          {doc.sections.map((s) => (
            <section key={s.h}>
              <h2>{s.h}</h2>
              {s.p.map((text) => <p key={text}>{text}</p>)}
              {s.link && (
                <p>
                  <a className="link" href={s.link.href}>
                    {s.link.text}
                    <svg width="8" height="12" viewBox="0 0 8 12" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M2 1.5L6.5 6 2 10.5" /></svg>
                  </a>
                </p>
              )}
            </section>
          ))}
        </div>
      </div>
    </article>
  );
}
