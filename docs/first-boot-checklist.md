# Pixel 4 Arch Linux ARM bring-up checklist

## Current known state

- Device: Google Pixel 4 / google-flame / SM8150.
- Current slot: B; B is marked successful.
- Slot A is marked unbootable. Do not assume its logical partitions are present or safe to overwrite.
- Physical `super`: `0x245800000` bytes.
- Preserve `userdata`; target a separate logical partition inside `super` only after inspecting LP metadata.

## Before changing super

- [ ] Verify Android B still boots and bootloader is unlocked.
- [ ] Save `fastboot getvar all`, `lpdump`, and logical-partition sizes from Android/fastbootd.
- [ ] Determine free extents and group limits; check snapshot/COW state.
- [ ] Back up the complete original super image/contents and LP metadata to a host; verify hashes and that the backup is readable.
- [ ] Back up boot-related partitions and record exact original slot state.
- [ ] Confirm a tested restore route before writing anything.
- [ ] Make sure the rootfs image fits the exact dedicated logical partition.
- [ ] Ensure kernel, DTB and modules were produced from the same device-support source revision.

## Do not

- Never flash a standalone ext4 rootfs image directly to the physical `super` block device.
- Never format or repartition `userdata` for this project.
- Never resize active slot-B logical partitions without a complete backup and restore plan.
- Do not treat missing fastboot partition-size variables as proof that a partition is absent.
- Do not flash a kernel or U-Boot solely because a workflow compiled it.

## Bring-up sequence

1. Build and inspect the device-support kernel artifacts.
2. Build Arch Linux ARM rootfs and verify checksums.
3. Identify the exact U-Boot boot script and test temporary boot if supported.
4. Verify root device, kernel command line, DTB and module release match.
5. Only after a boot test, plan a dedicated logical partition in super using a reviewed LP metadata procedure.
6. Preserve Android B and validate recovery before any permanent boot-chain changes.

The collector `scripts/collect-layout.sh` only runs read-only ADB/Fastboot queries. Redact serial numbers before sharing output.
