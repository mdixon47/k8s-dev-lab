#!/usr/bin/env bash
# Build the API image on the host and import it into containerd on each node
# (no registry needed for local dev). Requires Docker on the host.
set -euo pipefail
IMAGE="devapp/api:dev"
cd "$(dirname "$0")/.."
docker build -t "$IMAGE" app/
docker save "$IMAGE" -o api-image.tar
for node in w1 w2; do
  echo "Importing image into $node..."
  vagrant ssh "$node" -c "sudo ctr -n k8s.io images import /vagrant/api-image.tar"
done
rm -f api-image.tar
echo "Image $IMAGE loaded on all workers."
