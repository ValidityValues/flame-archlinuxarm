# Arch Linux ARM for Google Pixel 4 (google-flame)

This repository provides a local AArch64 Arch Linux ARM rootfs builder and a device-specific U-Boot build. Kernel builds live in the separate repository [ValidityValues/linux-sm8150-mainline](https://github.com/ValidityValues/linux-sm8150-mainline).

## Current device facts supplied for this project

- Product: `flame`, Snapdragon 855 / SM8150, 64 GB UFS.
- Active slot: `b`; slot B is marked successful. Slot A is marked unbootable.
- Physical `super`: `0x245800000` bytes.
- `userdata` is to remain untouched.
- Fastboot bootloader reports sizes for `system_b`, `vendor_b`, `product_b`, `system_ext_b`; some A-side queries return `variable not found`. This is not enough information to safely resize `super`.

## Local rootfs build (no GitHub Actions)

The Arch Linux ARM root filesystem is built **locally on the host PC**, not by a hosted workflow. From Fedora 44 x86_64, install the tools:

```bash
sudo dnf install qemu-user-static-aarch64 libarchive e2fsprogs rsync curl gnupg2 zstd
sudo systemctl restart systemd-binfmt
```

Clone the repository and build the one main ext4 image:

```bash
git clone https://github.com/ValidityValues/flame-archlinuxarm.git
cd flame-archlinuxarm
bash scripts/build-rootfs.sh --desktop plasma-desktop --size-mib 6144
```

The script prompts for sudo when required, verifies the upstream Arch Linux ARM tarball/signature, runs ARM64 package installation under QEMU user emulation, configures NetworkManager/wpa_supplicant and BlueZ, installs Qualcomm/Atheros firmware packages, and creates:

- `out/rootfs.img`: the single ext4 filesystem image.
- `out/rootfs.img.sha256`: SHA-256 checksum.
- `out/BUILD-MANIFEST.txt`: build details.

Desktop choices: `none`, `plasma-desktop`, `xfce4`, `lxqt`, `gnome`. Example for a smaller base system:

```bash
bash scripts/build-rootfs.sh --desktop none --size-mib 4096
```

The default user is `flame`. On an interactive terminal the script offers an optional password prompt; pressing Enter leaves its password locked. You can pass a **public** SSH key to enable key-based SSH access:

```bash
bash scripts/build-rootfs.sh --desktop plasma-desktop --size-mib 6144 --ssh-key ~/.ssh/id_ed25519.pub
```

Once matching kernel artifacts exist, they can optionally be embedded under `/boot` inside the filesystem image:

```bash
bash scripts/build-rootfs.sh --desktop plasma-desktop --size-mib 6144 --kernel-artifacts /path/to/downloaded-kernel-artifacts
```

This only places files in the filesystem; it does not guarantee that U-Boot can access them if `rootfs.img` is inside an Android dynamic logical partition.

## U-Boot build

The **Build SM8150 U-Boot** workflow builds the device-specific `andrew/google-flame` branch and packages the result as `u-boot.img`. It does not flash the phone. The exact `preboot` uses a blkmap view of `userdata` to scan a nested partition for Nura's EFI loader. That boot-file layout uses storage within `userdata`; it is therefore separate from, and not compatible with the requirement to leave `userdata` entirely untouched unless you choose another boot-file source.

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

The generic Arch Linux ARM AArch64 tarball provides a glibc-based ARM64 userspace. It is not a device-specific kernel. The matching kernel, DTB and modules must be built together from the device-support source. `rootfs.img` is an ext4 filesystem image only, not an Android boot image and not a flashable `super.img`.

If no SSH public key is supplied, SSH is not enabled. The builder only accepts a public key file; never pass a private key into the script.

## References

- Arch Linux ARM generic AArch64: https://archlinuxarm.org/platforms/armv8/generic
- SM8150 Mainline kernel: https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux
- U-Boot Qualcomm phone notes: https://docs.u-boot-project.org/en/latest/board/qualcomm/phones.html
