#!/bin/sh
set -eu

# ---- configurable via Debos -e VAR:VALUE (or defaults here) ----
USERNAME="${USERNAME:-netsys}"          # user to autologin
PASSWORD="${PASSWORD:-}"              # if empty: no password set
CONSOLE="${CONSOLE:-ttyAMA0}"         # e.g. ttyAMA0 (aarch64 virt) or ttyS0
SUDO_NOPASS="${SUDO_NOPASS:-1}"       # 1 = passwordless sudo for %sudo

echo "[setup] user=$USERNAME console=$CONSOLE sudo_nopass=$SUDO_NOPASS"

# Ensure groups exist (idempotent)
getent group sudo  >/dev/null || groupadd sudo
getent group users >/dev/null || groupadd users

# Create user if missing; set password if provided
if ! id -u "$USERNAME" >/dev/null 2>&1; then
  adduser --gecos "$USERNAME" --disabled-password --shell /bin/bash "$USERNAME"
fi
if [ -n "$PASSWORD" ]; then
  echo "$USERNAME:$PASSWORD" | chpasswd
fi

# Add to common groups (ignore if already a member)
for g in sudo users video render input audio; do
  adduser "$USERNAME" "$g" 2>/dev/null || true
done

# Optional: passwordless sudo for %sudo (applies when sudo package is present)
if [ "$SUDO_NOPASS" = "1" ]; then
  install -d -m 0750 /etc/sudoers.d
  printf '%s\n' '%sudo ALL=(ALL:ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-nopasswd-sudo
  chmod 0440 /etc/sudoers.d/99-nopasswd-sudo
fi

# Create systemd drop-in to autologin USERNAME on selected serial
install -d "/etc/systemd/system/serial-getty@${CONSOLE}.service.d"
cat > "/etc/systemd/system/serial-getty@${CONSOLE}.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${USERNAME} --noclear %I \$TERM
Type=simple
EOF

# OFFLINE enable: make the wants/ symlink instead of calling systemctl
# Debian's unit files live under /lib/systemd/system
install -d /etc/systemd/system/getty.target.wants
ln -sf "/lib/systemd/system/serial-getty@.service" \
       "/etc/systemd/system/getty.target.wants/serial-getty@${CONSOLE}.service"

# Make sure machine-id placeholder exists (systemd will populate on first boot)
: > /etc/machine-id

echo "[setup] autologin enabled on ${CONSOLE} (offline)"
