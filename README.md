# Arch Linux ARM for Google Pixel 4 (google-flame)

This repository builds an AArch64 Arch Linux ARM userspace rootfs and a reference U-Boot build. Kernel builds live in the separate repository [ValidityValues/linux-sm8150-mainline](https://github.com/ValidityValues/linux-sm8150-mainline).

## Current device facts supplied for this project

- Product: `flame`, Snapdragon 855 / SM8150, 64 GB UFS.
- Active slot: `b`; slot B is marked successful. Slot A is marked unbootable.
- Physical `super`: `0x245800000` bytes.
- `userdata` is to remain untouched.
- Fastboot bootloader reports sizes for `system_b`, `vendor_b`, `product_b`, `system_ext_b`; some A-side queries return `variable not found`. This is not enough information to safely resize `super`.

## Workflows and artifacts

Open **Actions → Run workflow** in this repository:

- **Build Arch Linux ARM rootfs**: choose `none`, `plasma-desktop`, `xfce4`, `lxqt`, or `gnome`; choose a 4096/6144/8192 MiB ext4 artifact size. Default is Plasma Desktop and 6144 MiB.
- **Build SM8150 U-Boot (reference)**: builds the selected ref from `sm8150-mainline/u-boot` and exports the U-Boot binary variants, configuration, host image tools if built, `pixel4.txt` if present, source revision, and SHA-256 manifest.

The rootfs artifact contains:
- `flame-rootfs.tar.zst`: complete ARM64 root filesystem archive.
- `flame-rootfs.ext4` and `flame-rootfs.ext4.zst`: standalone ext4 filesystem and compressed copy.
- `packages-installed.txt`, `packages-to-install.txt`, `firmware-audit.txt`, `desktop-environment.txt`, `display-manager.txt`, `MANIFEST.txt`, and `SHA256SUMS`.

The userspace enables NetworkManager and BlueZ at boot and installs `wpa_supplicant`, `iwd`, `wireless-regdb`, `bluez-utils`, `linux-firmware-qcom`, `linux-firmware-atheros`, and `linux-firmware-whence`. This supplies userspace services and redistributable Qualcomm/Atheros firmware files. **It does not by itself prove Wi-Fi/Bluetooth works on this phone**: the selected kernel must include the relevant drivers, the Pixel 4 DTS must correctly enable/configure WCN399x, and any device-specific calibration/firmware requirements must be met.

The matching kernel, Pixel 4 DTB, and modules are built in [the separate kernel repository](https://github.com/ValidityValues/linux-sm8150-mainline). The U-Boot artifact is built separately here. Each artifact has its own manifest and checksums. CI builds do not flash the device.

## Important: rootfs in super, not userdata

We will target a **dedicated logical partition inside Android's dynamic `super` container**, not `userdata`. Do not run `fastboot flash super flame-rootfs.ext4`: a standalone ext4 filesystem is not an Android `super.img`; flashing it to the physical container would overwrite LP metadata and existing logical partitions.

Before any write:

1. Capture the full current partition map and LP metadata with `lpdump` (from Android/root or fastbootd as supported).
2. Determine free extents, group limits, current snapshots/COW partitions, and the exact size of all logical partitions.
3. Make verified backups of the existing `super` contents/metadata and anything to be resized; copy them off-device. A 9.35 GB physical partition needs enough host storage.
4. Save the original boot images and `fastboot getvar all`; verify a recovery path and Android B boots.
5. Create a dedicated logical partition only after the layout has been reviewed, and only size the ext4 image to a confirmed available target. Never overwrite active B logical partitions or blindly assume A-side partitions exist.

The supplied fastboot output is not a full LP metadata dump, so no flash/resize command is provided yet. It is safer to first run `scripts/collect-layout.sh` and inspect its results. Serial numbers and device identifiers should be redacted before sharing.

## Rootfs details

The generic Arch Linux ARM AArch64 tarball provides a glibc-based ARM64 userspace. It is not a device-specific kernel. The matching kernel, DTB and modules must be built together from the device-support source. An ext4 image from the workflow is a filesystem image only, not a boot image and not a flashable `super.img`.

If no SSH public key is supplied at build time, SSH remains disabled. Never put a private key or password into workflow inputs.

## References

- Arch Linux ARM generic AArch64: https://archlinuxarm.org/platforms/armv8/generic
- SM8150 Mainline kernel: https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux
- U-Boot Qualcomm phone notes: https://docs.u-boot-project.org/en/latest/board/qualcomm/phones.html
