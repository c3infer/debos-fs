#!/bin/sh
set -x
echo "Installing optional scientific wheel dependencies..."

#export DEBIAN_FRONTEND=noninteractive
# Install python-required libraries

apt-get update
apt-get install -y --no-install-recommends libgl1 ffmpeg

# Set autorun.sh script to be running after boot
cp /root/autorun.service /etc/systemd/system/autorun.service
systemctl enable autorun.service
