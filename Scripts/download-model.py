#!/usr/bin/env python3
"""Setup-only bounded/resumable download; never used by the Swift application."""
import concurrent.futures
import hashlib
import fcntl
import os
from pathlib import Path
import re
import subprocess
import sys

url, raw_size, checksum, target_path = sys.argv[1:]
size = int(raw_size)
target = Path(target_path)
os.umask(0o077)
lock = target.with_suffix(target.suffix + '.download.lock').open('w')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('Another download of this model is already running')
chunks = target.parent / ('.' + target.name + '.chunks')
chunks.mkdir(mode=0o700, parents=True, exist_ok=True)
chunk_size = 8 * 1024 * 1024

def fetch(index):
    start = index * chunk_size
    end = min(size, start + chunk_size) - 1
    part = chunks / f'{index:05d}'
    if part.exists() and part.stat().st_size == end - start + 1:
        return index
    temporary = part.with_suffix('.partial')
    headers = part.with_suffix('.headers')
    for attempt in range(5):
        result = subprocess.run([
            'curl', '-fsSL', '--connect-timeout', '15', '--max-time', '60',
            '--range', f'{start}-{end}', '--max-filesize', str(chunk_size),
            '-D', str(headers), '-o', str(temporary),
            url + f'?download=true&chunk={index}',
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ranges = re.findall(r'content-range:\s*bytes\s+(\d+)-(\d+)/(\d+)',
                            headers.read_text().lower() if headers.exists() else '')
        if (result.returncode == 0 and ranges and ranges[-1] == (str(start), str(end), str(size))
                and temporary.is_file() and temporary.stat().st_size == end - start + 1):
            temporary.replace(part)
            return index
    raise RuntimeError(f'Chunk {index} could not be downloaded and range-validated')

count = (size + chunk_size - 1) // chunk_size
with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
    for done, _ in enumerate(pool.map(fetch, range(count)), 1):
        if done % 32 == 0 or done == count:
            print(f'Downloaded {done}/{count} verified ranges', flush=True)

partial = target.with_suffix(target.suffix + '.partial')
digest = hashlib.sha256()
with partial.open('wb') as output:
    for index in range(count):
        with (chunks / f'{index:05d}').open('rb') as stream:
            while block := stream.read(1024 * 1024):
                digest.update(block)
                output.write(block)
    output.flush()
    os.fsync(output.fileno())
if partial.stat().st_size != size or digest.hexdigest() != checksum:
    raise RuntimeError('Downloaded model failed exact size/SHA-256 verification')
partial.replace(target)
os.chmod(target, 0o600)
for path in chunks.iterdir():
    path.unlink()
chunks.rmdir()
print('Model size and SHA-256 verified.', flush=True)
