import { site } from '@/data/site';

type Doc = { title: string; intro: string; sections: { h: string; p: string[] }[] };

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
            </section>
          ))}
        </div>
      </div>
    </article>
  );
}
