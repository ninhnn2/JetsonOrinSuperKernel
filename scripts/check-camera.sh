#!/usr/bin/env bash
# Check the CSI camera on the Jetson, and keep what it shows as evidence: which kernel and boot
# entry run, whether the camera driver and its device-tree node are there, the sensor's modes,
# a capture through the ISP (Argus) with its frame rate, and, where ucpeer-detect is on the board,
# a run of the chicken detector on the camera.
#
#   scripts/check-camera.sh                 machineai-gw → logs/camera-<release>-<date>.log
#   BOARD=user@host scripts/check-camera.sh
#
# Each check ends in PASS or FAIL; the exit code is the number of FAILs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BOARD="${BOARD:-machineai-gw}"
DETECTOR="${DETECTOR:-ma_capture-jetson}" # a checkout of ucpeer-detect in the board's home
on() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOARD" "$@"; }
KREL="$(on uname -r)" || { echo "check-camera.sh: $BOARD does not answer"; exit 1; }
mkdir -p "$HERE/logs"
LOG="$HERE/logs/camera-$KREL-$(date +%Y%m%d-%H%M).log"
fails=0
check() { # name, command on the board, a grep -E the output must match
	echo
	echo "=== $1"
	out="$(on "$2" 2>&1)"
	echo "$ $2"
	echo "$out"
	if grep -qE -- "$3" <<<"$out"; then echo "--> PASS"; else echo "--> FAIL"; fails=$((fails + 1)); fi
}

main() {
echo "check-camera.sh on $BOARD, $(date '+%F %T %z')"
check "board and Jetson Linux" "tr -d '\0' </proc/device-tree/model; echo; head -1 /etc/nv_tegra_release" "Orin Nano.*Super"
check "kernel running" "uname -a; cat /proc/cmdline" "$KREL"
check "boot entry" "c=/boot/extlinux/extlinux.conf; d=\$(sed -n 's/^DEFAULT //p' \$c); echo DEFAULT \$d; sed -n \"/^LABEL \$d\\\$/,/^\\\$/p\" \$c" "OVERLAYS .*camera"
check "camera driver loaded, built for this kernel" "lsmod | grep -E '^(nv_imx|tegra_camera|nvhost_nvcsi|nvhost_isp)'; modinfo -F vermagic nv_imx219; modinfo -n nv_imx219" "$KREL SMP"
check "video device" "ls -l /dev/video* /dev/media*; v4l2-ctl --list-devices" "imx219"
check "device-tree node the driver bound" "for d in /sys/bus/i2c/devices/*-0010; do echo \$d; readlink -f \$d/of_node; cat \$d/name; done" "cam_i2cmux/i2c@[01]/rbpcv2_imx219_[ac]@10"
check "sensor modes" "v4l2-ctl -d /dev/video0 --list-formats-ext" "1920x1080"
check "kernel messages about the camera" "sudo -n dmesg | grep -iE 'imx219|nvcsi|tegra-camrtc|vi5|tegra-capture' | tail -15; echo dmesg-read" "dmesg-read"
check "capture through the ISP: 300 frames, 1920x1080, mode 2, turned 180" \
	"t0=\$(date +%s.%N); timeout 60 gst-launch-1.0 -e nvarguscamerasrc sensor-id=0 sensor-mode=2 num-buffers=300 ! 'video/x-raw(memory:NVMM),width=1920,height=1080,framerate=30/1' ! nvvidconv flip-method=2 ! 'video/x-raw,format=I420' ! fakesink 2>&1 | grep -E 'Running with|Camera mode|Output Stream|Got EOS|ERROR|rror'; t1=\$(date +%s.%N); echo \"300 frames in \$(echo \"\$t1 - \$t0\" | bc) s\"" "Got EOS"
check "the chicken detector on the camera, 30 s" \
	"cd ~/$DETECTOR && test -x out/ucpeer-detect || { echo 'no ucpeer-detect on the board: skipped'; exit 0; }; timeout 90 out/ucpeer-detect --no-config --camera csi --rotate 180 --model out/models/coop-1280.onnx --watch chicken --headless --duration 30 --stats 10 --report /tmp/check-camera-report.json 2>&1 | grep -vE 'NvMM' | grep -E 'model|camera|stats|error|stopping' | cut -c1-240; python3 -c \"import json; r=json.load(open('/tmp/check-camera-report.json')); print('report:', {k: r[k] for k in r if k in ('frames','fps','latency','framesDecoded','framesInferred')})\" 2>/dev/null || true" "\[stats\] 1920x1080|skipped"
echo
echo "=== $fails check(s) failed"
}

main 2>&1 | tee "$LOG"
echo "log: $LOG"
exit "$(grep -c -- '--> FAIL' "$LOG")"
