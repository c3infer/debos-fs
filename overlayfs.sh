#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

./overlay-into-artifact.sh \
  --overlay ./overlay \
  --dest / \
  --artifact ./out/rootfs.img \
  --pre-script ./recompile-rw_ivshmem.sh \
  "$@"
