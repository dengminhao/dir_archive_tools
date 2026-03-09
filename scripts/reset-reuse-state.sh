#!/usr/bin/env bash

set -euo pipefail

metadata_dir_name="sqfs-reuse"
metadata_file_name="metadata"

usage() {
  cat <<'EOF'
Usage:
  reset-reuse-state.sh <mount_point>

Example:
  reset-reuse-state.sh /tmp/archive-work

Notes:
  - This deletes the persisted state used by `mount-squashfs-rw.sh --mode reuse`.
  - The target must not be currently mounted.
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

reuse_metadata_dir() {
  local target_dir="$1"

  printf '%s.%s\n' "$target_dir" "$metadata_dir_name"
}

read_reuse_metadata() {
  local metadata_dir="$1"
  local metadata_file="${metadata_dir}/${metadata_file_name}"

  [[ -f "$metadata_file" ]] || return 1
  # shellcheck disable=SC1090
  source "$metadata_file"
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

need_cmd anylinuxfs

mount_point="$(abs_path "$1")"
metadata_dir="$(reuse_metadata_dir "$mount_point")"

[[ -d "$metadata_dir" ]] || die "Reuse metadata directory not found: $metadata_dir"
read_reuse_metadata "$metadata_dir" || die "Reuse metadata file not found: ${metadata_dir}/${metadata_file_name}"
[[ -n "${state_key:-}" ]] || die "Missing state_key in ${metadata_dir}/${metadata_file_name}"

if mount | grep -Fq " on ${mount_point} ("; then
  die "Mount point is still mounted: $mount_point"
fi

printf 'Resetting reuse state\n'
printf '  mount point: %s\n' "$mount_point"
printf '  state dir  : %s\n' "$metadata_dir"
printf '  state key  : %s\n' "$state_key"

for attempt in 1 2 3; do
  anylinuxfs stop >/dev/null 2>&1 || true
  sleep 1
  if anylinuxfs shell -c "rm -rf '/var/lib/alfs-squashfs-reuse/${state_key}'"; then
    rm -rf "$metadata_dir"
    printf 'Done\n'
    exit 0
  fi
done

die "Failed to reset VM-side reuse state after multiple attempts"
