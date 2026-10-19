# Homepage

The selected homepage is `docs/index.html`, based on design study 3. It is a dependency-free static site: no build step, analytics, server connection, audio, or external fonts. Vercel can use `docs` as the project root with no build command; deployment is not configured or published by this change.

From the repository root:

```sh
python3 scripts/preview-homepage.py
node scripts/check-homepage.mjs
```

Open `http://127.0.0.1:4173/` for the local preview.

Each visit chooses and begins loading a random artwork theme before the page body is parsed, so those matching screenshots are the first visible scene rather than a brief Sigh placeholder. Now Playing, Home, Album, and the page tint then cycle together automatically: the first change starts after 3.5 seconds, then each scene holds for 6.5 seconds with an 850 ms crossfade. Reduced motion keeps automatic playback but swaps images instantly. Both pause controls operate the same slideshow. It pauses in hidden tabs or when all screenshots are offscreen.

The twelve captures were explicitly supplied for the homepage. They are served as WebP (quality 86, alpha kept), about 2.5 MB for all twelve instead of 35 MB as PNG; the originals are recoverable from Git history before the WebP change. CSS hides exterior black padding. They demonstrate appearance, not exact in-app transitions or a playable web client. Installation details remain in the main repository README; the homepage links to them under the download button and in the footer, without a notarization label. `assets/og-image.jpg` is the link-preview image; `og:url` and `og:image` use the absolute https://coda-macos.vercel.app/ address because link previews require it.

The prototype gallery, other layouts, and their unused assets were removed after selection. They remain recoverable from Git commits `8d4efc2` and `21a0d5c`. Existing technical Markdown documents in `docs` are preserved.

Static checks validate assets and syntax, not visual quality. Human verification should cover desktop, narrow laptop and phone widths; random initial themes; all three synchronized screenshots; pause/resume; and reduced-motion settings. The Coda app is unchanged.
