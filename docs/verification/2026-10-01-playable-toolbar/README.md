# Playable homepage toolbar — 1 October 2026

Evidence for the homepage's playable toolbar (`site/home-play.mjs`, `site/home-play.css`). Ethan chose to keep it an Easter egg: nothing on the page advertises it. The pages were built with `node build.mjs --require-production` and served locally with the response headers from `site/vercel.json`, including the production Content Security Policy. Captures came from headless Chrome through the DevTools protocol. Headless Chrome draws no pointer, so the recording session added one; it is not part of the site. Nothing was deployed.

| File | What it shows |
| --- | --- |
| `play.gif` | 1440×900, about 22 s. The tour runs, the capsule is hovered and opened, Snap & Talk plays to its saved deck, Draw circles the headline, the visitor loops "Download for Mac", the first Esc clears the ink, and the second Esc lets the tour carry on into Persona. |
| `hover-light.png` | The closed toolbar on hover. Apart from the pointer and a faint mint ring, the page is unchanged. |
| `snap-rest-light.png` | Snap & Talk picked from the open toolbar, resting on the saved deck. |
| `draw-page-light.png` | Draw picked: the headline circle, the visitor's own ink on the page, and the Esc / Done bar. |
| `phone-persona-dark.png` | 375×812, dark, touch: Persona picked. The tray sits above the capsule to keep clear of the persona card. |
| `reduced-motion-draw-light.png` | Reduced motion: Draw shows its finished frame at once, and the pen is still offered. |

## Checked

- `node --test tests/*.test.mjs`: 20 pass, including a new check that the built homepage has no inline styles, scripts or handlers and ships both new files.
- No console errors or CSP reports on `/` under the production headers.
- Tray placement measured at 375, 800, 1024, 1280, 1440 and 1920 px: never over the persona card, always inside the viewport, and no sideways scroll at 375 px.
- Touch: tap to open, finger drawing does not scroll the page, Done clears the ink, and tapping outside closes the toolbar.
- Keyboard: Tab reaches the toolbar after the hero links, Enter opens it with focus on Dictate, the first Esc clears the ink, the second closes the toolbar and returns focus to it.
- Reduced motion: no animation frames run, and each pick shows its still frame (Dictate recording, Snap selection, Draw circle, Persona).
- No microphone, camera or other device access.
