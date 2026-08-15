#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
configuration="${1:-debug}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
app="$root/.build/Coda.app"
bundle_identifier="io.github.iamtoolino.coda.macos"
signing_identity_name="${CODA_SIGNING_IDENTITY:-Coda Local Development}"
entitlement_options=()

case "$configuration" in
  debug)
    entitlement_options=(--entitlements "$root/Support/CodaDebug.entitlements")
    ;;
  release)
    ;;
  *)
    print -u2 "Unsupported build configuration: $configuration"
    print -u2 "Expected 'debug' or 'release'."
    exit 2
    ;;
esac

"$root/scripts/build-libmpv.sh"

SDKROOT="$sdk" \
  CLANG_MODULE_CACHE_PATH="/private/tmp/coda-macos-clang-cache" \
  SWIFT_MODULE_CACHE_PATH="/private/tmp/coda-macos-swift-cache" \
  swift build --disable-sandbox --configuration "$configuration"

binary="$root/.build/arm64-apple-macosx/$configuration/CodaPlaybackSpike"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
mkdir -p "$app/Contents/Frameworks"
rm -rf "$app/Contents/Resources/Licenses"
mkdir -p "$app/Contents/Resources/Licenses"
cp "$binary" "$app/Contents/MacOS/Coda"
cp "$root/.build/libmpv/prefix/lib/libmpv.2.dylib" "$app/Contents/Frameworks/libmpv.2.dylib"
cp "$root/.build/libmpv/prefix/lib/libgraphite2.3.dylib" "$app/Contents/Frameworks/libgraphite2.3.dylib"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
cp "$root/Support/Coda.icns" "$app/Contents/Resources/Coda.icns"
cp "$root/Support/CodaPlaceholderCover.png" \
  "$app/Contents/Resources/CodaPlaceholderCover.png"
cp "$root/.build/libmpv/prefix/share/coda/BundledLibraries.txt" \
  "$app/Contents/Resources/Licenses/BundledLibraries.txt"
cp "$root/.build/libmpv/prefix/share/coda/Licenses/"* \
  "$app/Contents/Resources/Licenses/"

git_commit="$(git -C "$root" rev-parse --short=12 HEAD 2>/dev/null || true)"
git_describe="$(git -C "$root" describe --tags --always --dirty 2>/dev/null || true)"
git_tag="$(git -C "$root" describe --tags --exact-match HEAD 2>/dev/null || true)"
git_count="$(git -C "$root" rev-list --count HEAD 2>/dev/null || true)"
build_date="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

[[ -n "$git_commit" ]] || git_commit="unknown"
[[ -n "$git_describe" ]] || git_describe="$git_commit"
[[ -n "$git_count" ]] || git_count="1"

plutil -replace CFBundleVersion -string "$git_count" "$app/Contents/Info.plist"
plutil -insert CodaGitCommit -string "$git_commit" "$app/Contents/Info.plist"
plutil -insert CodaGitDescribe -string "$git_describe" "$app/Contents/Info.plist"
plutil -insert CodaBuildConfiguration -string "$configuration" "$app/Contents/Info.plist"
plutil -insert CodaBuildDate -string "$build_date" "$app/Contents/Info.plist"
if [[ -n "$git_tag" ]]; then
  plutil -insert CodaGitTag -string "$git_tag" "$app/Contents/Info.plist"
fi

chmod 755 "$app/Contents/MacOS/Coda"
chmod 755 "$app/Contents/Frameworks/"*.dylib

signing_identity="$({
  security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" \
    | awk -v name="\"$signing_identity_name\"" '$0 ~ name { print $2; exit }'
} 2>/dev/null)"

if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
  print -u2 "Code-signing identity '$signing_identity_name' was not found."
  print -u2 "Creating an ad-hoc signed local build instead."
fi

for framework in "$app/Contents/Frameworks/"*.dylib; do
  codesign --force --sign "$signing_identity" "$framework"
done

codesign \
  --force \
  --sign "$signing_identity" \
  --identifier "$bundle_identifier" \
  "${entitlement_options[@]}" \
  "$app"
codesign --verify --deep --strict --verbose=2 "$app"

touch "$app"

print "$app"
