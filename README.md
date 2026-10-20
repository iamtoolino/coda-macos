# Coda — Album-First Navidrome Client for macOS

Coda is a focused native macOS client for Navidrome and compatible OpenSubsonic servers. It keeps
artwork, albums, and the listening queue at the center of the experience.

Website: [coda-macos.vercel.app](https://coda-macos.vercel.app/)

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
- Proper artist credits: compilations show each track's artist, and Various Artists opens as a
  compilation collection.
- A visible, editable queue with drag-and-drop, album grouping, and queue handoff.
  In narrow windows it slides in from the right edge.
- Original-format playback with sample-exact gapless transitions in common formats, plus seeking,
  scrobbling, and saved queue restoration.
- Optional ReplayGain (Playback → ReplayGain) that picks album or track gain automatically.
- Continue Listening picks up unfinished albums where you left off.
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
./scripts/build-app.sh release
open .build/Coda.app
```

Tests, debug builds, audio-output checks and design notes are covered in
[docs/development.md](docs/development.md).

## Privacy

Coda contains no analytics, advertising, or tracking SDK. It communicates only with the server
configured by the user.

Artwork responses are cached only in memory and are discarded when Coda exits. The artwork cache
does not intentionally write OpenSubsonic authentication values or request URLs to disk.

## License

Copyright 2026 iamtoolino.

Coda's source code is licensed under the [Apache License, Version 2.0](LICENSE). Bundled libraries
retain their respective licenses; their notices are included in the built app.
