#!/bin/zsh
# Builds a styled installer DMG: scripts/make-dmg.sh <Blablador.app> <output.dmg>
set -euo pipefail
here=${0:A:h}
app=${1:A}
out=${2:A}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift "$here/dmg/background.swift" "$work/background.png" 1
swift "$here/dmg/background.swift" "$work/background@2x.png" 2
# dmgbuild picks up background@2x.png next to background.png for Retina screens.

if ! command -v dmgbuild >/dev/null; then
  python3 -m venv "$work/venv"
  "$work/venv/bin/pip" install -q dmgbuild
  dmgbuild=("$work/venv/bin/dmgbuild")
else
  dmgbuild=(dmgbuild)
fi
rm -f "$out"
"${dmgbuild[@]}" -s "$here/dmg/settings.py" -D app="$app" -D background="$work/background.png" Blablador "$out"
hdiutil verify "$out" >/dev/null && echo "Created $out"
