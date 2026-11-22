# JetsonOrinSuperKernel

The Linux kernel for the **Jetson Orin Nano Super Developer Kit** (NVIDIA Jetson Linux R36.4.4),
tested with an IMX219 CSI camera.

- Commit 1: NVIDIA's kernel sources, unmodified (checksums in its message).
- Commit 2: camera support: this README, `scripts/` and `logs/`. The kernel sources are not changed.

## 1. Flash the board (NVMe SSD)

From an Ubuntu x86 PC, as in NVIDIA's
[Quick Start](https://docs.nvidia.com/jetson/archives/r36.4.4/DeveloperGuide/IN/QuickStart.html).
**This erases the SSD.**

1. Download the BSP (746 MB) and the sample root filesystem (1.8 GB):
   - [Jetson_Linux_R36.4.4_aarch64.tbz2](https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Jetson_Linux_r36.4.4_aarch64.tbz2)
   - [Tegra_Linux_Sample-Root-Filesystem_R36.4.4_aarch64.tbz2](https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Tegra_Linux_Sample-Root-Filesystem_r36.4.4_aarch64.tbz2)
2. Prepare them:
   ```sh
   tar xf Jetson_Linux_R36.4.4_aarch64.tbz2
   sudo tar xpf Tegra_Linux_Sample-Root-Filesystem_R36.4.4_aarch64.tbz2 -C Linux_for_Tegra/rootfs/
   cd Linux_for_Tegra/
   sudo ./tools/l4t_flash_prerequisites.sh
   sudo ./apply_binaries.sh
   ```
3. Recovery mode: unplug power, short the **REC** and **GND** pins of the 12-pin button header with
   a jumper, plug power back, connect the board's USB-C port to the PC. `lsusb` must show
   `0955:7523 NVIDIA Corp.`
4. Flash with the Super configuration:
   ```sh
   sudo ./tools/kernel_flash/l4t_initrd_flash.sh --external-device nvme0n1p1 \
     -c tools/kernel_flash/flash_l4t_t234_nvme.xml -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
     --showlogs --network usb0 jetson-orin-nano-devkit-super internal
   ```
5. Remove the jumper. The board reboots into the Ubuntu setup on its display. Then, on the board:
   `sudo apt update && sudo apt upgrade` (the tested board runs the 36.4.7 update).

## 2. Enable the camera

The IMX219 (Raspberry Pi Camera v2 and compatibles) works with NVIDIA's own driver and device-tree
overlay; no kernel change is needed. JetPack enables no camera overlay by default, so select the
one for the connector the camera is on (power off before plugging the cable):

| Connector | Overlay |
|---|---|
| CAM0 | Camera IMX219-A |
| CAM1 | Camera IMX219-C |

```sh
sudo /opt/nvidia/jetson-io/jetson-io.py     # there is no "jetson-io" command
```

In its menu: **Configure Jetson 24pin CSI Connector** → **Configure for compatible hardware** →
the overlay → **Save pin changes** → **Save and reboot to reconfigure pins**. After the reboot,
`/dev/video0` exists and this captures from the camera:

```sh
gst-launch-1.0 -e nvarguscamerasrc sensor-id=0 num-buffers=30 ! fakesink   # ends with "Got EOS"
```

## 3. If the camera is not detected

No `/dev/video0`? Check what the kernel says: `sudo dmesg | grep imx219`.

| You see | Cause | Fix |
|---|---|---|
| Nothing | No camera overlay in the boot entry | Step 2 |
| `probe of 9-0010 failed with error -121` | The camera does not answer on I2C: loose, unplugged or reversed cable, or the overlay for the other connector | Power off, reseat the cable, check CAM0 vs CAM1 |
| `subdev imx219 9-0010 bound` | Detected | Capture as in step 2 |

The test board had both: no camera until the overlay was selected, and later error -121 for six
boots until the cable was reseated.

## 4. Build and install this kernel (optional)

Only needed to change the kernel or its device trees.

```sh
sudo apt install build-essential bc flex bison libssl-dev gcc-aarch64-linux-gnu rsync kmod
scripts/build.sh                    # cross-compile on an x86 PC, into build/
scripts/deploy.sh --reboot          # install on the board next to its kernel, boot into it
scripts/check-camera.sh             # 10 camera checks, logged in logs/
scripts/deploy.sh --back --reboot   # back to the boot entry the board had before
```

`deploy.sh` never overwrites the running kernel or its boot entry. The new entry is a copy of the
current one with only the kernel changed, so the camera overlay stays. It needs passwordless
`sudo` on the board; `BOARD=user@host` picks the board (default `machineai-gw`).

## Tested

Jetson Orin Nano Super, Jetson Linux R36.4.7, IMX219 on CAM1, 22 Nov 2026:

| | Board's kernel before | This repo's kernel |
|---|---|---|
| Camera checks | 10/10 pass | 10/10 pass |
| Camera / YOLO detector | 30 / 19.7 fps | 30 / 19.7 fps |
| Sensor to detection (median) | 110 ms | 110 ms |

The build took 13 minutes on 32 cores: 1090 modules, no errors. The device tree and the camera
overlay it builds are byte-identical to NVIDIA's files on the board.

Logs: [build](logs/build-5.15.148-tegra-orinsuper.log.gz) ·
[deploy](logs/deploy-5.15.148-tegra-orinsuper.log) ·
[camera before](logs/camera-5.15.148-tegra-klab-20261122-0231.log) ·
[camera after](logs/camera-5.15.148-tegra-orinsuper-20261122-0244.log).
The build log names commit `348a10c`: the same source tree as commit 1, before its author was
renamed.
