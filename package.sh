#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${1:-$source_dir/dist}"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/sleep-guard-package.XXXXXX")"
# This directory is created exclusively for this packaging operation.
trap 'rm -rf -- "$staging_dir"' EXIT
bash "$source_dir/build.sh" "$staging_dir/build"
app="$staging_dir/build/休眠哨兵.app"
mkdir -p "$output_dir" "$staging_dir/verify"
archive="$output_dir/休眠哨兵.zip"
ditto --norsrc --noextattr -c -k --keepParent "$app" "$archive"
ditto --norsrc --noextattr -x -k "$archive" "$staging_dir/verify"
codesign --verify --deep --strict "$staging_dir/verify/休眠哨兵.app"
printf '%s\n' "安装包已生成并通过解压签名检查：$archive"
