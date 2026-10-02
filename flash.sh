#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
IMAGE="${1:-$SCRIPT_DIR/out/rootfs.img}"
TARGET_LP="flame_root"

usage() {
  cat <<'EOF'
Usage: bash flash.sh [path/to/rootfs.img]

Interactive flash helper for Google Pixel 4 (google-flame).

Target:
  logical in super
                 Writes only to the dedicated logical partition "flame_root".
                 It never writes to userdata or the physical super container.

Optional:
  FASTBOOT_SERIAL=<serial> bash flash.sh [path/to/rootfs.img]
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -s "$IMAGE" ]]; then
  echo "Rootfs image not found or empty: $IMAGE" >&2
  echo "Build it first with: bash scripts/build-rootfs.sh" >&2
  exit 1
fi

for cmd in fastboot sha256sum stat awk sed grep; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required command: $cmd" >&2
    exit 1
  }
done

if [[ ! -s "$IMAGE.sha256" ]]; then
  echo "Required SHA-256 file not found: $IMAGE.sha256" >&2
  echo "Refusing to flash an image without its builder-generated checksum." >&2
  exit 1
fi
expected="$(awk 'NR == 1 { print $1; exit }' "$IMAGE.sha256")"
actual="$(sha256sum "$IMAGE" | awk '{ print $1 }')"
if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ || "$expected" != "$actual" ]]; then
  echo "SHA-256 mismatch or malformed checksum for $IMAGE; refusing to flash." >&2
  exit 1
fi
echo "SHA-256 verified."

FB=(fastboot)
if [[ -n "${FASTBOOT_SERIAL:-}" ]]; then
  FB+=(-s "$FASTBOOT_SERIAL")
fi

devices="$("${FB[@]}" devices 2>/dev/null | awk 'NF >= 2 { print $1 }' || true)"
device_count="$(printf '%s\n' "$devices" | awk 'NF { n++ } END { print n+0 }')"
if (( device_count == 0 )); then
  echo "No Fastboot device found. Boot the Pixel 4 into Fastboot mode and check USB/udev." >&2
  exit 1
fi
if (( device_count > 1 )) && [[ -z "${FASTBOOT_SERIAL:-}" ]]; then
  echo "More than one Fastboot device is connected. Set FASTBOOT_SERIAL to select one." >&2
  printf '%s\n' "$devices" >&2
  exit 1
fi

getvar() {
  "${FB[@]}" getvar "$1" 2>&1
}

getvar_value() {
  local var="$1"
  getvar "$var" | sed -nE "s/.*${var//\//\\/}:[[:space:]]*([^[:space:]]+).*/\1/p" | tail -n 1
}

product_output="$(getvar product || true)"
product_value="$(printf '%s\n' "$product_output" | sed -nE 's/.*product:[[:space:]]*([^[:space:]]+).*/\1/p' | tail -n 1)"
printf 'Detected Fastboot product: %s\n' "${product_value:-unknown}"
if [[ "$product_value" != "flame" && "$product_value" != "google-flame" ]]; then
  echo "Could not positively identify a Google Pixel 4 (flame); refusing to continue." >&2
  printf '%s\n' "$product_output" >&2
  exit 1
fi

image_bytes="$(stat -c '%s' "$IMAGE")"

partition_size_bytes() {
  local partition="$1" output hex
  output="$(getvar "partition-size:$partition" || true)"
  hex="$(printf '%s\n' "$output" | grep -Eo '0x[0-9a-fA-F]+' | tail -n 1 || true)"
  if [[ -z "$hex" ]]; then
    echo "Could not query partition-size:$partition. Refusing to flash without a known size." >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
  printf '%d\n' "$((hex))"
}

check_image_fits() {
  local partition="$1" capacity
  capacity="$(partition_size_bytes "$partition")" || return 1
  if (( image_bytes > capacity )); then
    echo "Image is $image_bytes bytes, but $partition is only $capacity bytes." >&2
    return 1
  fi
  printf 'Image size: %s bytes; %s size: %s bytes.\n' "$image_bytes" "$partition" "$capacity"
}

echo
echo "Image: $IMAGE"
echo "Target: logical partition '$TARGET_LP' inside Android super"
echo "This helper never writes to userdata or the physical super container."
echo "The logical partition must already exist in valid LP metadata."
echo "Choose the destination:"
echo "  1) flame_root (Fastbootd only)"
echo "  q) quit"
read -r -p '> ' choice

case "$choice" in
  1|flame_root|super)
    echo
    userspace_output="$(getvar is-userspace || true)"
    userspace_value="$(printf '%s\n' "$userspace_output" | sed -nE 's/.*is-userspace:[[:space:]]*([^[:space:]]+).*/\1/p' | tail -n 1)"
    if [[ "$userspace_value" != "yes" ]]; then
      echo "Fastbootd is required for dynamic logical partitions." >&2
      echo "Current is-userspace value: ${userspace_value:-unknown}" >&2
      echo "From bootloader Fastboot, run: fastboot reboot fastboot" >&2
      echo "Then rerun this script in Fastbootd." >&2
      exit 1
    fi
    logical_output="$(getvar "is-logical:$TARGET_LP" || true)"
    logical_value="$(printf '%s\n' "$logical_output" | sed -nE 's/.*is-logical:[^:]*:[[:space:]]*([^[:space:]]+).*/\1/p' | tail -n 1)"
    if [[ "$logical_value" != "yes" ]]; then
      echo "Fastbootd did not confirm '$TARGET_LP' is a logical partition; refusing to flash." >&2
      printf '%s\n' "$logical_output" >&2
      echo "Create and verify the dedicated logical partition first; this script does not resize super." >&2
      exit 1
    fi
    check_image_fits "$TARGET_LP"
    echo
    read -r -p "Type FLASH $TARGET_LP to continue: " confirmation
    [[ "$confirmation" == "FLASH $TARGET_LP" ]] || { echo "Cancelled."; exit 0; }
    "${FB[@]}" flash "$TARGET_LP" "$IMAGE"
    ;;
  q|Q|quit|exit)
    echo "Cancelled."
    exit 0
    ;;
  *)
    echo "Unknown choice: $choice" >&2
    exit 2
    ;;
esac
echo
echo "Flash command completed. This does not prove that the device can boot the image."
