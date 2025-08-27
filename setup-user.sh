#!/bin/sh
set -eu

# ---- configurable via Debos -e VAR:VALUE ----
USERNAME="${USERNAME:-netsys}"       # user to create/use when LOGIN_AS=user
PASSWORD="${PASSWORD:-}"             # optional user password
CONSOLE="${CONSOLE:-ttyAMA0}"        # e.g. ttyAMA0 (aarch64 virt) or ttyS0
SUDO_NOPASS="${SUDO_NOPASS:-1}"      # 1 = passwordless sudo for %sudo
LOGIN_AS="${LOGIN_AS:-root}"         # root | user

echo "[setup] login_as=$LOGIN_AS user=$USERNAME console=$CONSOLE sudo_nopass=$SUDO_NOPASS"

# Common prep
getent group sudo  >/dev/null || groupadd sudo
getent group users >/dev/null || groupadd users

# Make sure machine-id placeholder exists (systemd will populate on first boot)
: > /etc/machine-id

if [ "$LOGIN_AS" = "root" ]; then
  # Ensure root has a real shell
  chsh -s /bin/bash root || true

  # Allow root to log in on serial consoles (mostly relevant for PAM-based logins)
  grep -q "^${CONSOLE}\$" /etc/securetty 2>/dev/null || echo "${CONSOLE}" >> /etc/securetty

  # Configure systemd serial-getty to autologin as root
  install -d "/etc/systemd/system/serial-getty@${CONSOLE}.service.d"
  cat > "/etc/systemd/system/serial-getty@${CONSOLE}.service.d/override.conf" <<EOF
[Service]
# Clear upstream ExecStart and set autologin for root (no password)
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I \$TERM
Type=simple
EOF

  # Offline enable: symlink the wants/ unit (no systemctl in chroot)
  install -d /etc/systemd/system/getty.target.wants
  ln -sf "/lib/systemd/system/serial-getty@.service" \
         "/etc/systemd/system/getty.target.wants/serial-getty@${CONSOLE}.service"

  echo "[setup] root autologin enabled on ${CONSOLE}"

else
  # Create user if missing; set password if provided
  if ! id -u "$USERNAME" >/dev/null 2>&1; then
    adduser --gecos "$USERNAME" --disabled-password --shell /bin/bash "$USERNAME"
  fi
  if [ -n "$PASSWORD" ]; then
    echo "$USERNAME:$PASSWORD" | chpasswd
  fi

  # Add to common groups
  for g in sudo users video render input audio; do
    adduser "$USERNAME" "$g" 2>/dev/null || true
  done

  # Optional: passwordless sudo
  if [ "$SUDO_NOPASS" = "1" ]; then
    install -d -m 0750 /etc/sudoers.d
    printf '%s\n' '%sudo ALL=(ALL:ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-nopasswd-sudo
    chmod 0440 /etc/sudoers.d/99-nopasswd-sudo
  fi

  # Autologin selected user on serial
  install -d "/etc/systemd/system/serial-getty@${CONSOLE}.service.d"
  cat > "/etc/systemd/system/serial-getty@${CONSOLE}.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${USERNAME} --noclear %I \$TERM
Type=simple
EOF

  install -d /etc/systemd/system/getty.target.wants
  ln -sf "/lib/systemd/system/serial-getty@.service" \
         "/etc/systemd/system/getty.target.wants/serial-getty@${CONSOLE}.service"

  echo "[setup] user autologin enabled on ${CONSOLE}"
fi
