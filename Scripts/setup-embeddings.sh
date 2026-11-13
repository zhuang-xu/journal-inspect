#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/fetch-verified.sh
umask 077
mkdir -p Models
chmod 700 Models

fetch_verified 'https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/370f27d7550e0def9b39c1f16d3fbaa13aa67728/Qwen3-Embedding-0.6B-Q8_0.gguf' \
  Models/Qwen3-Embedding-0.6B-Q8_0.gguf \
  06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439
printf 'Verified Qwen3-Embedding-0.6B Q8_0.\n'
