# Arch Linux ARM for Google Pixel 4 (google-flame)

This repository builds an AArch64 Arch Linux ARM userspace rootfs and a reference U-Boot build. Kernel builds live in the separate repository [ValidityValues/linux-sm8150-mainline](https://github.com/ValidityValues/linux-sm8150-mainline).

## Current device facts supplied for this project

- Product: `flame`, Snapdragon 855 / SM8150, 64 GB UFS.
- Active slot: `b`; slot B is marked successful. Slot A is marked unbootable.
- Physical `super`: `0x245800000` bytes.
- `userdata` is to remain untouched.
- Fastboot bootloader reports sizes for `system_b`, `vendor_b`, `product_b`, `system_ext_b`; some A-side queries return `variable not found`. This is not enough information to safely resize `super`.

## Workflows

- **Build Arch Linux ARM rootfs:** verifies and extracts the generic AArch64 rootfs, produces a compressed rootfs archive and standalone ext4 image, then uploads checksums and a manifest.
- **Build SM8150 U-Boot reference:** builds the configured upstream/project reference and archives outputs. Build output is not a validated Pixel 4 boot image.

Run them under **Actions → workflow → Run workflow**. Neither workflow flashes the phone.

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
