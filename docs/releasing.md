# Releasing Coda

Coda releases are built locally from an annotated version tag and published as a macOS arm64 ZIP
with a separate SHA-256 checksum. Publishing is intentionally a separate approval step from release
preparation and packaging.

## Prerequisites

- A clean `main` checkout containing every intended release commit.
- The version in `Support/Info.plist` set to the release version.
- Xcode Command Line Tools, Swift, and the dependencies listed in `README.md`.
- The long-lived `Coda Local Development` code-signing identity with SHA-1 fingerprint
  `C0265B406C5DB49A5C626DDA5D1B12EADA89752C` in the login keychain.
- An authenticated GitHub CLI session for the final publish step.

The public build is not Developer ID signed or notarized. The local development identity keeps the
signature stable across Coda releases. `scripts/package-release.sh` refuses to package a public
release when that exact identity is unavailable instead of silently falling back to ad-hoc signing.
It also rejects `CODA_SIGNING_IDENTITY` overrides and verifies that the finished app's designated
requirement references the expected certificate. Changing the public release identity is a
separately reviewed migration because it changes Coda's Keychain and Local Network privacy identity.

## 1. Prepare the release commit

1. Confirm the latest public GitHub release and select the next version.
2. Review the commits and user-facing changes since the previous tag.
3. Update `CFBundleShortVersionString` in `Support/Info.plist`.
4. Draft release notes and a short manual verification checklist.
5. Run the candidate checks:

   ```sh
   ./scripts/build-libmpv.sh
   swift test
   ./scripts/build-app.sh release
   ```

6. Inspect the diff and commit the version preparation. Do not tag a dirty or unverified tree.

## 2. Verify the app manually

Use the release build as a normal player before tagging. Concentrate on behavior automation cannot
judge reliably:

- Sign in, reconnect, and sign out.
- Start playback, seek, pause, resume, skip, and allow a track to finish naturally.
- Confirm gapless queue transitions and queue restoration.
- Exercise selection, reordering, removal, and saving the queue as a playlist.
- Browse Home, Search, Artists, Albums, Playlists, album detail, and Now Playing.
- Check ratings, artwork changes, window resizing, inactive-window appearance, and keyboard/media
  shortcuts.

## 3. Tag and package

After the release commit and manual verification are approved, create an annotated local tag:

```sh
git tag -a v2.0.0 -m "Coda 2.0.0"
```

Run the packaging script with the matching version:

```sh
./scripts/package-release.sh 2.0.0
```

The script requires a clean tree and an annotated `vX.Y.Z` tag pointing to `HEAD`. It reruns the
tests and release build, then verifies:

- source version, embedded Git commit, and exact tag;
- release configuration and arm64 architecture;
- strict nested code signatures and the pinned release signing identity and designated requirement;
- release entitlements and bundled license materials through `build-app.sh`;
- ZIP integrity and SHA-256 checksum.

Artifacts are written under `.build/releases/vX.Y.Z/`:

```text
Coda-X.Y.Z-macOS-arm64.zip
Coda-X.Y.Z-macOS-arm64.zip.sha256
```

Existing artifacts are never overwritten automatically.

## 4. Publish after explicit approval

Review the tag, release notes, artifact names, and checksum before changing GitHub:

```sh
git status --short --branch
git show --no-patch v2.0.0
shasum -a 256 -c .build/releases/v2.0.0/Coda-2.0.0-macOS-arm64.zip.sha256
```

Push the verified commit and tag:

```sh
git push origin main
git push origin v2.0.0
```

Create the GitHub release using the reviewed notes and both assets:

```sh
gh release create v2.0.0 \
  --repo iamtoolino/coda-macos \
  --title "Coda 2.0.0" \
  --notes-file .build/release-notes-v2.0.0.md \
  .build/releases/v2.0.0/Coda-2.0.0-macOS-arm64.zip \
  .build/releases/v2.0.0/Coda-2.0.0-macOS-arm64.zip.sha256
```

Finally, open the public release, confirm both downloads are present, and verify that GitHub marks
it as the latest non-prerelease release.
