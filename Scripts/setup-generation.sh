#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p Models
chmod 700 Models
model='Models/Qwen_Qwen3-4B-Instruct-2507-Q5_K_M.gguf'
checksum='66713ce35a58a82fe87642d4ec13425bf9b9a46800fff5c49a665ef5701439dc'
url='https://huggingface.co/bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF/resolve/ae44f08e1392f39c0e474af10c3ff8355c8b6688/Qwen_Qwen3-4B-Instruct-2507-Q5_K_M.gguf'
if [ ! -f "$model" ] || ! echo "$checksum  $model" | shasum -a 256 -c - >/dev/null 2>&1; then
  python3 Scripts/download-model.py "$url" 2889513696 "$checksum" "$model"
fi
chmod 600 "$model"
printf 'Verified local Qwen3-4B-Instruct-2507 Q5_K_M model.\n'
