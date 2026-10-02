#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DESKTOP="plasma-desktop"
SIZE_MIB="6144"
OUT_DIR="$REPO_ROOT/out"
TARGET_USER="flame"
SSH_KEY=""
KERNEL_ARTIFACTS=""

usage() {
  cat <<'EOF'
Usage: scripts/build-rootfs.sh [--desktop none|plasma-desktop|xfce4|lxqt|gnome]
       [--size-mib MiB] [--out DIR] [--user NAME] [--ssh-key PUBLIC_KEY_FILE]
       [--kernel-artifacts DIR]

Builds a single ext4 rootfs.img locally. It does not flash the phone.
EOF
}
while (($#)); do
  case "$1" in
    --desktop) DESKTOP="$2"; shift 2 ;;
    --size-mib) SIZE_MIB="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --user) TARGET_USER="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --kernel-artifacts) KERNEL_ARTIFACTS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$DESKTOP" in none|plasma-desktop|xfce4|lxqt|gnome) ;; *) echo "Unknown desktop: $DESKTOP" >&2; exit 2 ;; esac
[[ "$SIZE_MIB" =~ ^[0-9]+$ ]] && (( SIZE_MIB >= 2048 )) || { echo "--size-mib must be >= 2048" >&2; exit 2; }
[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { echo "Invalid username: $TARGET_USER" >&2; exit 2; }
[[ -z "$SSH_KEY" || -f "$SSH_KEY" ]] || { echo "Public key file not found: $SSH_KEY" >&2; exit 2; }
[[ -z "$KERNEL_ARTIFACTS" || -d "$KERNEL_ARTIFACTS" ]] || { echo "Kernel artifacts directory not found" >&2; exit 2; }

if (( EUID != 0 )); then
  exec sudo env FLAME_BUILD_UID="$(id -u)" FLAME_BUILD_GID="$(id -g)" bash "$0" "$@"
fi
BUILD_UID="$(printenv FLAME_BUILD_UID || echo 0)"
BUILD_GID="$(printenv FLAME_BUILD_GID || echo 0)"

for cmd in curl gpg bsdtar qemu-aarch64-static rsync mkfs.ext4 e2fsck mount umount mountpoint chroot zstd sha256sum file md5sum systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing dependency: $cmd" >&2
    echo "Fedora 44: sudo dnf install qemu-user-static-aarch64 libarchive e2fsprogs rsync curl gnupg2 zstd" >&2
    exit 1
  }
done
if [[ "$(uname -m)" != aarch64 ]]; then
  systemctl restart systemd-binfmt.service 2>/dev/null || true
  BINFMT_HANDLER=/proc/sys/fs/binfmt_misc/qemu-aarch64
  if [[ ! -r "$BINFMT_HANDLER" ]] ||
     ! grep -Fq 'interpreter /usr/bin/qemu-aarch64-static' "$BINFMT_HANDLER" ||
     ! grep -Fxq 'enabled' "$BINFMT_HANDLER"; then
    echo "AArch64 binfmt handler is not registered or is disabled." >&2
    echo "Expected an enabled $BINFMT_HANDLER using /usr/bin/qemu-aarch64-static." >&2
    echo "Install qemu-user-static-aarch64 and restart systemd-binfmt, then check the handler file." >&2
    [[ ! -r "$BINFMT_HANDLER" ]] || cat "$BINFMT_HANDLER" >&2
    exit 1
  fi
fi

if [[ "$OUT_DIR" != /* ]]; then OUT_DIR="$PWD/$OUT_DIR"; fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd -- "$OUT_DIR" && pwd)"
WORK="$OUT_DIR/.build-rootfs"
ROOTFS="$WORK/rootfs"
MNT="$WORK/mnt"
CACHE_DIR="$OUT_DIR/cache"
DOWNLOAD="$CACHE_DIR/archlinuxarm"
OLD_DOWNLOAD="$WORK/download"
PKG_CACHE="$OUT_DIR/pacman-cache"
TMP_IMAGE="$OUT_DIR/.rootfs.img.tmp"
FINAL_IMAGE="$OUT_DIR/rootfs.img"
GPG_HOME="$CACHE_DIR/gnupg"
KEY_FILE="$CACHE_DIR/archlinuxarm-signing-key.asc"
URL="https://ca.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
FILE="ArchLinuxARM-aarch64-latest.tar.gz"
BASE_URL="$(dirname "$URL")"
KEY_FPR="68B3537F39A313B3E574D06777193F152BDBE6A6"
KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$KEY_FPR"

# Unmount only this builder's known mountpoints before touching its chroot.
# If something is still using them, fail instead of deleting a mounted tree.
unmount_builder_mounts() {
  local failed=0 target
  if mountpoint -q "$ROOTFS/sys"; then
    echo "Unmounting previous chroot /sys tree..."
    umount -R "$ROOTFS/sys" || failed=1
  fi
  for target in \
    "$ROOTFS/var/cache/pacman/pkg" \
    "$ROOTFS/proc" \
    "$ROOTFS/dev/pts" \
    "$ROOTFS/dev" \
    "$MNT"; do
    if mountpoint -q "$target"; then
      echo "Unmounting $target..."
      umount "$target" || failed=1
    fi
  done
  if (( failed )); then
    echo "ERROR: some previous chroot/image mounts are still busy; refusing to start." >&2
    echo "Inspect mounts with: findmnt -R '$ROOTFS'" >&2
    echo "Check open processes with: sudo fuser -vm '$ROOTFS'" >&2
    findmnt -R "$ROOTFS" >&2 || true
    return 1
  fi
}

cleanup() {
  set +e
  unmount_builder_mounts
}
trap cleanup EXIT INT TERM

mkdir -p "$OUT_DIR" "$WORK" "$ROOTFS" "$MNT" "$DOWNLOAD" "$GPG_HOME" "$PKG_CACHE"
chmod 700 "$GPG_HOME"

echo "[preflight] Unmount stale chroot mounts and reset the working rootfs"
unmount_builder_mounts

# Migrate the archive downloaded by the previous version of this script so
# the first run with the new persistent cache does not download ~800 MiB again.
if [[ -d "$OLD_DOWNLOAD" ]]; then
  for cached_file in "$FILE" "$FILE.md5" "$FILE.sig"; do
    if [[ ! -s "$DOWNLOAD/$cached_file" && -s "$OLD_DOWNLOAD/$cached_file" ]]; then
      cp -a "$OLD_DOWNLOAD/$cached_file" "$DOWNLOAD/$cached_file"
      echo "Migrated existing download into persistent cache: $cached_file"
    fi
  done
fi

rm -rf "$ROOTFS" "$MNT" "$TMP_IMAGE"
mkdir -p "$ROOTFS" "$MNT" "$WORK"

download_cached() {
  local url="$1" destination="$2"
  if [[ -s "$destination" ]]; then
    echo "Cache hit: $(basename "$destination")"
    return 0
  fi
  echo "Downloading: $(basename "$destination")"
  curl -fL --retry 5 "$url" -o "$destination.part"
  mv -f "$destination.part" "$destination"
}

echo "[1/6] Download and verify Arch Linux ARM rootfs"
download_cached "$URL" "$DOWNLOAD/$FILE"
download_cached "$BASE_URL/$FILE.md5" "$DOWNLOAD/$FILE.md5"
download_cached "$BASE_URL/$FILE.sig" "$DOWNLOAD/$FILE.sig"
if ! (cd "$DOWNLOAD" && md5sum -c "$FILE.md5"); then
  echo "Cached Arch Linux ARM archive failed its MD5 check; downloading it again." >&2
  rm -f "$DOWNLOAD/$FILE" "$DOWNLOAD/$FILE.part"
  download_cached "$URL" "$DOWNLOAD/$FILE"
  (cd "$DOWNLOAD" && md5sum -c "$FILE.md5")
fi
if ! gpg --homedir "$GPG_HOME" --batch --list-keys "$KEY_FPR" >/dev/null 2>&1; then
  download_cached "$KEY_URL" "$KEY_FILE"
  gpg --homedir "$GPG_HOME" --batch --import "$KEY_FILE"
fi
FPR="$(gpg --homedir "$GPG_HOME" --batch --with-colons --fingerprint "$KEY_FPR" | awk -F: '$1=="fpr" {print $10; exit}')"
[[ "$FPR" == "$KEY_FPR" ]] || { echo "Unexpected signing key fingerprint: $FPR" >&2; exit 1; }
gpg --homedir "$GPG_HOME" --batch --verify "$DOWNLOAD/$FILE.sig" "$DOWNLOAD/$FILE"

echo "[2/6] Extract ARM64 base system"
bsdtar --numeric-owner --xattrs --acls -xpf "$DOWNLOAD/$FILE" -C "$ROOTFS"
file "$ROOTFS/usr/bin/bash"
install -m 0755 "$(command -v qemu-aarch64-static)" "$ROOTFS/usr/bin/qemu-aarch64-static"
mkdir -p "$ROOTFS/etc/flame" "$ROOTFS/boot"
rm -f "$ROOTFS/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
printf 'flame-arch\n' > "$ROOTFS/etc/hostname"
printf 'LANG=en_US.UTF-8\n' > "$ROOTFS/etc/locale.conf"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$ROOTFS/etc/locale.gen" 2>/dev/null || true

DE_PACKAGES=""
DISPLAY_MANAGER=""
case "$DESKTOP" in
  plasma-desktop) DE_PACKAGES="plasma-desktop plasma-nm bluedevil dolphin konsole kate sddm xorg-server xorg-xwayland mesa vulkan-freedreno pipewire pipewire-alsa pipewire-pulse wireplumber xdg-desktop-portal xdg-desktop-portal-kde qt6-wayland"; DISPLAY_MANAGER=sddm ;;
  xfce4) DE_PACKAGES="xfce4-session xfce4-panel xfce4-settings xfdesktop xfwm4 xfce4-terminal thunar mousepad ristretto lightdm lightdm-gtk-greeter xorg-server xorg-xwayland mesa vulkan-freedreno"; DISPLAY_MANAGER=lightdm ;;
  lxqt) DE_PACKAGES="lxqt-session lxqt-panel lxqt-config lxqt-runner pcmanfm-qt qterminal sddm xorg-server xorg-xwayland mesa vulkan-freedreno qt6-wayland"; DISPLAY_MANAGER=sddm ;;
  gnome) DE_PACKAGES="gnome-shell gnome-session gdm gnome-terminal nautilus gnome-control-center gnome-settings-daemon gnome-keyring gnome-backgrounds gnome-tweaks xorg-xwayland mesa vulkan-freedreno"; DISPLAY_MANAGER=gdm ;;
esac
printf '%s\n' base sudo openssh git vim nano tmux usbutils e2fsprogs dosfstools device-mapper mkinitcpio networkmanager wpa_supplicant iwd wireless-regdb rfkill iw bluez bluez-utils linux-firmware-qcom linux-firmware-atheros linux-firmware-whence $DE_PACKAGES   | sed '/^$/d' | sort -u > "$WORK/packages.txt"

echo "[3/6] Set up ARM64 chroot and install packages"
mkdir -p "$ROOTFS/var/cache/pacman/pkg" "$PKG_CACHE"
mount --bind "$PKG_CACHE" "$ROOTFS/var/cache/pacman/pkg"
mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount --rbind /sys "$ROOTFS/sys"
mount --make-rslave "$ROOTFS/sys"
chroot "$ROOTFS" /usr/bin/pacman-key --init
chroot "$ROOTFS" /usr/bin/pacman-key --populate archlinuxarm
# The host kernel/container may not expose Landlock to this chroot. Disable
# only pacman's downloader sandbox for this build invocation; signature checks remain enabled.
xargs chroot "$ROOTFS" /usr/bin/pacman -Syu --disable-sandbox --noconfirm --needed < "$WORK/packages.txt"
chroot "$ROOTFS" /usr/bin/pacman -Q > "$WORK/packages-installed.txt"

if ! chroot "$ROOTFS" /usr/bin/id "$TARGET_USER" >/dev/null 2>&1; then
  chroot "$ROOTFS" /usr/bin/useradd -m -G wheel,audio,video,storage,input -s /bin/bash "$TARGET_USER"
fi
mkdir -p "$ROOTFS/etc/sudoers.d"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$ROOTFS/etc/sudoers.d/10-wheel"
chmod 0440 "$ROOTFS/etc/sudoers.d/10-wheel"
if [[ -t 0 ]]; then
  printf 'Optional password for user %s (Enter leaves it locked): ' "$TARGET_USER"
  read -r -s USER_PASSWORD
  printf '\n'
  if [[ -n "$USER_PASSWORD" ]]; then printf '%s:%s\n' "$TARGET_USER" "$USER_PASSWORD" | chroot "$ROOTFS" /usr/bin/chpasswd; unset USER_PASSWORD; fi
fi

mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
if [[ -n "$SSH_KEY" ]]; then
  install -d -m 0700 "$ROOTFS/home/$TARGET_USER/.ssh"
  install -m 0600 "$SSH_KEY" "$ROOTFS/home/$TARGET_USER/.ssh/authorized_keys"
  chroot "$ROOTFS" /usr/bin/chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.ssh"
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' > "$ROOTFS/etc/ssh/sshd_config.d/90-flame.conf"
  systemctl --root="$ROOTFS" enable sshd.service
else
  printf 'PasswordAuthentication no\nPermitRootLogin no\n' > "$ROOTFS/etc/ssh/sshd_config.d/90-flame.conf"
fi

mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
printf '[device]\nwifi.backend=wpa_supplicant\n' > "$ROOTFS/etc/NetworkManager/conf.d/10-wifi.conf"
systemctl --root="$ROOTFS" enable NetworkManager.service
systemctl --root="$ROOTFS" enable bluetooth.service
if [[ -n "$DISPLAY_MANAGER" ]]; then
  systemctl --root="$ROOTFS" enable "$DISPLAY_MANAGER.service"
  systemctl --root="$ROOTFS" set-default graphical.target
else
  systemctl --root="$ROOTFS" set-default multi-user.target
fi

# Optional: embed matching kernel files in /boot. This does not make a dynamic
# partition inside Android super automatically visible to U-Boot.
if [[ -n "$KERNEL_ARTIFACTS" ]]; then
  [[ -s "$KERNEL_ARTIFACTS/Image" && -s "$KERNEL_ARTIFACTS/sm8150-google-flame.dtb" ]] || { echo "Kernel artifacts need Image and sm8150-google-flame.dtb" >&2; exit 1; }
  install -m 0644 "$KERNEL_ARTIFACTS/Image" "$ROOTFS/boot/Image"
  install -m 0644 "$KERNEL_ARTIFACTS/sm8150-google-flame.dtb" "$ROOTFS/boot/sm8150-google-flame.dtb"
  if [[ -s "$KERNEL_ARTIFACTS/linux.efi" ]]; then install -D -m 0644 "$KERNEL_ARTIFACTS/linux.efi" "$ROOTFS/boot/EFI/BOOT/BOOTAA64.EFI"; fi
  if [[ -s "$KERNEL_ARTIFACTS/config" ]]; then install -m 0644 "$KERNEL_ARTIFACTS/config" "$ROOTFS/boot/config"; fi
  if [[ -s "$KERNEL_ARTIFACTS/System.map" ]]; then install -m 0644 "$KERNEL_ARTIFACTS/System.map" "$ROOTFS/boot/System.map"; fi
  if [[ -s "$KERNEL_ARTIFACTS/modules.tar.zst" ]]; then tar --zstd -xf "$KERNEL_ARTIFACTS/modules.tar.zst" -C "$ROOTFS"; fi
  if [[ -s "$KERNEL_ARTIFACTS/MANIFEST.txt" ]]; then cp "$KERNEL_ARTIFACTS/MANIFEST.txt" "$ROOTFS/boot/kernel-build-manifest.txt"; fi
fi

cat > "$ROOTFS/etc/flame/BUILD_INFO" <<EOF
Device: Google Pixel 4 (google-flame), Qualcomm SM8150
Userspace: Arch Linux ARM AArch64 (glibc)
Desktop: $DESKTOP
Default user: $TARGET_USER (password may be locked)
Network: NetworkManager + wpa_supplicant
Bluetooth: BlueZ
Firmware: linux-firmware-qcom, linux-firmware-atheros, linux-firmware-whence
Bootloader: separate U-Boot Android boot image; see docs/boot-layout.md
Hardware boot and Wi-Fi/BT: not yet validated
EOF

# Leave the chroot mounts before copying the tree into the ext4 image. In
# particular, never rsync the host's /dev, /proc or /sys into the guest rootfs.
unmount_builder_mounts
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static" "$ROOTFS/etc/resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"
rm -f "$ROOTFS"/var/cache/pacman/pkg/* 2>/dev/null || true
find "$ROOTFS/var/log/journal" -mindepth 1 -delete 2>/dev/null || true

echo "[4/6] Check image size"
USED_MIB="$(du -sm "$ROOTFS" | cut -f1)"
if (( USED_MIB + SIZE_MIB / 10 > SIZE_MIB )); then
  echo "Rootfs uses $USED_MIB MiB; $SIZE_MIB MiB image leaves less than 10% free. Increase --size-mib." >&2
  exit 1
fi

echo "[5/6] Create ext4 rootfs.img"
rm -f "$TMP_IMAGE"
truncate -s "$SIZE_MIB"M "$TMP_IMAGE"
mkfs.ext4 -F -q -L FLAME_ROOT -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "$TMP_IMAGE"
mount -o loop "$TMP_IMAGE" "$MNT"
rsync -aHAX --numeric-ids "$ROOTFS/" "$MNT/"
sync
df -h "$MNT" | tee "$WORK/ext4-space.txt"
umount "$MNT"
e2fsck -fn "$TMP_IMAGE"
mv -f "$TMP_IMAGE" "$FINAL_IMAGE"

echo "[6/6] Manifest and checksum"
{
  echo "device=google-flame"
  echo "distribution=Arch Linux ARM AArch64"
  echo "desktop=$DESKTOP"
  echo "size_mib=$SIZE_MIB"
  echo "filesystem=ext4"
  echo "output=rootfs.img"
  echo "network=NetworkManager+wpa_supplicant"
  echo "bluetooth=BlueZ"
  echo "rootfs_build=local"
  echo "source_cache=$DOWNLOAD"
  echo "pacman_package_cache=$PKG_CACHE"
  echo "pacman_download_sandbox=disabled for build only due to host Landlock limitation"
  echo "kernel_artifacts_embedded=$(if [[ -n "$KERNEL_ARTIFACTS" ]]; then echo yes; else echo no; fi)"
  echo "boot_note=U-Boot image is separate; see docs/boot-layout.md"
  echo "device_boot_validation=not yet performed"
  echo "warning=Never flash this ext4 image to physical super."
} > "$OUT_DIR/BUILD-MANIFEST.txt"
sha256sum "$FINAL_IMAGE" > "$OUT_DIR/rootfs.img.sha256"
if (( BUILD_UID != 0 )); then chown "$BUILD_UID:$BUILD_GID" "$FINAL_IMAGE" "$OUT_DIR/rootfs.img.sha256" "$OUT_DIR/BUILD-MANIFEST.txt"; fi
rm -rf "$WORK"
echo "Persistent download cache: $DOWNLOAD"
echo "Persistent pacman package cache: $PKG_CACHE"
echo "Done: $FINAL_IMAGE"
echo "Checksum: $OUT_DIR/rootfs.img.sha256"
echo "This is an ext4 filesystem, not an Android boot.img or super.img."
