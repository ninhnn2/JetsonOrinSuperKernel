#!/usr/bin/env bash
# Cross-compile this tree (NVIDIA Jetson Linux R36.4.4) for a Jetson Orin Nano Super, on an x86
# PC: the kernel Image, the in-tree and out-of-tree modules (nvgpu, nvidia-oot: the IMX219 and
# IMX477 camera drivers among them) and the device trees (the camera overlays among them).
#
#   scripts/build.sh                     LOCALVERSION -tegra-orinsuper, into build/
#   LV=-tegra-test scripts/build.sh      another variant beside it
#
# Needs: apt install build-essential bc flex bison libssl-dev gcc-aarch64-linux-gnu rsync kmod
#
# The tree is built in a copy (build/out<LV>), so the committed sources stay as they are. Out:
#   build/Image-<release>, build/modules-<release>.tar.gz, build/dtbs-<release>/ (DTB + overlays)
#   logs/build-<release>.log.gz   every line of the build; the summary at its end
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LV="${LV:--tegra-orinsuper}"
B="${BUILD:-$HERE/build}"
OUT="$B/out$LV"
STAGE="$B/stage$LV"
JOBS="$(nproc)"
export ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}" LC_ALL=C
mkdir -p "$B" "$HERE/logs"
LOG="$B/build$LV.log"
KSRC="$OUT/kernel/kernel-jammy-src"
step() { echo "=== $(date '+%F %T') $*"; }

main() {

step "build of $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo '?') on $(hostname), $JOBS jobs"
"${CROSS_COMPILE}gcc" --version | head -1

step "[1/6] the sources into $OUT"
mkdir -p "$OUT/kernel"
rsync -a --delete "$HERE/kernel/kernel-jammy-src" "$OUT/kernel/"
cp -a "$HERE/kernel/Makefile" "$OUT/kernel/"
for d in nvethernetrm nvgpu nvidia-oot hwpm hardware nvdisplay kernel-devicetree; do
	rsync -a --delete "$HERE/$d" "$OUT/"
done
cp -a "$HERE/Makefile" "$OUT/"

step "[2/6] the kernel: Image, in-tree modules, LOCALVERSION $LV (defconfig as NVIDIA ships it)"
time make -C "$OUT/kernel" version="$LV" NPROC="$JOBS"
test -f "$KSRC/arch/arm64/boot/Image" || { echo "build.sh: no Image"; exit 1; }

step "[3/6] the out-of-tree modules (nvgpu, nvidia-oot, hwpm, nvdisplay, nvethernetrm)"
export KERNEL_HEADERS="$KSRC" KERNEL_OUTPUT="$KSRC"
time make -C "$OUT" modules -j"$JOBS"
for ko in nvgpu/drivers/gpu/nvgpu/nvgpu.ko nvidia-oot/drivers/media/i2c/nv_imx219.ko nvidia-oot/drivers/media/i2c/nv_imx477.ko; do
	test -f "$OUT/$ko" || { echo "build.sh: no $ko"; exit 1; }
done

step "[4/6] the device trees"
time make -C "$OUT" dtbs -j"$JOBS"

step "[5/6] the modules staged for the board (stripped)"
rm -rf "$STAGE"
mkdir -p "$STAGE"
make -C "$KSRC" LOCALVERSION="$LV" INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 \
	modules_install -j"$JOBS" >/dev/null
make -C "$OUT" INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_DIR=updates INSTALL_MOD_STRIP=1 \
	modules_install >/dev/null

step "[6/6] packed"
KREL="$(cat "$KSRC/include/config/kernel.release")"
cp "$KSRC/arch/arm64/boot/Image" "$B/Image-$KREL"
tar -C "$STAGE/lib/modules" -czf "$B/modules-$KREL.tar.gz" "$KREL"
rm -rf "$B/dtbs-$KREL"
cp -a "$OUT/kernel-devicetree/generic-dts/dtbs" "$B/dtbs-$KREL"
echo "kernel.release  $KREL"
echo "modules         $(find "$STAGE/lib/modules/$KREL" -name '*.ko' | wc -l)"
echo "camera drivers  $(find "$STAGE/lib/modules/$KREL" -name 'nv_imx*.ko' -printf '%f ')"
(cd "$B" && sha256sum "Image-$KREL" "modules-$KREL.tar.gz" \
	"dtbs-$KREL/tegra234-p3768-0000+p3767-0005-nv-super.dtb" \
	"dtbs-$KREL/tegra234-p3767-camera-p3768-imx219-C.dtbo" \
	"dtbs-$KREL/tegra234-p3767-camera-p3768-imx219-A.dtbo")
step "done"
}

# every line to the terminal and to the log; the log kept, compressed, once the build has ended
main 2>&1 | tee "$LOG"
gzip -9c "$LOG" >"$HERE/logs/build-$(cat "$KSRC/include/config/kernel.release").log.gz"
