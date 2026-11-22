#!/usr/bin/env bash
# Install a kernel scripts/build.sh made on the Jetson, BESIDE the one it runs, and boot it.
# The running kernel, its modules and its boot entry are left as they are, to go back to.
#
#   scripts/deploy.sh                  5.15.148-tegra-orinsuper to machineai-gw, as the default
#   scripts/deploy.sh --reboot         ... then reboot into it and wait for the board
#   scripts/deploy.sh --back --reboot  the boot entries as they were before, and reboot
#   BOARD=user@host KREL=<release> LABEL=<entry> scripts/deploy.sh
#
# The new boot entry is the board's current default entry with LINUX and INITRD changed: FDT,
# OVERLAYS (the camera overlay that jetson-io set) and APPEND stay, so the camera stays
# configured. Needs sudo on the board without a password (sudo -n); keeps no password.
# Every step goes to logs/deploy-<release>.log.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
B="${BUILD:-$HERE/build}"
BOARD="${BOARD:-machineai-gw}"
KREL="${KREL:-5.15.148-tegra-orinsuper}"
LABEL="${LABEL:-orinsuper}"
CONF=/boot/extlinux/extlinux.conf
SAVED="$CONF.before-$KREL" # the boot entries as they were before the first deploy of this kernel
reboot=0 back=0
for a in "$@"; do
	case "$a" in
	--reboot) reboot=1 ;;
	--back) back=1 ;;
	*) echo "deploy.sh: --reboot, --back" >&2; exit 2 ;;
	esac
done
mkdir -p "$HERE/logs"
LOG="$HERE/logs/deploy-$KREL.log"
on() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOARD" "$@"; }
step() { echo "=== $(date '+%F %T') $*"; }

wait_for_board() {
	sleep 20
	for _ in $(seq 1 60); do
		on true 2>/dev/null && { on 'echo "up: $(uname -r), $(uptime -p)"'; return 0; }
		sleep 5
	done
	echo "deploy.sh: $BOARD not back after 5 minutes: choose the old entry at its boot menu (serial)"
	return 1
}

main() {
step "deploy of $KREL to $BOARD, as boot entry $LABEL"
on 'sudo -n true' || { echo "deploy.sh: sudo on $BOARD asks for a password"; exit 1; }
on "uname -r; grep -E '^(DEFAULT|TIMEOUT)' $CONF"

if [ "$back" = 1 ]; then
	step "the boot entries as they were before $KREL"
	on "sudo -n test -f $SAVED && sudo -n cp $SAVED $CONF && grep -E '^(DEFAULT|TIMEOUT)' $CONF"
else
	IMG="$B/Image-$KREL" MODS="$B/modules-$KREL.tar.gz"
	test -f "$IMG" && test -f "$MODS" || { echo "deploy.sh: no $IMG or $MODS: scripts/build.sh first"; exit 1; }

	step "[1/4] the boot entries saved once, as $SAVED"
	on "sudo -n cp -n $CONF $SAVED; ls -l $SAVED"

	step "[2/4] Image and modules to the board"
	scp -q "$IMG" "$BOARD:/tmp/Image-$KREL"
	scp -q "$MODS" "$BOARD:/tmp/modules-$KREL.tar.gz"
	on "sha256sum /tmp/Image-$KREL /tmp/modules-$KREL.tar.gz"

	step "[3/4] installed: /lib/modules/$KREL, /boot/Image-$KREL, its own initrd"
	on "set -e
		sudo -n rm -rf /lib/modules/$KREL
		sudo -n tar -C /lib/modules -xzf /tmp/modules-$KREL.tar.gz
		sudo -n depmod -a $KREL
		echo \"modules: \$(find /lib/modules/$KREL -name '*.ko' | wc -l)\"
		sudo -n cp /tmp/Image-$KREL /boot/Image-$KREL
		sudo -n rm -f /boot/initrd.img-$KREL
		sudo -n update-initramfs -c -k $KREL 2>&1 | tail -1
		ls -l /boot/Image-$KREL /boot/initrd.img-$KREL"

	step "[4/4] boot entry $LABEL: the default entry's, with this kernel; made the default"
	on "sudo -n python3 - $CONF $KREL $LABEL" <<'PY'
import re, sys
conf, krel, label = sys.argv[1:4]
lines = open(conf).read().split("\n")
default = next(re.match(r"DEFAULT\s+(\S+)", l).group(1) for l in lines if re.match(r"DEFAULT\s+\S", l))
starts = [i for i, l in enumerate(lines) if re.match(r"LABEL\s+\S", l)]
blocks = {lines[s].split()[1]: (s, starts[n + 1] if n + 1 < len(starts) else len(lines)) for n, s in enumerate(starts)}
s, e = blocks[default]
new = []
for l in lines[s:e]:
    if not l.strip() or l.strip().startswith("#"):
        continue
    key, pad = l.split()[0], l[: len(l) - len(l.lstrip())]
    if key == "LABEL":
        new.append(f"LABEL {label}")
    elif key == "MENU":
        new.append(f"{pad}MENU LABEL {krel}, boot config of {default}")
    elif key == "LINUX":
        new.append(f"{pad}LINUX /boot/Image-{krel}")
        new.append(f"{pad}INITRD /boot/initrd.img-{krel}")
    elif key != "INITRD":
        new.append(l)
if label in blocks and label != default:  # an earlier deploy's entry: replaced
    s2, e2 = blocks[label]
    lines = lines[:s2] + lines[e2:]
elif label == default:
    lines = lines[:s] + lines[e:]
lines = [re.sub(r"^DEFAULT\s+\S+", f"DEFAULT {label}", l) for l in lines]
text = "\n".join(lines).rstrip("\n") + "\n\n" + "\n".join(new) + "\n"
open(conf, "w").write(text)
print(f"from entry {default}:")
print("\n".join(new))
PY
	on "grep -E '^(DEFAULT|TIMEOUT)' $CONF"
fi

if [ "$reboot" = 1 ]; then
	step "reboot"
	on 'sudo -n systemctl reboot' || true
	wait_for_board
	on "uname -a; grep -E '^DEFAULT' $CONF"
fi
step "done"
}

main 2>&1 | tee -a "$LOG"
