#!/usr/bin/env bash

set -euo pipefail

ACTION_NAME="squashfs_rw_overlay"
REUSE_ACTION_NAME="squashfs_reuse_overlay"

usage() {
  cat <<'EOF'
Usage:
  mount-squashfs-rw.sh [--mode rw|ro|reuse] <image.sqfs> <mount_point>

Example:
  mount-squashfs-rw.sh --mode rw /path/to/archive.sqfs /tmp/archive-rw
  mount-squashfs-rw.sh --mode ro /path/to/archive.sqfs /tmp/archive-ro
  mount-squashfs-rw.sh --mode reuse /path/to/archive.sqfs /tmp/archive-work

Notes:
  - rw mode uses an ephemeral writable overlay and discards changes on unmount.
  - ro mode is a direct anylinuxfs mount of the SquashFS image.
  - reuse mode keeps the overlay upper/work state and reuses it next time.
  - The first rw or reuse run appends custom anylinuxfs actions to ~/.anylinuxfs/config.toml.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

metadata_dir_name="sqfs-reuse"
metadata_file_name="metadata"

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

file_signature() {
  stat -f '%i:%z' "$1"
}

reuse_metadata_dir() {
  local target_dir="$1"

  printf '%s.%s\n' "$target_dir" "$metadata_dir_name"
}

state_key_for() {
  local target_dir="$1"
  local image_path="$2"

  printf '%s\n%s\n' "$target_dir" "$image_path" | shasum -a 256 | awk '{print $1}'
}

write_reuse_metadata() {
  local metadata_dir="$1"
  local image_path="$2"
  local signature="$3"
  local state_key="$4"
  local metadata_file="${metadata_dir}/${metadata_file_name}"

  mkdir -p "$metadata_dir"
  {
    printf 'image_path=%q\n' "$image_path"
    printf 'image_signature=%q\n' "$signature"
    printf 'state_key=%q\n' "$state_key"
  } > "$metadata_file"
}

read_reuse_metadata() {
  local metadata_dir="$1"
  local metadata_file="${metadata_dir}/${metadata_file_name}"

  [[ -f "$metadata_file" ]] || return 1
  # shellcheck disable=SC1090
  source "$metadata_file"
}

ensure_action() {
  local cfg_dir="${HOME}/.anylinuxfs"
  local cfg_file="${cfg_dir}/config.toml"
  local tmp_file

  mkdir -p "$cfg_dir"
  touch "$cfg_file"

  tmp_file="$(mktemp "${cfg_file}.XXXXXX")"
  awk -v action1="$ACTION_NAME" -v action2="$REUSE_ACTION_NAME" '
    $0 == "[custom_actions." action1 "]" || $0 == "[custom_actions." action2 "]" {
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

[custom_actions.squashfs_reuse_overlay]
description = "Export squashfs through a persistent reusable overlayfs"
after_mount = '''
set -eu
mkdir -p /var/lib/alfs-squashfs-reuse/"$SQFS_REUSE_KEY"/upper /var/lib/alfs-squashfs-reuse/"$SQFS_REUSE_KEY"/work /run/alfs-squashfs-reuse-export
mount -t overlay overlay -o lowerdir="$ALFS_VM_MOUNT_POINT",upperdir=/var/lib/alfs-squashfs-reuse/"$SQFS_REUSE_KEY"/upper,workdir=/var/lib/alfs-squashfs-reuse/"$SQFS_REUSE_KEY"/work,nfs_export=on,index=on /run/alfs-squashfs-reuse-export
chown "$SQFS_OVERLAY_UID:$SQFS_OVERLAY_GID" /run/alfs-squashfs-reuse-export
chmod 0755 /run/alfs-squashfs-reuse-export
'''
before_unmount = '''
set -eu
if grep -qs " /run/alfs-squashfs-reuse-export " /proc/mounts; then
  umount /run/alfs-squashfs-reuse-export
fi
rmdir /run/alfs-squashfs-reuse-export 2>/dev/null || true
'''
override_nfs_export = "/run/alfs-squashfs-reuse-export"
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

if [[ "$mode" != "rw" && "$mode" != "ro" && "$mode" != "reuse" ]]; then
  die "Unsupported mode: $mode (expected rw, ro or reuse)"
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

if [[ "$mode" == "reuse" ]]; then
  metadata_dir="$(reuse_metadata_dir "$mount_point")"
  local_image_signature="$(file_signature "$image")"
  if read_reuse_metadata "$metadata_dir"; then
    if [[ "${image_path:-}" != "$image" ]]; then
      die "Reuse directory belongs to a different image: $mount_point"
    fi
    if [[ "${image_signature:-}" != "$local_image_signature" ]]; then
      die "Image changed since the reuse directory was created: $image"
    fi
    if [[ -z "${state_key:-}" ]]; then
      die "Reuse metadata is missing state_key: $metadata_dir"
    fi
  else
    state_key="$(state_key_for "$mount_point" "$image")"
    write_reuse_metadata "$metadata_dir" "$image" "$local_image_signature" "$state_key"
  fi

  ensure_action
  SQFS_OVERLAY_UID="$(id -u)"
  SQFS_OVERLAY_GID="$(id -g)"
  SQFS_REUSE_KEY="$state_key"
  export SQFS_OVERLAY_UID
  export SQFS_OVERLAY_GID
  export SQFS_REUSE_KEY

  printf 'Mounting reusable overlay view\n'
  printf '  image      : %s\n' "$image"
  printf '  mount point: %s\n' "$mount_point"
  printf '  state dir  : %s\n' "$metadata_dir"
  printf '  state key  : %s\n' "$state_key"

  anylinuxfs mount \
    "$image" \
    "$mount_point" \
    -a "$REUSE_ACTION_NAME" \
    -w false \
    --nfs-export-opts "rw,no_subtree_check,all_squash,anonuid=0,anongid=0,insecure" \
    -n noowners

  printf 'Mounted\n'
  printf '  mode       : reuse\n'
  printf '  backing    : anylinuxfs + persistent overlay upper/work\n'
  printf '  inspect with: ls %q\n' "$mount_point"
  printf '  unmount via : %s\n' "scripts/unmount-anylinuxfs.sh $mount_point"
  printf '  note       : keep %s to reuse the same overlay state next time\n' "$metadata_dir"
  exit 0
fi

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
