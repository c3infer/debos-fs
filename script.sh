#!/bin/sh
set -eux
echo "Installing optional scientific wheel dependencies..."

#export DEBIAN_FRONTEND=noninteractive
# Install python-required libraries

apt-get update
apt-get install -y --no-install-recommends libgl1 ffmpeg build-essential file

# Build rw_ivshmem from overlay source into /root/rw_ivshmem
if [ -f /root/rw_ivshmem.c ]; then
  gcc -O2 -Wall -o /root/rw_ivshmem /root/rw_ivshmem.c
  chmod 0755 /root/rw_ivshmem
  file /root/rw_ivshmem | grep -Eq 'ARM aarch64|ARM64|aarch64' || {
    echo "ERROR: /root/rw_ivshmem is not an AArch64 binary"
    exit 1
  }
else
  echo "ERROR: /root/rw_ivshmem.c was not found in the image"
  exit 1
fi

# # Set autorun.sh script to be running after boot
# cp /root/autorun.service /etc/systemd/system/autorun.service
# systemctl enable autorun.service
