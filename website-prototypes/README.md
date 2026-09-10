# Coda homepage studies

Eight local, dependency-free website prototypes for comparing the homepage directions discussed on September 10, 2026. The comparison page has an eight-up overview and a two-way comparison. Open a study for its full-size layout and interactions.

## Preview

From the repository root:

```sh
python3 website-prototypes/serve.py
```

Open `http://127.0.0.1:4173/`. A direct study URL is `http://127.0.0.1:4173/concept.html?v=5`.

There is no dependency installation or build step. With Node.js available, validate the layouts, routes, screenshot references, and JavaScript syntax:

```sh
node website-prototypes/validate.mjs
```

## Directions

1. Native showroom — conventional, centered product presentation.
2. Sleeve notes — editorial margin with a large listening scene.
3. Living window — looping scenes beside concise product copy.
4. Choose a sleeve — manual album selection and coordinated page color.
5. Listening room — immersive app-first composition.
6. Product poster — one media surface with Now Playing / Browse / Album controls.
7. Open contact sheet — one complete window and two cropped glimpses.
8. One album, three moments — Home / Album / Now Playing screenshot sequence.

## Media and behavior

- The four Now Playing images and eight matching Home / Album captures were supplied by the user for these homepage studies. Directions 2 and 3 use the matching sets; other directions retain the repository's earlier Home and Album images. The app icon is the existing Coda SVG.
- Original image pixels are unchanged. CSS clips exterior black padding; sleeve buttons and contact-sheet details use explicitly cropped views of the same captures.
- These are still-image transitions, not a screen recording, playable web client, or demonstration of exact native transition behavior.
- Directions 2 and 3 start with a randomly selected theme, and coordinate Now Playing, Home, Album, and the page color. The first automatic change starts after 3.5 seconds; subsequent scenes hold for 6.5 seconds, with 850 ms crossfades. All images for the next theme decode before any view changes. Scene selection pauses the loop. Loops continue while any coordinated screenshot is visible, and pause when all are offscreen or the tab is hidden. Reduced-motion preferences default to a static scene with an explicit Play preview control.
- The preferred directions omit scene counters and artist/album captions outside the app. Direction 3 now includes both Home and Album views below its opening composition. The overview remains deterministic and still for fair comparisons.
- The optional walkthrough uses three stills of the Press Start album and ends on Now Playing. It does not loop or pretend to be a continuous recording.
- Overview and comparison thumbnails are live, noninteractive page renders, held still at the same desktop width. Full-size studies are responsive; open them individually to inspect a phone-width layout.
- No analytics, external fonts, server access, authentication, audio, or third-party runtime dependencies are included. Download and installation links open the public GitHub repository.

## Status

Local comparison only. Nothing has been published or connected to Vercel. The `dist/` directory is authored static source, intentionally tracked, not generated build output. The local Sites manifest declares only that static directory; it has no remote Site registration or credentials.

Before publishing a chosen direction, review the final screenshots and copy, replace the prototype navigation with the selected page, remove `noindex`, optimize the approved media, and confirm the installation requirements. The selected static page can then be deployed to Vercel separately.

Static validation does not establish visual quality. Compare desktop (approximately 1440 px), laptop (approximately 900 px), and phone (approximately 390 px) layouts, keyboard focus, screenshot legibility, pause/scene controls, and reduced-motion behavior before finalizing the direction. No Coda app code or build behavior is changed.
