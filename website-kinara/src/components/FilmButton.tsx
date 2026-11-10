'use client';

/** "Watch the film": Apple's blue link with a play disc. It takes you down to the cinema section,
 * which opens to the full screen and starts the film with sound. */
export function FilmButton() {
  return (
    <button type="button" className="filmlink" onClick={() => dispatchEvent(new CustomEvent('kinara:film'))}>
      Watch the film
      <span className="filmlink__disc" aria-hidden="true"><svg width="9" height="10" viewBox="0 0 9 10"><path d="M0 0.6v8.8L8.2 5z" fill="currentColor" /></svg></span>
    </button>
  );
}
