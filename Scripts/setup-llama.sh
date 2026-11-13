#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/fetch-verified.sh
umask 077

directory=vendor/llama.cpp
archive="$directory/llama-b12038-xcframework.zip"
framework="$directory/build-apple/llama.xcframework"
mkdir -p "$(dirname "$framework")"
fetch_verified 'https://github.com/ggml-org/llama.cpp/releases/download/b12038/llama-b12038-xcframework.zip' \
  "$archive" 484ea8b06c2c41e37d3ea8c2d456d16c2fe62bf9987f0c609dd9443b3f6b89e3

if [ ! -d "$framework" ]; then
  staging=$(mktemp -d "$directory/.unpack.XXXXXX")
  trap 'rm -rf "$staging"' EXIT
  unzip -q "$archive" -d "$staging"
  mv "$staging/build-apple/llama.xcframework" "$framework"
fi
printf 'Ready: llama.cpp b12038 XCFramework.\n'
