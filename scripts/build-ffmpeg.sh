#!/bin/bash
#
# Builds a universal (arm64 + x86_64), static, LGPL ffmpeg and ffprobe that only
# link frameworks shipped with macOS. Run from a folder holding the FFmpeg
# source tarball; scripts/setup-tools.sh does this for you.
set -e
B="$(pwd)"
TARBALL="${FFMPEG_TARBALL:-ffmpeg-7.1.2.tar.xz}"
[ -d src ] || { mkdir src && tar xf "$TARBALL" -C src --strip-components 1; }
for ARCH in arm64 x86_64; do
  rm -rf "build-$ARCH"; cp -R src "build-$ARCH"; cd "build-$ARCH"
  EXTRA=""
  [ "$ARCH" = "x86_64" ] && EXTRA="--enable-cross-compile --disable-x86asm"
  ./configure --prefix="$B/out-$ARCH" --arch=$ARCH --target-os=darwin \
    --cc="clang -arch $ARCH" $EXTRA \
    --extra-cflags="-mmacosx-version-min=26.0" --extra-ldflags="-mmacosx-version-min=26.0" \
    --enable-static --disable-shared --disable-debug --disable-doc --disable-ffplay \
    --disable-autodetect --enable-audiotoolbox --enable-videotoolbox --enable-securetransport \
    --enable-zlib --enable-bzlib --enable-iconv --pkg-config=false --extra-libs="-liconv" \
    > "$B/configure-$ARCH.log" 2>&1
  make -j"$(sysctl -n hw.ncpu)" > "$B/make-$ARCH.log" 2>&1
  make install > /dev/null 2>&1
  cd "$B"
done
mkdir -p universal
lipo -create out-arm64/bin/ffmpeg out-x86_64/bin/ffmpeg -output universal/ffmpeg
lipo -create out-arm64/bin/ffprobe out-x86_64/bin/ffprobe -output universal/ffprobe
echo BUILD-DONE
