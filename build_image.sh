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
ROOT_DIR="$WORK_DIR/root"
LOOP_DEVICE=
cleanup() {
  if mountpoint -q "$ROOT_DIR"; then
    umount -R "$ROOT_DIR"
  fi
  if [[ -n $LOOP_DEVICE ]]; then
    losetup --detach "$LOOP_DEVICE"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
cd "$WORK_DIR"

VMUTILS="vmutils-linux-amd64-$VMAGENT_VERSION"
VMUTILS_URL="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/$VMAGENT_VERSION"

wget --no-verbose -O "$IMG_NAME" "$SOURCE"
wget --no-verbose -O SHA256SUMS "$BASE_URL/SHA256SUMS"
awk -v name="$IMG_NAME" '$2 == name || $2 == "*" name { print; found=1 } END { if (!found) exit 1 }' SHA256SUMS >source.sha256
sha256sum -c source.sha256

wget --no-verbose -O cuda-keyring.deb "$CUDA_REPO/$CUDA_KEYRING"
wget --no-verbose -O "$VMUTILS.tar.gz" "$VMUTILS_URL/$VMUTILS.tar.gz"
wget --no-verbose -O "${VMUTILS}_checksums.txt" "$VMUTILS_URL/${VMUTILS}_checksums.txt"
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

qemu-img convert -f qcow2 -O raw "$IMG_NAME" work.raw
rm "$IMG_NAME"
qemu-img resize -f raw work.raw 16G
LOOP_DEVICE=$(losetup --find --show --partscan "$WORK_DIR/work.raw")
udevadm settle --timeout=30
growpart "$LOOP_DEVICE" 1
udevadm settle --timeout=30
BOOT_DEVICE=$(lsblk --raw --noheadings --paths --output NAME,LABEL "$LOOP_DEVICE" | awk '$2 == "BOOT" {print $1}')
EFI_DEVICE=$(lsblk --raw --noheadings --paths --output NAME,LABEL "$LOOP_DEVICE" | awk '$2 == "UEFI" {print $1}')
: "${BOOT_DEVICE:?Image must contain a BOOT partition}"
: "${EFI_DEVICE:?Image must contain a UEFI partition}"

mkdir "$ROOT_DIR"
mount "${LOOP_DEVICE}p1" "$ROOT_DIR"
resize2fs "${LOOP_DEVICE}p1"
mount "$BOOT_DEVICE" "$ROOT_DIR/boot"
mount "$EFI_DEVICE" "$ROOT_DIR/boot/efi"
mount --rbind /dev "$ROOT_DIR/dev"
mount --make-rslave "$ROOT_DIR/dev"
mount -t proc proc "$ROOT_DIR/proc"
mount -t sysfs sysfs "$ROOT_DIR/sys"
cp -a "$ROOT_DIR/etc/resolv.conf" resolv.conf
rm "$ROOT_DIR/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT_DIR/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' >"$ROOT_DIR/usr/sbin/policy-rc.d"
chmod 755 "$ROOT_DIR/usr/sbin/policy-rc.d"

export DEBIAN_FRONTEND=noninteractive SYSTEMD_OFFLINE=1
chroot "$ROOT_DIR" apt-get update --error-on=any
chroot "$ROOT_DIR" apt-get install -y --no-install-recommends \
  "linux-modules-nvidia-${DRIVER}-server${DRIVER_SUFFIX}-generic" \
  "nvidia-headless-no-dkms-${DRIVER}-server${DRIVER_SUFFIX}" \
  "nvidia-utils-${DRIVER}-server"
install -m 644 cuda-keyring.deb "$ROOT_DIR/tmp/cuda-keyring.deb"
chroot "$ROOT_DIR" dpkg -i /tmp/cuda-keyring.deb
rm "$ROOT_DIR/tmp/cuda-keyring.deb"
chroot "$ROOT_DIR" apt-get update --error-on=any
chroot "$ROOT_DIR" apt-get install -y --no-install-recommends \
  datacenter-gpu-manager-4-core datacenter-gpu-manager-4-proprietary \
  "datacenter-gpu-manager-exporter=$DCGM_EXPORTER_VERSION"
chroot "$ROOT_DIR" apt-mark hold datacenter-gpu-manager-exporter
install -m 755 vmagent-prod "$ROOT_DIR/usr/local/bin/vmagent"
mkdir -p "$ROOT_DIR/etc/vmagent"
printf '%s' "$VMAGENT_SCRAPE" >"$ROOT_DIR/etc/vmagent/scrape.yml"
printf '%s' "$VMAGENT_UNIT" >"$ROOT_DIR/etc/systemd/system/vmagent.service"
chroot "$ROOT_DIR" useradd --system --no-create-home --shell /usr/sbin/nologin vmagent
chroot "$ROOT_DIR" systemctl enable nvidia-dcgm.service nvidia-dcgm-exporter.service vmagent.service
chroot "$ROOT_DIR" apt-get clean
chroot "$ROOT_DIR" cloud-init clean --logs
truncate -s 0 "$ROOT_DIR/etc/machine-id"
rm "$ROOT_DIR/usr/sbin/policy-rc.d" "$ROOT_DIR/etc/resolv.conf"
cp -a resolv.conf "$ROOT_DIR/etc/resolv.conf"
fstrim "$ROOT_DIR"
umount -R "$ROOT_DIR"
losetup --detach "$LOOP_DEVICE"
LOOP_DEVICE=

qemu-img convert -f raw -O qcow2 -c work.raw "$DEST"
qemu-img check "$DEST"
cd "$(dirname "$DEST")"
sha256sum "$(basename "$DEST")" >"$DEST.sha256"
