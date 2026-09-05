#!/usr/bin/env bash
# Build the lab images on the host and import them into containerd on each worker
# (no registry needed for local dev). Requires Docker on the host.
# Usage: load-image.sh [api|web ...]   (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."
WORKERS="${WORKERS:-w1 w2}"
# macOS ships bash 3.2 (no associative arrays), so map names with a case
context_for() { case "$1" in api) echo app ;; web) echo web ;; *) echo "unknown image: $1" >&2; exit 1 ;; esac; }
targets=("$@"); [ ${#targets[@]} -eq 0 ] && targets=(api web)

for t in "${targets[@]}"; do
  image="devapp/$t:dev"; ctx="$(context_for "$t")"
  echo "== Building $image from $ctx/"
  docker build -q -t "$image" "$ctx/" >/dev/null
  docker save "$image" -o "$t-image.tar"
  for node in $WORKERS; do
    echo "   importing into $node..."
    vagrant ssh "$node" -c "sudo ctr -n k8s.io images import /vagrant/$t-image.tar" >/dev/null
  done
  rm -f "$t-image.tar"
  echo "   $image loaded on: $WORKERS"
done
echo "Done. Pods only pick up a reloaded image after: kubectl -n devapp rollout restart deployment/<name>"
