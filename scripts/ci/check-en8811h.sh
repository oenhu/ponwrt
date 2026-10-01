#!/usr/bin/env bash
# Compile the Airoha EN8811H port with the same kernel and PHY backports as PonWrt.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_root=${1:-"$repo_root/tmp/en8811h-check"}
mkdir -p "$work_root"
work_root=$(cd "$work_root" && pwd)

kernel_series=$(awk -F ':=' '/^KERNEL_PATCHVER:=/ { print $2 }' \
  "$repo_root/target/linux/airoha/Makefile")
if [[ "$kernel_series" != 6.18 ]]; then
  printf 'This check currently supports the 6.18 patch series.\n' >&2
  exit 1
fi
kernel_metadata="$repo_root/target/linux/generic/kernel-$kernel_series"
kernel_suffix=$(awk -v key="LINUX_VERSION-$kernel_series" \
  '$1 == key && $2 == "=" { print $3 }' "$kernel_metadata")
kernel_version="$kernel_series$kernel_suffix"
kernel_hash=$(awk -v key="LINUX_KERNEL_HASH-$kernel_version" \
  '$1 == key && $2 == "=" { print $3 }' "$kernel_metadata")
if [[ -z "$kernel_suffix" || ${#kernel_hash} != 64 ]]; then
  printf 'Cannot determine the pinned kernel version/checksum.\n' >&2
  exit 1
fi

archive=${KERNEL_ARCHIVE:-"$work_root/linux-$kernel_version.tar.xz"}
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 \
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$kernel_version.tar.xz" \
    --output "$archive"
fi
printf '%s  %s\n' "$kernel_hash" "$archive" | sha256sum --check

source_root=$(mktemp -d "$work_root/kernel.XXXXXXXX")
tar -xJf "$archive" --strip-components=1 -C "$source_root"
backports="$repo_root/target/linux/generic/backport-6.18"
for patch_file in "$backports"/785-v7.0-0[1-7]-*.patch \
                  "$backports"/785-v7.0-11-*.patch \
                  "$backports"/786-v7.3-*.patch \
                  "$repo_root"/target/linux/airoha/patches-6.18/790-net-phy-air-en8811h-port-v2.0.7.patch; do
  patch --directory="$source_root" --batch --fuzz=0 -p1 < "$patch_file"
done

build_args=(ARCH=arm64)
if [[ $(uname -m) != aarch64 ]]; then
  build_args+=(CROSS_COMPILE=aarch64-linux-gnu-)
fi
jobs=${JOBS:-$(nproc)}
cd "$source_root"
make "${build_args[@]}" defconfig
scripts/config --enable MODULES --enable COMMON_CLK --enable OF \
  --enable PHYLIB --enable PHYLIB_LEDS --module AIR_EN8811H_PHY
make "${build_args[@]}" olddefconfig
cp .config "$work_root/baseline.config"

for mode in debug-on debug-off debug-global-off; do
  log_file="$work_root/$mode.log"
  (
    cp "$work_root/baseline.config" .config
    case "$mode" in
      debug-on)
        scripts/config --enable DEBUG_FS --enable AIR_EN8811H_PHY_DEBUGFS
        ;;
      debug-off)
        scripts/config --enable DEBUG_FS --disable AIR_EN8811H_PHY_DEBUGFS
        ;;
      debug-global-off)
        scripts/config --disable DEBUG_FS --disable AIR_EN8811H_PHY_DEBUGFS
        ;;
    esac
    make "${build_args[@]}" olddefconfig
    if [[ "$mode" == debug-on ]]; then
      grep -qx 'CONFIG_AIR_EN8811H_PHY_DEBUGFS=y' .config
    else
      ! grep -qx 'CONFIG_AIR_EN8811H_PHY_DEBUGFS=y' .config
    fi
    make "${build_args[@]}" -j"$jobs" modules_prepare
    # Rebuild the object after changing the optional diagnostic configuration.
    rm -f drivers/net/phy/air_en8811h.o drivers/net/phy/.air_en8811h.o.cmd
    make "${build_args[@]}" -j"$jobs" W=1 KCFLAGS=-Werror \
      drivers/net/phy/air_en8811h.o drivers/phy/phy-common-props.o
    cp .config "$work_root/$mode.config"
    cp drivers/net/phy/air_en8811h.o "$work_root/air_en8811h-$mode.o"
    file drivers/net/phy/air_en8811h.o
  ) 2>&1 | tee "$log_file"
done
printf 'EN8811H ARM64 compilation passed in all three configurations.\n'
