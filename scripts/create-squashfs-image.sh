#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  create-squashfs-image.sh <source_dir> <dest_image.sqfs>

Example:
  create-squashfs-image.sh /path/to/source-dir /path/to/archive.sqfs

Environment:
  FORCE=1    overwrite an existing destination image
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

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

need_cmd mksquashfs

src_dir="$1"
dest_image="$2"

[[ -d "$src_dir" ]] || die "Source directory not found: $src_dir"

mkdir -p "$(dirname "$dest_image")"

src_dir="$(abs_path "$src_dir")"
dest_image="$(abs_path "$dest_image")"

if [[ -e "$dest_image" && "${FORCE:-0}" != "1" ]]; then
  die "Destination already exists: $dest_image (set FORCE=1 to overwrite)"
fi

tmp_image="${dest_image}.tmp.$$"
trap 'rm -f "$tmp_image"' EXIT

printf 'Creating SquashFS image\n'
printf '  source: %s\n' "$src_dir"
printf '  target: %s\n' "$dest_image"

rm -f "$tmp_image"

mksquashfs \
  "$src_dir" \
  "$tmp_image" \
  -noappend \
  -comp zstd \
  -b 1M \
  -root-uid "$(id -u)" \
  -root-gid "$(id -g)" \
  -root-mode 0755 \
  -no-xattrs

mv -f "$tmp_image" "$dest_image"

printf 'Done\n'
printf '  source size: %s\n' "$(du -sh "$src_dir" | awk '{print $1}')"
printf '  image size : %s\n' "$(du -sh "$dest_image" | awk '{print $1}')"
