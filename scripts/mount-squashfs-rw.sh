#!/usr/bin/env bash

set -euo pipefail

ACTION_NAME="squashfs_rw_overlay"

usage() {
  cat <<'EOF'
Usage:
  mount-squashfs-rw.sh [--mode rw|ro] <image.sqfs> <mount_point>

Example:
  mount-squashfs-rw.sh --mode rw /path/to/archive.sqfs /tmp/archive-rw
  mount-squashfs-rw.sh --mode ro /path/to/archive.sqfs /tmp/archive-ro

Notes:
  - rw mode uses an ephemeral writable overlay and discards changes on unmount.
  - ro mode is a direct anylinuxfs mount of the SquashFS image.
  - The first rw run appends a custom anylinuxfs action to ~/.anylinuxfs/config.toml.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

abs_path() {
  local target="$1"

  if [[ -d "$target" ]]; then
    (
      cd "$target"
      pwd -P
    )
    return
  fi

  (
    cd "$(dirname "$target")"
    printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  )
}

ensure_action() {
  local cfg_dir="${HOME}/.anylinuxfs"
  local cfg_file="${cfg_dir}/config.toml"
  local tmp_file

  mkdir -p "$cfg_dir"
  touch "$cfg_file"

  tmp_file="$(mktemp "${cfg_file}.XXXXXX")"
  awk -v action="$ACTION_NAME" '
    $0 == "[custom_actions." action "]" {
      skip = 1
      next
    }
    skip && /^\[/ {
      skip = 0
    }
    !skip {
      print
    }
  ' "$cfg_file" > "$tmp_file"
  mv "$tmp_file" "$cfg_file"

  if [[ -s "$cfg_file" ]]; then
    printf '\n' >> "$cfg_file"
  fi

  cat >> "$cfg_file" <<'EOF'
[custom_actions.squashfs_rw_overlay]
description = "Export squashfs through an ephemeral writable overlayfs"
after_mount = '''
set -eu
mkdir -p /run/alfs-squashfs-rw/merged /run/alfs-squashfs-rw/upper /run/alfs-squashfs-rw/work
mount -t overlay overlay -o lowerdir="$ALFS_VM_MOUNT_POINT",upperdir=/run/alfs-squashfs-rw/upper,workdir=/run/alfs-squashfs-rw/work,nfs_export=on,index=on /run/alfs-squashfs-rw/merged
chown "$SQFS_OVERLAY_UID:$SQFS_OVERLAY_GID" /run/alfs-squashfs-rw/merged
chmod 0755 /run/alfs-squashfs-rw/merged
'''
before_unmount = '''
set -eu
if grep -qs " /run/alfs-squashfs-rw/merged " /proc/mounts; then
  umount /run/alfs-squashfs-rw/merged
fi
rm -rf /run/alfs-squashfs-rw
'''
override_nfs_export = "/run/alfs-squashfs-rw/merged"
required_os = "Linux"
EOF
}

mode="rw"

if [[ $# -ge 1 && "$1" == "--mode" ]]; then
  [[ $# -ge 2 ]] || {
    usage >&2
    exit 2
  }
  mode="$2"
  shift 2
fi

if [[ "$mode" != "rw" && "$mode" != "ro" ]]; then
  die "Unsupported mode: $mode (expected rw or ro)"
fi

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

need_cmd anylinuxfs

image="$1"
mount_point="$2"

[[ -f "$image" ]] || die "Image not found: $image"

mkdir -p "$mount_point"

image="$(abs_path "$image")"
mount_point="$(abs_path "$mount_point")"

if [[ "$mode" == "ro" ]]; then
  printf 'Mounting read-only view via direct anylinuxfs mount\n'
  printf '  image      : %s\n' "$image"
  printf '  mount point: %s\n' "$mount_point"

  anylinuxfs mount "$image" "$mount_point" -w false

  printf 'Mounted\n'
  printf '  mode       : ro\n'
  printf '  backing    : direct anylinuxfs mount\n'
  printf '  inspect with: ls %q\n' "$mount_point"
  printf '  unmount via : %s\n' "scripts/unmount-anylinuxfs.sh $mount_point"
  exit 0
fi

ensure_action

SQFS_OVERLAY_UID="$(id -u)"
SQFS_OVERLAY_GID="$(id -g)"
export SQFS_OVERLAY_UID
export SQFS_OVERLAY_GID

printf 'Mounting writable overlay view\n'
printf '  image      : %s\n' "$image"
printf '  mount point: %s\n' "$mount_point"

anylinuxfs mount \
  "$image" \
  "$mount_point" \
  -a "$ACTION_NAME" \
  -w false \
  --nfs-export-opts "rw,no_subtree_check,all_squash,anonuid=0,anongid=0,insecure" \
  -n noowners
printf 'Mounted\n'
printf '  mode       : rw\n'
printf '  backing    : anylinuxfs + overlayfs + NFS export\n'
printf '  inspect with: ls %q\n' "$mount_point"
printf '  unmount via : %s\n' "scripts/unmount-anylinuxfs.sh $mount_point"
