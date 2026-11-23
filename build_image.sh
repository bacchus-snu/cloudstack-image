#!/usr/bin/env bash
set -euo pipefail

CUDA_KEYRING=cuda-keyring_1.1-1_all.deb
DCGM_EXPORTER_VERSION=4.8.4.3955-1
VMAGENT_VERSION=v1.156.0
DRIVER_FLAVOR=open

while (($#)); do
  case "$1" in
    --source)
      SOURCE="$2"
      shift 2
      ;;
    --dest)
      DEST="$2"
      shift 2
      ;;
    --driver)
      DRIVER="$2"
      shift 2
      ;;
    --driver-flavor)
      DRIVER_FLAVOR="$2"
      shift 2
      ;;
    --cuda-repo)
      CUDA_REPO="$2"
      shift 2
      ;;
    --cuda-keyring)
      CUDA_KEYRING="$2"
      shift 2
      ;;
    --dcgm-exporter)
      DCGM_EXPORTER_VERSION="$2"
      shift 2
      ;;
    --vmagent)
      VMAGENT_VERSION="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

: "${SOURCE:?--source is required}"
: "${DEST:?--dest is required}"
: "${DRIVER:?--driver is required}"

if ((EUID != 0)); then
  echo "Run this script as root." >&2
  exit 1
fi

case "$DRIVER_FLAVOR" in
  open) DRIVER_SUFFIX=-open ;;
  proprietary) DRIVER_SUFFIX= ;;
  *)
    echo "--driver-flavor must be open or proprietary" >&2
    exit 1
    ;;
esac

BASE_URL="${SOURCE%/*}"
IMG_NAME="${SOURCE##*/}"
if [[ -z ${CUDA_REPO:-} ]]; then
  if [[ ! $IMG_NAME =~ ubuntu-([0-9]+)\.([0-9]+) ]]; then
    echo "Cannot determine the Ubuntu version from $IMG_NAME; pass --cuda-repo." >&2
    exit 1
  fi
  CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${BASH_REMATCH[1]}${BASH_REMATCH[2]}/x86_64"
fi

DEST=$(realpath -m "$DEST")
mkdir -p "$(dirname "$DEST")"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

VMUTILS="vmutils-linux-amd64-$VMAGENT_VERSION"
VMUTILS_URL="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/$VMAGENT_VERSION"

wget -O "$IMG_NAME" "$SOURCE"
wget -O SHA256SUMS "$BASE_URL/SHA256SUMS"
awk -v name="$IMG_NAME" '$2 == name || $2 == "*" name { print; found=1 } END { if (!found) exit 1 }' SHA256SUMS >source.sha256
sha256sum -c source.sha256

wget -O cuda-keyring.deb "$CUDA_REPO/$CUDA_KEYRING"
wget -O "$VMUTILS.tar.gz" "$VMUTILS_URL/$VMUTILS.tar.gz"
wget -O "${VMUTILS}_checksums.txt" "$VMUTILS_URL/${VMUTILS}_checksums.txt"
awk -v name="$VMUTILS.tar.gz" '$2 == name || $2 == "*" name { print; found=1 } END { if (!found) exit 1 }' "${VMUTILS}_checksums.txt" >vmutils.sha256
sha256sum -c vmutils.sha256
tar -xzf "$VMUTILS.tar.gz" --no-same-owner vmagent-prod

VMAGENT_SCRAPE='global:
  scrape_interval: 30s
scrape_configs:
  - job_name: dcgm-exporter
    static_configs:
      - targets: [localhost:9400]
'
# shellcheck disable=SC2016
VMAGENT_UNIT='[Unit]
Description=vmagent
Wants=network-online.target
After=network-online.target nvidia-dcgm-exporter.service
ConditionPathExists=/etc/default/vmagent

[Service]
User=vmagent
EnvironmentFile=/etc/default/vmagent
ExecStart=/usr/local/bin/vmagent -promscrape.config=/etc/vmagent/scrape.yml -remoteWrite.tmpDataPath=/var/lib/vmagent -httpListenAddr=127.0.0.1:8429 $VMAGENT_ARGS
StateDirectory=vmagent
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
'

export LIBGUESTFS_BACKEND=direct
qemu-img resize "$IMG_NAME" 16G
virt-customize --verbose --memsize 4096 --smp 2 -a "$IMG_NAME" \
  --run-command 'growpart /dev/sda 1 && resize2fs /dev/sda1' \
  --run-command 'apt-get update' \
  --run-command "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends linux-modules-nvidia-${DRIVER}-server${DRIVER_SUFFIX}-generic nvidia-headless-no-dkms-${DRIVER}-server${DRIVER_SUFFIX} nvidia-utils-${DRIVER}-server" \
  --upload cuda-keyring.deb:/tmp/cuda-keyring.deb \
  --run-command 'dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb && apt-get update' \
  --run-command "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends datacenter-gpu-manager-4-core datacenter-gpu-manager-4-proprietary datacenter-gpu-manager-exporter=${DCGM_EXPORTER_VERSION} && apt-mark hold datacenter-gpu-manager-exporter" \
  --upload vmagent-prod:/usr/local/bin/vmagent \
  --mkdir /etc/vmagent \
  --write "/etc/vmagent/scrape.yml:$VMAGENT_SCRAPE" \
  --write "/etc/systemd/system/vmagent.service:$VMAGENT_UNIT" \
  --run-command 'useradd --system --no-create-home --shell /usr/sbin/nologin vmagent' \
  --run-command 'systemctl enable nvidia-dcgm.service nvidia-dcgm-exporter.service vmagent.service' \
  --run-command 'apt-get clean && cloud-init clean --logs' \
  --truncate /etc/machine-id

TMPDIR="$WORK_DIR" virt-sparsify --memsize 4096 --compress --convert qcow2 "$IMG_NAME" "$DEST"
qemu-img check "$DEST"
cd "$(dirname "$DEST")"
sha256sum "$(basename "$DEST")" >"$DEST.sha256"
