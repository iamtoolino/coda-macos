# Developing Coda

## Build and test

Install Xcode Command Line Tools 26 or newer, Swift 6.2 or newer, and the build dependencies:

```sh
brew install meson ninja pkg-config libunibreak graphite2 freetype fribidi harfbuzz libpng
```

Build and open the app, then run the automated tests:

```sh
./scripts/build-app.sh release
open .build/Coda.app
swift test
```

`scripts/build-app.sh` builds a debug app when no configuration is given.

## Debug builds and login storage

Debug builds store the server URL, username and password as plaintext JSON at
`~/Library/Application Support/Coda/DevelopmentLogin.json`, with file mode `0600` and a newly
created Coda directory mode `0700`. If that file is absent, a debug launch reads an existing
Keychain login and automatically copies it to this file. Release builds use Keychain only and do
not read or remove the development file.

Debug sign-out removes both the file and the Keychain login; release sign-out removes only the
Keychain login. To remove the plaintext copy without signing out, delete that file and use a
release build: launching debug again can recreate it from Keychain. Keep the development file out
of shared reports and backups.

## Offline audio-output checks

These checks compile the production C bridge into a test harness and render synthetic audio
through the bundled libmpv. They use no server, credentials or audio device. Build libmpv first.

### ReplayGain

```sh
python3 scripts/check-replaygain-output.py
```

Renders synthetic tones to WAV files under `.build/replaygain-output-check/` and checks PCM
scaling, per-file transitions, updated same-URL next gain and disabling gain. Policy and
occurrence-state checks remain in `swift test`.

### Gapless playback

```sh
python3 scripts/check-gapless-output.py
```

Encodes synthetic tracks with odd sample counts as FLAC, Opus, MP3, AAC/M4A (FFmpeg and, when
`afconvert` is present, Apple's encoder) and Ogg Vorbis, then renders queues through the
production bridge. Each case serves the files locally, over HTTP with ranges, and over HTTP
without a length, and requires exactly the encoded number of samples with no shifted or missing
audio at any transition. It needs the `ffmpeg` command-line tool; formats whose encoder
Homebrew's FFmpeg lacks (for example `libvorbis`) are skipped. Bundled FFmpeg carries the small
gapless fixes in `scripts/patches/ffmpeg/`.

## Further documentation

- [ReplayGain playback specification](replaygain.md)
- [Queue and playlist presentation](track-list-presentation.md)
- [Album Resume Bookmark protocol](album-resume-bookmarks.md) and
  [Coda album resume design](coda-album-resume-design.md)
- [Optional Navidrome artwork cache tuning](artwork-performance.md)
- [Homepage](homepage.md)
- [Releasing Coda](releasing.md)
