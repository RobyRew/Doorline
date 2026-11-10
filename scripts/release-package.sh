#!/bin/bash
# Wraps a built Doorline.app into a release file.
#   release-package.sh ipa <Doorline.app> <Doorline-platform.ipa>
#   release-package.sh dmg <Doorline.app> <Doorline-macOS.dmg>
set -euo pipefail

kind="${1:?ipa or dmg}"
app="${2:?path to Doorline.app}"
out="${3:?output path}"

if [[ ! -d "$app" ]]; then
  echo "App not found: $app" >&2
  exit 1
fi

mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

case "$kind" in
  ipa)
    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/Payload"
    cp -R "$app" "$stage/Payload/Doorline.app"
    rm -f "$out"
    (cd "$stage" && zip -qry "$out" Payload)
    ;;
  dmg)
    rm -f "$out"
    hdiutil create -volname "Doorline" -srcfolder "$app" -ov -format UDZO "$out"
    ;;
  *)
    echo "Unknown package kind: $kind" >&2
    exit 1
    ;;
esac

echo "Wrote $out"
