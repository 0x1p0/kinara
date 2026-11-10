import { download, site } from '@/data/site';

export function Footer() {
  return (
    <footer className="footer">
      <div className="wrap">
        <div className="footer__notes">
          <p>{download.note} {site.requirements}</p>
          <p>CPU and memory figures were measured on an M4 MacBook with gestures paused and the menu closed.</p>
          <p>{site.trademarks}</p>
        </div>
        <div className="footer__bar">
          <span>Copyright © 2026 {site.maker}. Kinara is free and open source.</span>
          <ul>
            <li><a href="/privacy">Privacy</a></li>
            <li><a href="/license">License</a></li>
            <li><a href={site.sourceUrl}>Source</a></li>
            <li><a href={site.issuesUrl}>Contact</a></li>
          </ul>
        </div>
      </div>
    </footer>
  );
}
