#!/bin/bash
# Pinned, portable constant-time AES for the SWEET legacy CBC/ECB API.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f libkern/crypto/corecrypto_aes.c ]] || exit 1

bearssl_sha=7bea48e5e850ab4cafbe68d3765cdaba13a86d6f
bearssl_url="https://www.bearssl.org/git/BearSSL"

bearssl_tmp=$(mktemp -d)
trap 'rm -rf "$bearssl_tmp"' EXIT

echo "Fetching BearSSL commit: $bearssl_sha"

# Retry temporary network/server failures.
downloaded=false

for attempt in 1 2 3 4 5; do
    echo "BearSSL download attempt $attempt/5"

    rm -rf "$bearssl_tmp"
    mkdir -p "$bearssl_tmp"

    if git init -q "$bearssl_tmp" &&
       git -C "$bearssl_tmp" -c http.version=HTTP/1.1 \
         fetch -q --depth 1 "$bearssl_url" "$bearssl_sha"; then
        downloaded=true
        break
    fi

    if [ "$attempt" -lt 5 ]; then
        delay=$((attempt * 10))
        echo "Download failed. Retrying in ${delay}s..."
        sleep "$delay"
    fi
done

if [ "$downloaded" != true ]; then
    echo "ERROR: Unable to download BearSSL after 5 attempts."
    exit 1
fi

git -C "$bearssl_tmp" checkout -q FETCH_HEAD

actual_sha=$(git -C "$bearssl_tmp" rev-parse HEAD)

if [[ "$actual_sha" != "$bearssl_sha" ]]; then
    echo "ERROR: BearSSL commit mismatch!"
    echo "Expected: $bearssl_sha"
    echo "Actual:   $actual_sha"
    exit 1
fi

echo "Verified BearSSL commit: $actual_sha"

python3 - "$bearssl_tmp" <<'PY'
from pathlib import Path
import shutil
import sys

source = Path(sys.argv[1])
target = Path('libkern/crypto/sweet_bearssl')

if target.exists():
    raise SystemExit(f'refusing to overwrite existing AES source: {target}')

shutil.copytree(source / 'inc', target / 'inc')
(target / 'src/symcipher').mkdir(parents=True)

for file in ('inner.h', 'config.h'):
    shutil.copy2(source / 'src' / file, target / 'src' / file)

# XNU exports machine/limits.h instead of the userspace limits.h.
header = target / 'src/inner.h'
text = header.read_text()

assert text.count('#include <limits.h>') == 1

header.write_text(text.replace(
    '#include <limits.h>',
    '#if defined(KERNEL)\n'
    '#include <machine/limits.h>\n'
    '#else\n'
    '#include <limits.h>\n'
    '#endif'
))

for name in (
    'aes_ct',
    'aes_ct_enc',
    'aes_ct_dec',
    'aes_ct_cbcenc',
    'aes_ct_cbcdec'
):
    shutil.copy2(
        source / 'src/symcipher' / (name + '.c'),
        target / 'src/symcipher' / (name + '.c')
    )

# MD5, SHA-1 and SHA-384/512 for the legacy hash APIs, with their codecs.
for name in (
    'hash/md5.c',
    'codec/dec32le.c',
    'codec/enc32le.c',
    'hash/sha1.c',
    'codec/dec32be.c',
    'codec/enc32be.c',
    'hash/sha2big.c',
    'codec/dec64be.c',
    'codec/enc64be.c'
):
    (target / 'src' / name).parent.mkdir(
        parents=True,
        exist_ok=True
    )

    shutil.copy2(
        source / 'src' / name,
        target / 'src' / name
    )

shutil.copy2(
    source / 'LICENSE.txt',
    target / 'LICENSE.txt'
)

print("BearSSL source files staged successfully.")
PY

echo "Staged BearSSL portable AES, MD5, SHA-1 and SHA-384/512 ($bearssl_sha) for SWEET"
