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

The SM8150 U-Boot reference artifact built by this project has UFS/SCSI, ext4 loading, `booti`, `bootm`, FIT-related boot commands and Android boot-image support in its configuration. However, this is not proof that the branch supports parsing Android LP metadata and exposing a custom logical partition to `ext4load`. The current build used `qcom_defconfig`; it is a reference build, not a verified Pixel 4 boot image. Do not flash it on that basis alone.

## Correct division of responsibilities

1. **`rootfs.img`** — one ext4 filesystem containing the full Arch Linux ARM installation (the desktop, NetworkManager, BlueZ, libraries, and packages). The CI artifact is compressed as `rootfs.img.zst`; decompress it to obtain `rootfs.img`.
2. **Boot bundle** — a U-Boot-readable FIT image (`boot.itb`) containing the matched kernel `Image` and `sm8150-google-flame.dtb`; a working system rooted inside `super` also needs an initramfs that maps the Android LP extents to a Linux device-mapper block device before mounting the root filesystem.
3. **Boot source** — U-Boot must load the FIT from a source it can actually access: a suitable physical boot partition/filesystem, or a temporary network/host-loaded path. Storing the FIT only inside the logical rootfs partition in `super` requires LP parsing in U-Boot, which has not been verified for the current branch.
4. **Early root mount** — because the rootfs lives inside `super`, the initramfs must create a `dm-linear` mapping for the chosen logical partition using the actual LP metadata, then mount that mapped device. A plain `root=/dev/sdaN` does not identify a logical partition inside `super`.

## What is still needed before a genuinely bootable image

- A current `lpdump` report for both metadata slots, with serial numbers redacted, so we can determine free extents and create a dedicated logical partition without altering slot B's logical partitions.
- A decided boot source that U-Boot can read before Linux starts (or explicit proof that our U-Boot branch implements Android LP mapping).
- A tested early-userspace LP mapper/initramfs, plus a matching kernel, DTB and modules.
- A restorable backup of original `super` data and LP metadata before any resize/write.

Until these conditions are met, CI should produce the ext4 `rootfs.img` and kernel/U-Boot build artifacts separately, but should not claim the rootfs is bootable or give a command to flash it to the physical `super` partition. `userdata` remains untouched.
