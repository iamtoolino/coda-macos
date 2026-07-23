#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
work="$root/.build/libmpv"
downloads="$work/downloads"
sources="$work/sources"
prefix="$work/prefix"
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || print 8)"

ffmpeg_version="8.1.2"
ffmpeg_sha="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
libass_version="0.17.5"
libass_sha="2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc"
libplacebo_version="7.360.1"
libplacebo_sha="937aa5eeea596798b3274d362de2e3bd32bc537a66d149dd85043349c74dffb6"
mpv_version="0.41.0"
mpv_sha="ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209"

mkdir -p "$downloads" "$sources" "$prefix"

fetch() {
  local url="$1"
  local output="$2"
  local expected_sha="$3"
  if [[ ! -f "$output" ]]; then
    curl --fail --location --retry 3 --output "$output" "$url"
  fi
  local actual_sha="$(shasum -a 256 "$output" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    print -u2 "Checksum mismatch for ${output:t}"
    exit 1
  fi
}

fetch \
  "https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz" \
  "$downloads/ffmpeg-${ffmpeg_version}.tar.xz" \
  "$ffmpeg_sha"
fetch \
  "https://github.com/libass/libass/releases/download/${libass_version}/libass-${libass_version}.tar.xz" \
  "$downloads/libass-${libass_version}.tar.xz" \
  "$libass_sha"
fetch \
  "https://code.videolan.org/videolan/libplacebo/-/archive/v${libplacebo_version}/libplacebo-v${libplacebo_version}.tar.bz2" \
  "$downloads/libplacebo-${libplacebo_version}.tar.bz2" \
  "$libplacebo_sha"
fetch \
  "https://github.com/mpv-player/mpv/archive/refs/tags/v${mpv_version}.tar.gz" \
  "$downloads/mpv-${mpv_version}.tar.gz" \
  "$mpv_sha"

if [[ ! -d "$sources/ffmpeg-${ffmpeg_version}" ]]; then
  tar -xf "$downloads/ffmpeg-${ffmpeg_version}.tar.xz" -C "$sources"
fi
if [[ ! -d "$sources/libass-${libass_version}" ]]; then
  tar -xf "$downloads/libass-${libass_version}.tar.xz" -C "$sources"
fi
if [[ ! -d "$sources/libplacebo-v${libplacebo_version}" ]]; then
  tar -xf "$downloads/libplacebo-${libplacebo_version}.tar.bz2" -C "$sources"
fi
if [[ ! -d "$sources/mpv-${mpv_version}" ]]; then
  tar -xf "$downloads/mpv-${mpv_version}.tar.gz" -C "$sources"
fi

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"
export MACOSX_DEPLOYMENT_TARGET="26.0"
export PYTHONPATH="$work/python${PYTHONPATH:+:$PYTHONPATH}"

meson_python="$(head -1 "$(command -v meson)" | sed 's/^#!//')"
if ! "$meson_python" -c 'import jinja2' 2>/dev/null; then
  "$meson_python" -m pip install \
    --disable-pip-version-check \
    --target "$work/python" \
    "jinja2==3.1.6" \
    "MarkupSafe==3.0.3"
fi

if [[ ! -f "$prefix/lib/libavcodec.a" ]]; then
  ffmpeg_build="$work/build-ffmpeg"
  rm -rf "$ffmpeg_build"
  mkdir -p "$ffmpeg_build"
  cd "$ffmpeg_build"
  "$sources/ffmpeg-${ffmpeg_version}/configure" \
    --prefix="$prefix" \
    --cc=clang \
    --disable-autodetect \
    --disable-gpl \
    --disable-nonfree \
    --disable-version3 \
    --disable-shared \
    --enable-static \
    --enable-pic \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-avdevice \
    --enable-network \
    --enable-securetransport \
    --enable-iconv \
    --enable-zlib \
    --enable-bzlib
  make -j "$jobs"
  make install
fi

if [[ ! -f "$prefix/lib/libass.a" ]]; then
  libass_build="$work/build-libass"
  rm -rf "$libass_build"
  mkdir -p "$libass_build"
  cd "$libass_build"
  "$sources/libass-${libass_version}/configure" \
    --prefix="$prefix" \
    --disable-shared \
    --enable-static \
    --disable-fontconfig \
    --disable-require-system-font-provider
  make -j "$jobs"
  make install
fi

if [[ ! -f "$prefix/lib/libplacebo.a" ]]; then
  libplacebo_build="$work/build-libplacebo"
  rm -rf "$libplacebo_build"
  meson setup "$libplacebo_build" "$sources/libplacebo-v${libplacebo_version}" \
    --prefix="$prefix" \
    --default-library=static \
    --buildtype=release \
    -Ddemos=false \
    -Dtests=false \
    -Dvulkan=disabled \
    -Dshaderc=disabled \
    -Dd3d11=disabled \
    -Dlcms=disabled \
    -Dopengl=disabled \
    -Ddovi=disabled \
    -Dxxhash=disabled
  meson compile -C "$libplacebo_build"
  meson install -C "$libplacebo_build"
fi

libmpv="$prefix/lib/libmpv.2.dylib"
if [[ ! -f "$libmpv" || "${CODA_REBUILD_LIBMPV:-0}" == "1" ]]; then
  mpv_build="$work/build-mpv"
  rm -rf "$mpv_build"
  PKG_CONFIG_ALL_STATIC=1 meson setup "$mpv_build" "$sources/mpv-${mpv_version}" \
  --prefix="$prefix" \
  --buildtype=release \
  --default-library=shared \
  --prefer-static \
  --auto-features=disabled \
  -Dgpl=false \
  -Dcplayer=false \
  -Dlibmpv=true \
  -Dbuild-date=false \
  -Dlua=disabled \
  -Dcoreaudio=enabled \
  -Diconv=disabled \
  -Dzlib=enabled \
  -Dgl=disabled \
  -Dcocoa=disabled \
  -Davfoundation=disabled \
  -Dmacos-cocoa-cb=disabled \
  -Dswift-build=disabled \
  -Dmacos-media-player=disabled \
    -Dmacos-touchbar=disabled
  meson compile -C "$mpv_build"
  meson install -C "$mpv_build"
fi

graphite_source="/opt/homebrew/opt/graphite2/lib/libgraphite2.3.dylib"
graphite="$prefix/lib/libgraphite2.3.dylib"
if [[ ! -f "$graphite" ]]; then
  cp "$graphite_source" "$graphite"
  chmod u+w "$graphite"
fi
install_name_tool -id "@rpath/libgraphite2.3.dylib" "$graphite"
install_name_tool -id "@rpath/libmpv.2.dylib" "$libmpv"
install_name_tool \
  -change "$graphite_source" "@rpath/libgraphite2.3.dylib" \
  "$libmpv"
codesign --force --sign - "$graphite"
codesign --force --sign - "$libmpv"

print "Built $libmpv"
otool -L "$libmpv"
