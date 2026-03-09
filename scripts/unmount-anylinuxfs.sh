#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  unmount-anylinuxfs.sh <mount_point_or_image>

Example:
  unmount-anylinuxfs.sh /tmp/archive-rw
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

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

need_cmd anylinuxfs

target="$1"
target="$(abs_path "$target")"

if ! mount | grep -Fq " on ${target} ("; then
  printf 'Nothing to unmount for %s\n' "$target"
  printf 'If this is a reuse-mode directory, it is already a normal local directory.\n'
  exit 0
fi

printf 'Unmounting %s\n' "$target"
anylinuxfs unmount "$target"
anylinuxfs stop >/dev/null 2>&1 || true

if [[ -d "$target" ]]; then
  rmdir "$target" 2>/dev/null || true
fi
