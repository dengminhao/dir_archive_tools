#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  verify-mounted-image.sh [--mode quick|checksum] [--no-progress] <source_dir> <mounted_dir>

Example:
  verify-mounted-image.sh /path/to/source-dir /tmp/archive-ro
  verify-mounted-image.sh --mode checksum /path/to/source-dir /tmp/archive-ro

Notes:
  - quick mode is the default and compares by size+mtime for regular files.
  - checksum mode adds full file-content checksums and is much slower.
  - macOS ACLs/xattrs/owners/groups/perms are intentionally ignored.
  - Exit code is 0 when no differences are found, 1 when differences are found.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

abs_dir() {
  local target="$1"
  [[ -d "$target" ]] || die "Directory not found: $target"
  (
    cd "$target"
    pwd -P
  )
}

show_progress=1
compare_mode="quick"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || die "Missing value for --mode"
      compare_mode="$2"
      shift 2
      ;;
    --no-progress)
      show_progress=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[[ "$compare_mode" == "quick" || "$compare_mode" == "checksum" ]] || die "Unsupported mode: $compare_mode"
[[ $# -eq 2 ]] || {
  usage >&2
  exit 2
}

need_cmd rsync
need_cmd find

source_dir="$(abs_dir "$1")"
mounted_dir="$(abs_dir "$2")"

source_dir="${source_dir}/"
mounted_dir="${mounted_dir}/"

tmp_output="$(mktemp /tmp/verify-mounted-image.XXXXXX)"
tmp_output_raw="${tmp_output}.raw"
trap 'rm -f "$tmp_output" "$tmp_output_raw"' EXIT

printf 'Verifying mounted image\n'
printf '  source : %s\n' "$source_dir"
printf '  target : %s\n' "$mounted_dir"
printf '  mode   : %s\n' "$compare_mode"
printf '  compare: entries + symlinks + regular files'
if [[ "$compare_mode" == "quick" ]]; then
  printf ' (size+mtime)\n'
else
  printf ' (checksum)\n'
fi
printf '  ignore : owner/group/perms/ACL/xattrs\n'

printf 'Scanning source tree...\n'
source_entries="$(find "$source_dir" -mindepth 1 | wc -l | awk '{print $1}')"
printf '  source entries: %s\n' "$source_entries"

printf 'Scanning target tree...\n'
target_entries="$(find "$mounted_dir" -mindepth 1 | wc -l | awk '{print $1}')"
printf '  target entries: %s\n' "$target_entries"

rsync_opts=(
  -rlt
  --links
  --dry-run
  --delete
  --itemize-changes
  --omit-dir-times
  --no-perms
  --no-owner
  --no-group
  '--out-format=%i|%n%L'
)

if [[ "$compare_mode" == "checksum" ]]; then
  rsync_opts+=(-c)
fi

if [[ "$show_progress" -eq 1 ]]; then
  rsync_opts+=(--info=flist2)
else
  rsync_opts+=(--info=name0)
fi

printf 'Running rsync comparison...\n'
if ! rsync "${rsync_opts[@]}" "$source_dir" "$mounted_dir" 2>&1 | tee "$tmp_output_raw"; then
  die "rsync comparison failed"
fi

grep -E '^[><ch\.\*][fdLDS].*\|' "$tmp_output_raw" > "$tmp_output" || true

if [[ ! -s "$tmp_output" ]]; then
  printf 'No differences detected.\n'
  exit 0
fi

diff_count="$(wc -l < "$tmp_output" | awk '{print $1}')"
printf 'Differences detected: %s\n' "$diff_count"
cat "$tmp_output"
exit 1
