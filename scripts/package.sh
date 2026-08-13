#!/bin/sh
set -eu

version="${1:-}"
output_dir="${2:-dist}"

case "$version" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) printf 'Usage: %s vX.Y.Z [output-directory]\n' "$0" >&2; exit 1 ;;
esac

metadata_version=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' legadosync.koplugin/_meta.lua)
if [ "v$metadata_version" != "$version" ]; then
    printf 'Version mismatch: tag is %s, metadata is v%s\n' "$version" "$metadata_version" >&2
    exit 1
fi

mkdir -p "$output_dir"
archive="$output_dir/legadosync-koreader-$version.zip"
rm -f "$archive" "$archive.sha256"
if command -v zip >/dev/null 2>&1; then
    zip -9 -X -r "$archive" legadosync.koplugin -x '*/.*'
elif command -v bsdtar >/dev/null 2>&1; then
    bsdtar --format zip -cf "$archive" legadosync.koplugin
else
    printf 'Either zip or bsdtar is required.\n' >&2
    exit 1
fi
(
    cd "$output_dir"
    sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256"
)

printf 'Created %s\n' "$archive"
printf 'Created %s.sha256\n' "$archive"
