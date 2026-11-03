#!/bin/bash
# Publishes the patches without a new app: raises the patch set number (patches/VERSION) and rewrites the list (patches/index.txt).
# Then commit patches/ and push to main; every NxNative Builder checks that page and offers the newer set (Patches > Check for newer patches).
set -euo pipefail
cd "$(dirname "$0")/patches"
v=$(( $(cat VERSION 2>/dev/null || echo 0) + 1 ))
echo "$v" > VERSION
ls *.patch > index.txt
echo "Patch set $v: $(wc -l < index.txt | tr -d ' ') patch(es). Commit patches/ and push to main to publish it."
