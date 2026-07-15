#!/usr/bin/env bash
set -euo pipefail

source_root=${1:?source root is required}
output_root=${2:?output root is required}
git_sha=${3:-unknown}
build_root=/root/k7bridge-local-build

rm -rf "$build_root"
mkdir -p "$build_root" "$output_root"
find "$output_root" -maxdepth 1 -type f -name '*.deb' -delete
rsync -a --delete --exclude .git --exclude outputs "$source_root/" "$build_root/"
find "$build_root" -type d -exec chmod 0755 {} +
find "$build_root" -type f -exec chmod 0644 {} +
chmod 0755 "$build_root/gateway/layout/DEBIAN/postinst"
chmod 0755 "$build_root/gateway/layout/usr/local/bin/k7-audio-probe-session"

short_sha=${git_sha:0:7}
build_number=$(date -u +%Y%m%d%H%M%S)
version="0.1.0+local.${build_number}.${short_sha}"
sed -i -E "s/^Version:.*/Version: ${version}/" "$build_root/gateway/control"

export THEOS=/opt/theos
export PATH="$THEOS/toolchain/linux/iphone/bin:$PATH"
make -C "$build_root/gateway" clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

cp "$build_root"/gateway/packages/*.deb "$output_root/"
printf 'Built %s\n' "$version"
find "$output_root" -maxdepth 1 -type f -name '*.deb' -printf '%f\n'
