#!/bin/bash
# Makes the two zips from package/ (rebuild package/Playground/Playground.pck first with pack.gd, see the README):
#   out/Playground-mod.zip         the Playground folder to drop into GDWeave/mods
#   out/Playground-<version>.zip   the Thunderstore upload
set -e
cd "$(dirname "$0")"
mkdir -p out
V=$(python3 -c "import json;print(json.load(open('thunderstore/manifest.json'))['version_number'])")
rm -f out/Playground-mod.zip out/Playground-$V.zip
(cd package && zip -qr ../out/Playground-mod.zip Playground)
T=$(mktemp -d)
cp thunderstore/manifest.json thunderstore/README.md thunderstore/CHANGELOG.md thunderstore/icon.png $T/
mkdir -p $T/GDWeave/mods/Playground
cp package/Playground/manifest.json package/Playground/Playground.pck $T/GDWeave/mods/Playground/
(cd $T && zip -qr - .) > out/Playground-$V.zip
rm -rf $T
echo "out/Playground-mod.zip"
echo "out/Playground-$V.zip"
