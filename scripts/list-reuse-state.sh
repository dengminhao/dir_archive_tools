#!/usr/bin/env bash

set -euo pipefail

metadata_dir_suffix=".sqfs-reuse"
metadata_file_name="metadata"

usage() {
  cat <<'EOF'
Usage:
  list-reuse-state.sh [search_root ...]

Example:
  list-reuse-state.sh
  list-reuse-state.sh /tmp /Volumes/work

Notes:
  - Without arguments, this scans /tmp.
  - This only reads local reuse sidecar metadata and does not start anylinuxfs.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

abs_dir() {
  local target="$1"
  [[ -d "$target" ]] || die "Directory not found: $target"
  (
    cd "$target"
    pwd -P
  )
}

read_reuse_metadata() {
  local metadata_dir="$1"
  local metadata_file="${metadata_dir}/${metadata_file_name}"

  [[ -f "$metadata_file" ]] || return 1
  unset image_path image_signature state_key
  # shellcheck disable=SC1090
  source "$metadata_file"
}

if [[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 ]]; then
  search_roots=(/tmp)
else
  search_roots=()
  for root in "$@"; do
    search_roots+=("$(abs_dir "$root")")
  done
fi

printf 'Listing reuse state metadata\n'
printf '  suffix: %s\n' "$metadata_dir_suffix"
printf '  roots : %s\n' "${search_roots[*]}"

found=0

for root in "${search_roots[@]}"; do
  while IFS= read -r metadata_dir; do
    read_reuse_metadata "$metadata_dir" || continue
    found=1

    mount_point="${metadata_dir%${metadata_dir_suffix}}"
    if mount | grep -Fq " on ${mount_point} ("; then
      mounted="yes"
    else
      mounted="no"
    fi

    printf '\n'
    printf 'mount_point=%s\n' "$mount_point"
    printf 'metadata_dir=%s\n' "$metadata_dir"
    printf 'image_path=%s\n' "${image_path:-}"
    printf 'image_signature=%s\n' "${image_signature:-}"
    printf 'state_key=%s\n' "${state_key:-}"
    printf 'mounted=%s\n' "$mounted"
  done < <(find "$root" -type d -name "*${metadata_dir_suffix}" 2>/dev/null | sort)
done

if [[ "$found" -eq 0 ]]; then
  printf 'No reuse state metadata found.\n'
fi
