# Pixel 4 boot layout: U-Boot, FIT and rootfs.img

## Conclusion

For the chosen layout—preserve Android slot B and put Arch Linux ARM in a new logical partition inside Android's physical `super`—a standalone `rootfs.img` is **not a self-booting image**. It is an ext4 filesystem image.

A U-Boot FIT image (commonly `boot.itb`) is a different object: it packages the Linux kernel and the matching device tree, and may also package an initramfs. U-Boot loads the FIT into RAM and starts it with `bootm`. Alternatively it can start an ARM64 flat `Image` with `booti`, passing the initrd and FDT addresses. U-Boot can load individual files from a normal, accessible ext4 block-device partition using `ext4load`. See the upstream U-Boot docs:
- https://docs.u-boot-project.org/en/latest/usage/cmd/bootm.html
- https://docs.u-boot-project.org/en/latest/usage/cmd/booti.html
- https://docs.u-boot-project.org/en/latest/usage/filesystems/ext4.html

## Why putting /boot inside rootfs.img is not enough here

Android's `super` is a physical GPT partition that stores metadata and extents for logical partitions. Android's first-stage `init` parses that metadata and creates the logical block devices with `dm-linear`. Those logical partitions are not ordinary GPT partitions available automatically to the bootloader. See the Android documentation:
- https://source.android.com/docs/core/ota/dynamic_partitions/implement
- https://source.android.com/docs/core/ota/dynamic_partitions/ab_launch

Consequently, putting `/boot/Image`, the Pixel 4 DTB, and an initramfs inside an ext4 image that lives as a logical partition inside `super` does not by itself let ordinary U-Boot `ext4load` read those files. U-Boot first needs access to the block device/partition containing the filesystem. The standard dynamic-partition mapping happens later in Android userspace, not automatically in U-Boot.

This project now targets the device-specific source/ref supplied for Pixel 4:
- Source: https://gitlab.com/andrewgigena/u-boot
- Branch: `andrew/google-flame`
- Config fragments: `qcom_defconfig qcom-phone.config sm8150-google-flame.config`
- DTB: `.output/dts/upstream/src/arm64/qcom/sm8150-google-flame.dtb`

The U-Boot workflow applies the supplied `preboot` blkmap recipe and packages `u-boot-nodtb.bin.gz + sm8150-google-flame.dtb` into Android-format `u-boot.img` using the given base, kernel offset, and page size. This means ABL can potentially start this U-Boot image through the normal Android boot-image path. A successful build still does not prove the device will boot it; use temporary `fastboot boot` where the image format/bootloader permits and keep a tested restore path.

### What the supplied blkmap preboot actually means

The supplied preboot calculates the physical start and size of the Android `userdata` partition, then creates a virtual block device named `root` mapped over that entire region. This lets U-Boot's partition scanner inspect a nested disk/partition layout stored *inside userdata* and find an EFI loader there. It does not create a mapping for Android logical partitions inside `super`.

**Important trade-off:** the exact Nura/andrew recipe uses `userdata` as backing storage for the nested boot-file layout. Building U-Boot with this setting does not modify the phone, but installing the nested layout does write to `userdata`. If the requirement remains to leave `userdata` entirely untouched, do not install that nested layout there; a different U-Boot-readable boot-file source must be designed.

## Correct division of responsibilities

1. **`rootfs.img`** — one ext4 filesystem containing Arch Linux ARM, the selected DE, NetworkManager, BlueZ, firmware files and packages. It is built locally with `scripts/build-rootfs.sh`; there is no hosted rootfs build workflow.
2. **`u-boot.img`** — the Android boot-image-format U-Boot artifact produced from `andrew/google-flame`. It is a separate boot-chain image, not part of the ext4 root filesystem.
3. **Linux boot files** — the kernel `Image`, Pixel 4 DTB, and matching modules can optionally be copied into `/boot` inside `rootfs.img`. This helps only when U-Boot/EFI can actually read that filesystem. The current blkmap recipe scans a nested layout in `userdata`, not a dynamic partition inside `super`.
4. **Early root mount** — because the rootfs lives inside `super`, the initramfs must create a `dm-linear` mapping for the chosen logical partition using the actual LP metadata, then mount that mapped device. A plain `root=/dev/sdaN` does not identify a logical partition inside `super`.

## What is still needed before a genuinely bootable image

- A current `lpdump` report for both metadata slots, with serial numbers redacted, so we can determine free extents and create a dedicated logical partition without altering slot B's logical partitions.
- A decided boot source that U-Boot can read before Linux starts (or explicit proof that our U-Boot branch implements Android LP mapping).
- A tested early-userspace LP mapper/initramfs, plus a matching kernel, DTB and modules.
- A restorable backup of original `super` data and LP metadata before any resize/write.

Until these conditions are met, the local builder produces the ext4 `rootfs.img` and GitHub Actions builds the kernel/U-Boot artifacts separately. Do not claim the rootfs is bootable or flash the standalone ext4 image to the physical `super` partition. Building U-Boot does not write to the device; installing the nested blkmap layout described above would write to `userdata`.
