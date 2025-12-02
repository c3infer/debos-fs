#!/usr/bin/env bash
set -euo pipefail

# --- Defaults ---
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RECIPE="${RECIPE:-$DIR/recipe.yaml}"
ARTIFACTDIR="${ARTIFACTDIR:-$DIR/out}"

FORMAT="${FORMAT:-cpio.gz}"           # cpio | cpio.gz | ext4 | tar
IMGNAME="${IMGNAME:-rootfs.img}"
IMGSIZE="${IMGSIZE:-700MB}"
CPIONAME="${CPIONAME:-rootfs.cpio}"
CPIONAME_GZ="${CPIONAME_GZ:-rootfs.cpio.gz}"
TARNAME="${TARNAME:-rootfs.tar.gz}"

# console/login
CONSOLE="${CONSOLE:-ttyS0}"
USERNAME="${USERNAME:-netsys}"
PASSWORD="${PASSWORD:-netsys}"
SUDO_NOPASS="${SUDO_NOPASS:-1}"
HOSTNAME="${HOSTNAME:-vm}"            # removes 'fakemachine' prompt
LOGIN_AS="${LOGIN_AS:-root}"          # root | user
OVERLAY_DEST="${OVERLAY_DEST:-/root}"     # where to place overlay inside the image

# Python (lean by default; no venv)
PY_ENABLE="${PY_ENABLE:-0}"           # 0 = off (smallest), 1 = install
PY_MODE="${PY_MODE:-system}"          # system | venv
PY_VENV_PATH="${PY_VENV_PATH:-/opt/venvs/default}"

reqs_file="${reqs_file:-./requirements.txt}"            # optional (for your script)

# Size-slimming toggles used by the recipe
KEEP_LOCALES="${KEEP_LOCALES:-en}"

# For now it is better to not use these flags as they might create crashing and unstability
PY_PRUNE_TESTS="${PY_PRUNE_TESTS:-0}"
PY_COMPILE_PYC="${PY_COMPILE_PYC:-0}"
PY_DROP_SOURCES="${PY_DROP_SOURCES:-0}"

DEBOS_VERBOSE=0
DRY_RUN=0

OVERLAY="${OVERLAY:-./overlay}"

DEVICE_MOUNT="${DEVICE_MOUNT:-sh}"
MOUNT_POINT="${MOUNT_POINT:-/root/shared_with_VM}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

General:
  --recipe PATH             (default: $RECIPE)
  --artifactdir DIR         (default: $ARTIFACTDIR)
  --format FMT              cpio|cpio.gz|ext4|tar  (default: $FORMAT)
  --verbose                 pass -v to debos
  --dry-run                 print the command and exit
  --overlay DIR             overlay directory to merge into the rootfs (default: $OVERLAY)
                            (only in-tree addresses work. give relative path)
  --overlay-dest PATH      (default: $OVERLAY_DEST)
  --device-mount NAME       (default: $DEVICE_MOUNT) The device name to mount inside the VM. Does not work with .ext4 images.
  --mount-point PATH        (default: $MOUNT_POINT) The mount point inside the VM. Does not work with .ext4 images.

Console & user:
  --console TTY             (default: $CONSOLE)
  --username NAME           (default: $USERNAME)
  --password PASS           (default: $PASSWORD)
  --sudo-nopass 0|1         (default: $SUDO_NOPASS)
  --hostname NAME          (default: $HOSTNAME)
  --login-as MODE          root|user (default: $LOGIN_AS)


Python:
  --py-enable 0|1           (default: $PY_ENABLE)
  --py-mode MODE            system|venv (default: $PY_MODE)
  --py-venv-path PATH       (default: $PY_VENV_PATH)
  --reqs-file PATH          passed as reqs_file to your script  (default: $reqs_file)
                            (only in-tree addresses work. give relative path)

Format-specific:
  --imgname NAME            (ext4)   (default: $IMGNAME)
  --imgsize SIZE            (ext4)   (default: $IMGSIZE)
  --cpioname NAME           (cpio)   (default: $CPIONAME)
  --cpioname-gz NAME        (cpio.gz)(default: $CPIONAME_GZ)
  --tarname NAME            (tar)    (default: $TARNAME)

Slimming:
  --keep-locales CODE       (default: $KEEP_LOCALES)
  --py-prune-tests 0|1      (default: $PY_PRUNE_TESTS)
  --py-compile-pyc 0|1      (default: $PY_COMPILE_PYC)
  --py-drop-sources 0|1     (default: $PY_DROP_SOURCES)

Examples:
  # Minimal image, cpio.gz, no Python
  $(basename "$0") --format cpio.gz --py-enable 0

  # ext4 image, Python enabled from requirements.txt
  $(basename "$0") --format ext4 --py-enable 1 --reqs-file Absolute_address_to_requirements.txt

EOF
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --recipe) RECIPE="$2"; shift 2;;
    --artifactdir) ARTIFACTDIR="$2"; shift 2;;
    --format) FORMAT="$2"; shift 2;;

    --console) CONSOLE="$2"; shift 2;;
    --username) USERNAME="$2"; shift 2;;
    --password) PASSWORD="$2"; shift 2;;
    --sudo-nopass) SUDO_NOPASS="$2"; shift 2;;
    --hostname) HOSTNAME="$2"; shift 2;;
    --login-as) LOGIN_AS="$2"; shift 2;;
    --overlay-dest) OVERLAY_DEST="$2"; shift 2;;

    --py-enable) PY_ENABLE="$2"; shift 2;;
    --py-mode) PY_MODE="$2"; shift 2;;
    --py-venv-path) PY_VENV_PATH="$2"; shift 2;;
    --reqs-file) reqs_file="$2"; shift 2;;

    --imgname) IMGNAME="$2"; shift 2;;
    --imgsize) IMGSIZE="$2"; shift 2;;
    --cpioname) CPIONAME="$2"; shift 2;;
    --cpioname-gz) CPIONAME_GZ="$2"; shift 2;;
    --tarname) TARNAME="$2"; shift 2;;
    --overlay) OVERLAY="$2"; shift 2;;

    --keep-locales) KEEP_LOCALES="$2"; shift 2;;
    --py-prune-tests) PY_PRUNE_TESTS="$2"; shift 2;;
    --py-compile-pyc) PY_COMPILE_PYC="$2"; shift 2;;
    --py-drop-sources) PY_DROP_SOURCES="$2"; shift 2;;

    --verbose) DEBOS_VERBOSE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 2;;
  esac  
done

mkdir -p "$ARTIFACTDIR"
mkdir -p out
mkdir -p overlay

# --- Validate format ---
case "$FORMAT" in
  cpio|cpio.gz|ext4|tar) ;;
  *) echo "Invalid --format '$FORMAT' (must be: cpio|cpio.gz|ext4|tar)"; exit 2;;
esac

# --- Base CMD ---
CMD="debos --artifactdir $ARTIFACTDIR"
#CMD="$CMD -t artifactdir:$ARTIFACTDIR" 
[[ $DEBOS_VERBOSE -eq 1 ]] && CMD="$CMD -v"

# Format-specific -t vars
case "$FORMAT" in
  cpio)     CMD="$CMD -t cpioname:$CPIONAME" ;;
  cpio.gz)  CMD="$CMD -t cpioname_gz:$CPIONAME_GZ" ;;
  ext4)     CMD="$CMD -t imgname:$IMGNAME -t imgsize:$IMGSIZE" ;;
  tar)      CMD="$CMD -t tarname:$TARNAME" ;;
esac

CMD="$CMD -t format:$FORMAT"  

# Python toggles (match your recipe’s variables)
CMD="$CMD -t py_enable:$PY_ENABLE -t py_mode:$PY_MODE -t py_venv_path:$PY_VENV_PATH"
CMD="$CMD -t keep_locales:$KEEP_LOCALES -t py_prune_tests:$PY_PRUNE_TESTS -t py_compile_pyc:$PY_COMPILE_PYC -t py_drop_sources:$PY_DROP_SOURCES"
CMD="$CMD -t hostname:$HOSTNAME -t overlay_dest:$OVERLAY_DEST"   
# Env vars for your helper script(s)
CMD="$CMD -e CONSOLE:$CONSOLE -e USERNAME:$USERNAME -e PASSWORD:$PASSWORD -e SUDO_NOPASS:$SUDO_NOPASS -e LOGIN_AS:$LOGIN_AS"   

#CMD="$CMD -t username:$USERNAME"
[[ -n "${reqs_file}" ]] && CMD="$CMD -t reqs_file:$reqs_file"

if [[ -d "$OVERLAY" ]]; then
  CMD="$CMD -t overlay_dir:$OVERLAY"
fi

# Recipe
CMD="$CMD $RECIPE"

# Device mount and mount point (only for non-ext4 images)
if [[ $FORMAT != "ext4" ]]; then
  CMD="$CMD -t device_mount:$DEVICE_MOUNT -t mount_point:$MOUNT_POINT"
fi

echo "+ $CMD"
if [[ $DRY_RUN -eq 1 ]]; then
  exit 0
fi

# Run it
eval "$CMD"
