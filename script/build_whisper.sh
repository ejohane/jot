#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source_dir="${JOT_WHISPER_SOURCE:-.build/jot-whisper-source}"
cmake="${JOT_CMAKE:-cmake}"
revision=927cfce34f31707e17f2bff35c349632fb9e2c3a
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --depth 1 --branch v1.9.4 https://github.com/ggml-org/whisper.cpp.git "$source_dir"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$revision" ]] || {
  echo 'Unexpected whisper.cpp revision' >&2
  exit 1
}

architectures=(arm64)
if [[ "${JOT_UNIVERSAL:-0}" == 1 ]]; then architectures+=(x86_64); fi
for arch in "${architectures[@]}"; do
  metal=OFF
  if [[ "$arch" == arm64 ]]; then metal=ON; fi
  build_dir=".build/jot-whisper-$arch"
  "$cmake" -S "$source_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL="$metal" \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF
  "$cmake" --build "$build_dir" --target whisper-cli --parallel 4
  cp "$build_dir/bin/whisper-cli" "dist/jot-whisper-$arch"
done
if [[ "${JOT_UNIVERSAL:-0}" == 1 ]]; then
  lipo -create dist/jot-whisper-arm64 dist/jot-whisper-x86_64 -output dist/jot-whisper-binary
else
  cp dist/jot-whisper-arm64 dist/jot-whisper-binary
fi
cp "$source_dir/LICENSE" dist/whisper.cpp-LICENSE
