#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
plist="$root/Support/Info.plist"
app="$root/.build/Coda.app"
signing_identity_name="${CODA_SIGNING_IDENTITY:-Coda Local Development}"

usage() {
  print -u2 "Usage: ${0:t} [X.Y.Z]"
}

if (( $# > 1 )); then
  usage
  exit 2
fi

plist_version="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$plist")"
version="${1:-$plist_version}"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "Release version must use X.Y.Z format: $version"
  exit 2
fi

if [[ "$version" != "$plist_version" ]]; then
  print -u2 "Requested version $version does not match Info.plist $plist_version."
  exit 1
fi

tag="v$version"
head="$(git -C "$root" rev-parse HEAD)"
short_head="$(git -C "$root" rev-parse --short=12 HEAD)"

if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  print -u2 "Release packaging requires a clean working tree."
  exit 1
fi

if ! git -C "$root" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  print -u2 "Release tag $tag does not exist."
  exit 1
fi

if [[ "$(git -C "$root" cat-file -t "$tag")" != "tag" ]]; then
  print -u2 "Release tag $tag must be annotated."
  exit 1
fi

if [[ "$(git -C "$root" rev-list -n 1 "$tag")" != "$head" ]]; then
  print -u2 "Release tag $tag does not point to HEAD."
  exit 1
fi

signing_identity="$({
  security find-identity -v -p codesigning \
    "$HOME/Library/Keychains/login.keychain-db" \
    | awk -v name="\"$signing_identity_name\"" '$0 ~ name { print $2; exit }'
} 2>/dev/null)"

if [[ -z "$signing_identity" ]]; then
  print -u2 "Release signing identity '$signing_identity_name' was not found."
  print -u2 "Refusing to package an ad-hoc-signed public release."
  exit 1
fi

swift test --package-path "$root"
"$root/scripts/build-app.sh" release

bundle_version="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
bundle_commit="$(/usr/libexec/PlistBuddy \
  -c 'Print :CodaGitCommit' "$app/Contents/Info.plist")"
bundle_describe="$(/usr/libexec/PlistBuddy \
  -c 'Print :CodaGitDescribe' "$app/Contents/Info.plist")"
bundle_tag="$(/usr/libexec/PlistBuddy \
  -c 'Print :CodaGitTag' "$app/Contents/Info.plist")"
bundle_configuration="$(/usr/libexec/PlistBuddy \
  -c 'Print :CodaBuildConfiguration' "$app/Contents/Info.plist")"

[[ "$bundle_version" == "$version" ]] || {
  print -u2 "Built app version is $bundle_version, expected $version."
  exit 1
}
[[ "$bundle_commit" == "$short_head" ]] || {
  print -u2 "Built app commit is $bundle_commit, expected $short_head."
  exit 1
}
[[ "$bundle_describe" == "$tag" ]] || {
  print -u2 "Built app describes itself as $bundle_describe, expected $tag."
  exit 1
}
[[ "$bundle_tag" == "$tag" ]] || {
  print -u2 "Built app tag is $bundle_tag, expected $tag."
  exit 1
}
[[ "$bundle_configuration" == "release" ]] || {
  print -u2 "Built app configuration is $bundle_configuration, expected release."
  exit 1
}

if [[ "$(lipo -archs "$app/Contents/MacOS/Coda")" != "arm64" ]]; then
  print -u2 "Release executable is not arm64-only."
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app"
signature_details="$(codesign -dvvv "$app" 2>&1)"
if [[ "$signature_details" != *"Authority=$signing_identity_name"* ]]; then
  print -u2 "Built app was not signed by '$signing_identity_name'."
  exit 1
fi

release_directory="$root/.build/releases/$tag"
archive_name="Coda-$version-macOS-arm64.zip"
checksum_name="$archive_name.sha256"
archive="$release_directory/$archive_name"
checksum="$release_directory/$checksum_name"

mkdir -p "$release_directory"
if [[ -e "$archive" || -e "$checksum" ]]; then
  print -u2 "Release artifacts already exist in $release_directory."
  print -u2 "Move or remove them deliberately before packaging again."
  exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(
  cd "$release_directory"
  shasum -a 256 "$archive_name" > "$checksum_name"
  shasum -a 256 -c "$checksum_name"
)
unzip -tq "$archive"

print "Release artifacts:"
print "$archive"
print "$checksum"
