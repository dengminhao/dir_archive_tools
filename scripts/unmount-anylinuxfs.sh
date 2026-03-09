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

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

need_cmd anylinuxfs

target="$1"

printf 'Unmounting %s\n' "$target"
anylinuxfs unmount "$target"

if [[ -d "$target" ]]; then
  rmdir "$target" 2>/dev/null || true
fi
