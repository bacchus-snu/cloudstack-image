#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PROFILE=${1:?Usage: deploy.sh a100|gtx1080 DEST}
DEST=${2:?Usage: deploy.sh a100|gtx1080 DEST}
case "$PROFILE" in
  a100)
    DRIVER=615
    DRIVER_FLAVOR=open
    ;;
  gtx1080)
    DRIVER=580
    DRIVER_FLAVOR=proprietary
    ;;
  *)
    echo "Unknown profile: $PROFILE" >&2
    exit 1
    ;;
esac

./build_image.sh \
  --source https://cloud-images.ubuntu.com/releases/resolute/release-20261108/ubuntu-26.04-server-cloudimg-amd64.img \
  --dest "$DEST" \
  --driver "$DRIVER" \
  --driver-flavor "$DRIVER_FLAVOR" \
  --cuda-keyring cuda-keyring_1.1-1_all.deb \
  --dcgm-exporter 4.8.4.3955-1 \
  --vmagent v1.156.0
