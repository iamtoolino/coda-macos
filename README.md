# Coda — Album-First Navidrome Client for macOS

Coda is a focused native macOS client for Navidrome and compatible OpenSubsonic servers. It keeps
artwork, albums, and the listening queue at the center of the experience.

Coda is an independent community project and is not affiliated with or endorsed by Navidrome.

<p align="center">
  <img src="screenshots/Home.png" width="49%" alt="Coda home screen">
  <img src="screenshots/Album.png" width="49%" alt="Coda album view">
</p>

<p align="center">
  <img src="screenshots/nowplaying.png" width="49%" alt="Coda Now Playing screen">
  <img src="screenshots/search.png" width="49%" alt="Coda search results">
</p>

## Highlights

- Artwork-led native macOS design with album-derived colors and Liquid Glass controls.
- Album-first browsing with chronological discographies, multidisc releases, ratings, and search.
- Server-supplied track and album credits with separate artist links. Compilations show
  the track title with a smaller, muted artist credit beneath it in album, grouped playlist, and
  queue rows when Navidrome marks the album as a compilation; other albums keep title-only rows.
  Song search and Now Playing use track credits, while album headers keep album credits.
  Artist search hides artists with zero albums; matching albums and songs remain searchable.
  The Various Artists page presents a compilation collection with a stack icon and a Compilations
  heading. Queue context menus use “Show Artist” for the clicked track or album's first artist.
- A visible, editable queue with drag-and-drop insertion, reordering, removal, and queue handoff.
  In narrow windows, hover over, click, or drag music to the right edge to reveal the queue over the content;
  it closes shortly after the pointer leaves, or with Escape.
- Original-format playback with gapless transitions, seeking, scrobbling, and saved queue restoration.
- Native media keys, macOS Now Playing integration, and a dedicated immersive Now Playing view.

## Requirements

- macOS 26 or newer on an Apple silicon Mac.
- A Navidrome server or compatible OpenSubsonic implementation.
- Network access to that server; HTTPS is recommended outside a trusted network.

## Install

Download the macOS arm64 ZIP from the latest GitHub release, extract `Coda.app`, and move it to
`/Applications`.

The app is not currently notarized. After reviewing the source, you can remove macOS quarantine
from a downloaded build with:

```sh
xattr -dr com.apple.quarantine /Applications/Coda.app
```

## Build from source

Install Xcode Command Line Tools 26 or newer, Swift 6.2 or newer, and the build dependencies:

```sh
brew install meson ninja pkg-config libunibreak graphite2 freetype fribidi harfbuzz libpng
```

Then build and open the release app:

```sh
./scripts/build-app.sh release
open .build/Coda.app
```

Run the automated tests with:

```sh
swift test
```

### Selecting artist-credit test albums

With Python 3.11 or newer and `naviclient` installed in the active environment, use the
read-only metadata selector:

```sh
python3 scripts/find-artist-test-cases.py --album "Album title" --discover 2
python3 -m unittest discover -s scripts -p 'test_artist_test_cases.py'
```

Repeat `--album` for each title substring. All matching editions are retained. The script uses
`naviclient.Client.from_config()` to load the existing private `[navidrome]` configuration;
no password prompt is needed. Use `--config /path/to/private/config.toml` or `NAVICLIENT_CONFIG`
to override naviclient's shared configuration defaults. Authentication, TLS, redirects, proxies
and transport limits follow naviclient's behavior. HTTP is supported for trusted LANs; use HTTPS
outside them. Run with your configured venv's Python interpreter when it is not activated.
Use `--artist "Artist name"` to select albums by album-artist credit or individual artist name
instead of title; this can be repeated or combined with `--album`.

It pages through album summaries and fetches tracks only for selected albums. `--discover N`
adds up to N candidates in each album-level category: compilations, multiple album artists,
and explicitly non-compilation single-artist albums. It does not scan every album's tracks for
guests. The default scan limit is 20,000 albums (`--max-albums` overrides it).

The private JSON report under `.build/artist-test-cases/` preserves display credits, artist IDs
and arrays, and compilation flags (including absence). It flags varying track credits and
possible shared recordings across selected albums. Matching titles alone are candidates, not
proof of identical recordings. Missing queries and ambiguous editions remain visible in
`requestedMatches` and `requestedArtistMatches`. A separate candidate comparison removes parenthesized
`feat.` / `ft.` credits from titles; it does not establish recording identity. These are
server-interpreted fields, not a dump of the files' original tags.
Reports contain personal library metadata: keep them untracked. Credentials, server URLs,
file paths and artwork are excluded. No playback, tag edits, ratings or server scans are triggered.

## Privacy

Coda contains no analytics, advertising, or tracking SDK. It communicates only with the server
configured by the user.

Artwork responses are cached only in memory and are discarded when Coda exits. The artwork cache
does not intentionally write OpenSubsonic authentication values or request URLs to disk.

## License

Copyright 2026 iamtoolino.

Coda's source code is licensed under the [Apache License, Version 2.0](LICENSE). Bundled libraries
retain their respective licenses; their notices are included in the built app.
