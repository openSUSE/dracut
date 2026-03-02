#!/bin/sh

trap 'poweroff -f' EXIT

set -e

mkfs.btrfs -draid0 -mraid0 -L root /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_raid[12]
udevadm settle

btrfs device scan
udevadm settle

mkdir -p /sysroot
mount -t btrfs /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_raid1 /sysroot
cp -a -t /sysroot /source/*
umount /sysroot

echo "dracut-root-block-created" | dd oflag=direct,dsync of=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_marker
sync
poweroff -f
