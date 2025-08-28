#!/usr/bin/env bash
set -euo pipefail

# Always operate relative to this script's directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# ---------- Defaults ----------
OVERLAY="${OVERLAY:-./overlay}"
OUTDIR="${OUTDIR:-./out}"
ARTIFACT="${ARTIFACT:-./out/rootfs.cpio.gz}"
DEST="${DEST:-/root}"     # path inside target FS to place overlay contents
BACKUP=1
DRYRUN=0
LIST=0
VERIFY_PATH="${VERIFY_PATH:-}"  # optional path to check inside the artifact after applying

# ---------- Helpers ----------
log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Overlay the contents of ./overlay into an existing artifact in ./out.
Supported: initramfs CPIO(.gz) [REPACK ONLY, single newc], ext4 images (.img),
and rootfs tarballs (.tar.gz).

Usage:
  overlay-into-artifact.sh [options]

Options:
  --overlay DIR      Overlay directory (default: ./overlay)
  --out DIR          Output directory with artifacts (default: ./out)
  --artifact PATH    Artifact to modify (.cpio|.cpio.gz|.img|.tar.gz)
  --dest PATH        Target path inside the filesystem (default: /root)
  --verify PATH      After applying, check that PATH exists inside the artifact
  --no-backup        Do not create ARTIFACT.bak
  --dry-run          Show actions without modifying anything
  --list             List detected artifacts in --out and exit
  -h, --help         Show this help and exit

Notes:
  • CPIO(.gz): ALWAYS repacks → extract → merge overlay into DEST → rebuild single newc → (re)gzip
  • .img: loop/partition mount, copy overlay to DEST, unmount (requires sudo)
  • .tar.gz: append overlay under DEST and recompress

Tip:
  If your kernel boots with an ext4 root (cmdline has "root="), changes to the initramfs
  won’t show in the final root filesystem. Modify the .img instead (or both).
EOF
}

# ---------- Arg parse ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --overlay) OVERLAY="$2"; shift 2;;
    --out) OUTDIR="$2"; shift 2;;
    --artifact) ARTIFACT="$2"; shift 2;;
    --dest) DEST="$2"; shift 2;;
    --verify) VERIFY_PATH="$2"; shift 2;;
    --no-backup) BACKUP=0; shift;;
    --dry-run) DRYRUN=1; shift;;
    --list) LIST=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1 (try --help)";;
  esac
done

# ---------- Sanity ----------
[[ -d "$OVERLAY" ]] || die "overlay dir not found: $OVERLAY"
[[ -d "$OUTDIR"  ]] || die "out dir not found: $OUTDIR"

# Normalize DEST (leading slash, strip trailing unless root)
if [[ -z "$DEST" ]]; then DEST="/"; fi
if [[ "${DEST:0:1}" != "/" ]]; then DEST="/$DEST"; fi
[[ "$DEST" != "/" ]] && DEST="${DEST%/}"

discover() {
  shopt -s nullglob
  local arr=("$OUTDIR"/*.cpio.gz "$OUTDIR"/*.cpio "$OUTDIR"/*.img "$OUTDIR"/*.tar.gz)
  local found=()
  for f in "${arr[@]}"; do [[ -f "$f" ]] && found+=("$f"); done
  printf '%s\n' "${found[@]}"
}

if [[ $LIST -eq 1 ]]; then
  log "Artifacts in $OUTDIR:"
  discover || true
  exit 0
fi

# If ARTIFACT wasn't given explicitly and the default isn't usable, try discovering a single artifact
if [[ ! -f "$ARTIFACT" ]]; then
  mapfile -t matches < <(discover || true)
  if   [[ ${#matches[@]} -eq 0 ]]; then die "Artifact not found: $ARTIFACT  (and none discovered in $OUTDIR)"
  elif [[ ${#matches[@]} -eq 1 ]]; then ARTIFACT="${matches[0]}"
  else
    log "Multiple artifacts found; please specify --artifact:"
    printf '  %s\n' "${matches[@]}" >&2
    exit 1
  fi
fi

[[ -f "$ARTIFACT" ]] || die "Artifact not found: $ARTIFACT"

log "[i] Overlay  : $OVERLAY"
log "[i] Artifact : $ARTIFACT"
log "[i] Dest     : $DEST"
[[ -n "$VERIFY_PATH" ]] && log "[i] Verify   : $VERIFY_PATH"
[[ $BACKUP -eq 1 ]] && log "[i] Backup   : enabled (will create ${ARTIFACT}.bak)"
[[ $DRYRUN  -eq 1 ]] && log "[i] Dry-run  : enabled"

# ---------- Temp + cleanup ----------
tmpdir="$(mktemp -d)"
cleanup() {
  set +e
  [[ -n "${mnt:-}" ]] && mountpoint -q "$mnt" && sudo umount "$mnt"
  [[ -n "${loopdev:-}" ]] && sudo losetup -d "$loopdev" >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

do_backup() {
  [[ $BACKUP -eq 1 ]] || return 0
  if [[ $DRYRUN -eq 1 ]]; then
    log "[dry] cp -a \"$ARTIFACT\" \"${ARTIFACT}.bak\""
  else
    cp -a "$ARTIFACT" "${ARTIFACT}.bak"
    log "[i] Backup made: ${ARTIFACT}.bak"
  fi
}

sanitize_overlay_into() {
  local dst="$1"
  mkdir -p "$dst"
  local excludes=(
    --exclude 'out' --exclude '*.img' --exclude '*.cpio' --exclude '*.cpio.gz'
    --exclude '*.tar.gz' --exclude '.git' --exclude 'node_modules'
    --exclude '__pycache__' --exclude '*.pyc'
  )
  local rs=( -a )
  [[ -f "$OVERLAY/.overlayignore" ]] && rs+=( "--exclude-from=$OVERLAY/.overlayignore" )
  rs+=( "${excludes[@]}" )
  if [[ $DRYRUN -eq 1 ]]; then
    log "[dry] rsync ${rs[*]} \"$OVERLAY\"/ \"$dst\"/"
  else
    rsync "${rs[@]}" "$OVERLAY"/ "$dst"/
  fi
}

ensure_root_meta_strategy() {
  # Prefer fakeroot for correct ownership in CPIO; else try sudo chown; else warn.
  if command -v fakeroot >/dev/null 2>&1; then
    echo "fakeroot" > "$tmpdir/.use_fakeroot"
  elif sudo -n true >/dev/null 2>&1; then
    echo "sudochown" > "$tmpdir/.use_chown"
  else
    log "[!] Neither 'fakeroot' nor passwordless sudo available; CPIO entries may reflect your UID/GID."
  fi
}

repack_cpio() {
  local base="$1"
  local gz=0
  [[ "$base" == *.gz ]] && gz=1
  log "[i] Repack CPIO: extract → merge overlay → rebuild single newc"

  local root="$tmpdir/root"
  mkdir -p "$root"

  # Extract CPIO
  if [[ $DRYRUN -eq 1 ]]; then
    if [[ $gz -eq 1 ]]; then
      log "[dry] gzip -cd \"$base\" | (cd \"$root\" && cpio -idm --quiet)"
    else
      log "[dry] (cd \"$root\" && cpio -idm --quiet < \"$base\")"
    fi
  else
    if [[ $gz -eq 1 ]]; then
      gzip -cd "$base" | (cd "$root" && cpio -idm --quiet)
    else
      (cd "$root" && cpio -idm --quiet < "$base")
    fi
  fi

  # Merge overlay into DEST within extracted tree
  local target="$root$DEST"
  [[ $DRYRUN -eq 1 ]] || mkdir -p "$target"
  sanitize_overlay_into "$target"

  # Ensure root ownership if possible (or mark to use fakeroot for packing)
  ensure_root_meta_strategy
  if [[ -f "$tmpdir/.use_chown" && $DRYRUN -eq 0 ]]; then
    sudo chown -R 0:0 "$root" || true
  elif [[ -f "$tmpdir/.use_chown" && $DRYRUN -eq 1 ]]; then
    log "[dry] sudo chown -R 0:0 \"$root\""
  fi

  # Pack single newc (with or without fakeroot)
  if [[ $gz -eq 1 ]]; then
    if [[ -f "$tmpdir/.use_fakeroot" ]]; then
      if [[ $DRYRUN -eq 1 ]]; then
        log "[dry] fakeroot sh -c '(cd \"$root\" && find . -print0 | cpio --null -o -H newc | gzip -9 > \"$tmpdir/new.cpio.gz\")'"
        log "[dry] mv \"$tmpdir/new.cpio.gz\" \"$base\""
      else
        fakeroot sh -c "(cd \"$root\" && find . -print0 | cpio --null -o -H newc | gzip -9 > \"$tmpdir/new.cpio.gz\")"
        mv "$tmpdir/new.cpio.gz" "$base"
      fi
    else
      if [[ $DRYRUN -eq 1 ]]; then
        log "[dry] (cd \"$root\" && find . -print0 | cpio --null -o -H newc | gzip -9 > \"$tmpdir/new.cpio.gz\")"
        log "[dry] mv \"$tmpdir/new.cpio.gz\" \"$base\""
      else
        (cd "$root" && find . -print0 | cpio --null -o -H newc | gzip -9 > "$tmpdir/new.cpio.gz")
        mv "$tmpdir/new.cpio.gz" "$base"
      fi
    fi
  else
    if [[ -f "$tmpdir/.use_fakeroot" ]]; then
      if [[ $DRYRUN -eq 1 ]]; then
        log "[dry] fakeroot sh -c '(cd \"$root\" && find . -print0 | cpio --null -o -H newc > \"$tmpdir/new.cpio\")'"
        log "[dry] mv \"$tmpdir/new.cpio\" \"$base\""
      else
        fakeroot sh -c "(cd \"$root\" && find . -print0 | cpio --null -o -H newc > \"$tmpdir/new.cpio\")"
        mv "$tmpdir/new.cpio" "$base"
      fi
    else
      if [[ $DRYRUN -eq 1 ]]; then
        log "[dry] (cd \"$root\" && find . -print0 | cpio --null -o -H newc > \"$tmpdir/new.cpio\")"
        log "[dry] mv \"$tmpdir/new.cpio\" \"$base\""
      else
        (cd "$root" && find . -print0 | cpio --null -o -H newc > "$tmpdir/new.cpio")
        mv "$tmpdir/new.cpio" "$base"
      fi
    fi
  fi

  log "[✓] Repacked $(basename "$base")"
}

overlay_into_ext4_img() {
  local img="$1"
  log "[i] Mount image…"
  mnt="$tmpdir/mnt"; mkdir -p "$mnt"

  if [[ $DRYRUN -eq 1 ]]; then
    log "[dry] sudo mount -o loop \"$img\" \"$mnt\" || (loopdev=\$(sudo losetup --find --show --partscan \"$img\"); sudo mount \${loopdev}p1 \"$mnt\")"
  else
    if sudo mount -o loop "$img" "$mnt" 2>/dev/null; then :
    else
      loopdev="$(sudo losetup --find --show --partscan "$img")"
      part="${loopdev}p1"
      [[ -b "$part" ]] || die "No partition node (tried $part)"
      sudo mount "$part" "$mnt"
    fi
  fi

  local target="$mnt$DEST"
  [[ $DRYRUN -eq 1 ]] || sudo mkdir -p "$target"

  log "[i] Copy overlay → image at $DEST…"
  if command -v rsync >/dev/null 2>&1; then
    if [[ $DRYRUN -eq 1 ]]; then
      log "[dry] sudo rsync -a \"$OVERLAY\"/ \"$target\"/"
    else
      sudo rsync -a "$OVERLAY"/ "$target"/
    fi
  else
    if [[ $DRYRUN -eq 1 ]]; then
      log "[dry] sudo cp -a \"$OVERLAY\"/. \"$target\"/"
    else
      sudo cp -a "$OVERLAY"/. "$target"/
    fi
  fi

  if [[ $DRYRUN -eq 1 ]]; then
    log "[dry] sudo umount \"$mnt\""
    log "[dry] [[ -n \${loopdev:-} ]] && sudo losetup -d \"\$loopdev\""
  else
    sync
    sudo umount "$mnt"
    [[ -n "${loopdev:-}" ]] && sudo losetup -d "$loopdev"
    unset mnt loopdev
  fi
  log "[✓] Overlay copied into $(basename "$img") at $DEST"
}

append_overlay_to_targz() {
  local tgz="$1"
  log "[i] Append overlay into tar.gz at $DEST…"
  local work="$tmpdir/work.tar"
  local tmpovl="$tmpdir/ovl"; mkdir -p "$tmpovl$DEST"
  rsync -a "$OVERLAY"/ "$tmpovl$DEST"/

  if [[ $DRYRUN -eq 1 ]]; then
    log "[dry] gzip -cd \"$tgz\" > \"$work\""
    log "[dry] ( cd \"$tmpovl\" && tar --owner=0 --group=0 --numeric-owner -rf \"$work\" . )"
    log "[dry] gzip -9 < \"$work\" > \"$tmpdir/new.tar.gz\" && mv \"$tmpdir/new.tar.gz\" \"$tgz\""
  else
    gzip -cd "$tgz" > "$work"
    ( cd "$tmpovl" && tar --owner=0 --group=0 --numeric-owner -rf "$work" . )
    gzip -9 < "$work" > "$tmpdir/new.tar.gz"
    mv "$tmpdir/new.tar.gz" "$tgz"
  fi

  log "[✓] Overlay appended to $(basename "$tgz") at $DEST"
}

post_verify() {
  [[ -z "$VERIFY_PATH" ]] && return 0
  local vp="$VERIFY_PATH"
  [[ "${vp:0:1}" != "/" ]] && vp="/$vp"
  log "[i] Verifying presence of \"$vp\" inside artifact…"

  case "$ARTIFACT" in
    *.cpio.gz)
      if gzip -cd "$ARTIFACT" | cpio -t 2>/dev/null | grep -E -x '(\./)?'"${vp#/}"; then
        log "[✓] Found: ${vp} in $(basename "$ARTIFACT")"
      else
        log "[!] NOT found: ${vp} in $(basename "$ARTIFACT")"
      fi
      ;;
    *.cpio)
      if cpio -t < "$ARTIFACT" 2>/dev/null | grep -E -x '(\./)?'"${vp#/}"; then
        log "[✓] Found: ${vp} in $(basename "$ARTIFACT")"
      else
        log "[!] NOT found: ${vp} in $(basename "$ARTIFACT")"
      fi
      ;;
    *.img)
      mnt="$tmpdir/verifymnt"; mkdir -p "$mnt"
      if sudo mount -o loop "$ARTIFACT" "$mnt" 2>/dev/null; then :
      else
        loopdev="$(sudo losetup --find --show --partscan "$ARTIFACT")"
        sudo mount "${loopdev}p1" "$mnt"
      fi
      if sudo test -e "$mnt$vp"; then
        log "[✓] Found: $vp in $(basename "$ARTIFACT")"
      else
        log "[!] NOT found: $vp in $(basename "$ARTIFACT")"
      fi
      sudo umount "$mnt" || true
      [[ -n "${loopdev:-}" ]] && sudo losetup -d "$loopdev" || true
      ;;
    *.tar.gz)
      if tar tzf "$ARTIFACT" | grep -qxF "${vp#/}"; then
        log "[✓] Found: $vp in $(basename "$ARTIFACT")"
      else
        log "[!] NOT found: $vp in $(basename "$ARTIFACT")"
      fi
      ;;
    *) log "[!] post-verify: unsupported artifact type";;
  esac
}

# ---------- Run ----------
do_backup
case "$ARTIFACT" in
  *.cpio|*.cpio.gz) repack_cpio "$ARTIFACT" ;;
  *.img)            overlay_into_ext4_img "$ARTIFACT" ;;
  *.tar.gz)         append_overlay_to_targz "$ARTIFACT" ;;
  *) die "Unsupported artifact: $ARTIFACT (supported: .cpio, .cpio.gz, .img, .tar.gz)";;
esac

post_verify

log "[done] Overlay applied."
