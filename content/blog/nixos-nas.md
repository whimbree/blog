+++
title = "NixOS NAS with ZFS Encryption, SSH Decrypt, and temporary root filesystem"
date = 2022-12-19

[taxonomies]
tags = ["nixos", "zfs", "luks", "erase your darlings"]
+++

I wanted a server for backing up my computers, as well as acting as a NAS and media server.
Since this will store backups and documents, the disks needed to be encrypted with a robust filesystem to allow for redundancy.
I chose ZFS as the filysystem with ZFS native encryption, and opted to use LUKS to encrypt the swap partition as well.

This install gives me:
- ZFS encrypted With ZFS native encryption
- Swap encryped with LUKS
- Remotely decryption with SSH
- Once decrypted, only allow SSH through Tailscale VPN

<!-- more -->

## Parts List
- [6 Seagate 16TB HDD Exos X16 ST16000NM001G](https://www.amazon.com/dp/B08JYQKVJP)
- [Samsung 970 EVO Plus SSD 1TB](https://www.amazon.com/gp/product/B07MFZY2F2)
- [AMD Ryzen 9 3900X 12-core](https://www.amazon.com/AMD-Ryzen-3900X-24-Thread-Processor/dp/B07SXMZLP9)
- [AsRock Rack X470D4U](https://www.amazon.com/dp/B07PNFTPGB)
- [Kingston Server Premier 32GB 3200MHz DDR4 ECC](https://www.amazon.com/dp/B08GKVFMGN)
- [SilverStone FX600 600W FlexATX PSU](https://www.amazon.com/dp/B09SKRQ6KC)
- [Noctua NH-L9a-AM4](https://www.amazon.com/dp/B083LQVX5W)
- [U-NAS NSC-810A Server Chassis](https://www.u-nas.com/xcart/cart.php?target=product&product_id=17640)

## Initial Installation

```bash
# The boot disk that will be used
export DISK='/dev/nvme0n1'

export KEYFILE_LOCATION=/cryptkey
export KEY_DISK=/dev/mapper/cryptkey

```
Next, we partition the boot SSD

```bash
# Set partition sizes
export EFI_SIZE=512M
export BOOT_SIZE=1G

export OTHER_SIZE=65GB
export KEY_SIZE=20M
# SWAP_SIZE = OTHER_SIZE - KEY_SIZE

# Partition the disk
sgdisk --zap-all $DISK
# EFI System parition
sgdisk -n 1:0:+$EFI_SIZE -t 1:EF00 $DISK
# Boot partition
sgdisk -n 2:0:+$BOOT_SIZE -t 2:BE00 $DISK
# ZFS partition
sgdisk -n 3:0:-$OTHER_SIZE -t 3:8300 $DISK
# LUKS encrypted SWAP partition
sgdisk -n 4:0:-$KEY_SIZE -t 4:8300 $DISK
# LUKS encrypted decryption key
sgdisk -n 5:0:0 -t 5:8300 $DISK
```

Next, we create an encrypted disk to hold our key, the key to this drive is what you'll type in to unlock the rest of your drives... so, remember it.

```bash
export DISK1_KEY=$(echo $DISK | cut -f1 -d\ )p5
cryptsetup luksFormat $DISK1_KEY
cryptsetup luksOpen $DISK1_KEY cryptkey
```

Now we generate a randomized key and store it in our LUKS partition.

```bash
echo "" > newline
dd if=/dev/zero bs=1 count=1 seek=1 of=newline
dd if=/dev/urandom bs=32 count=1 | od -A none -t x | tr -d '[:space:]' | cat - newline > hdd.key
dd if=/dev/zero of=$KEY_DISK
dd if=hdd.key of=$KEY_DISK
```

Using that key, we create an encrypted swap partition.

```bash
export DISK1_SWAP=$(echo $DISK | cut -f1 -d\ )p4
cryptsetup luksFormat --key-file=$KEY_DISK --keyfile-size=64 $DISK1_SWAP
cryptsetup open --key-file=$KEY_DISK --keyfile-size=64 $DISK1_SWAP cryptswap
mkswap /dev/mapper/cryptswap
swapon /dev/mapper/cryptswap
```

Using GRUB with encrypted ZFS presents challenges, so here I separate the boot and root zfs pools. First we create the boot pool.

```bash
zpool create -f \
	-o compatibility=grub2 \
	-o ashift=12 \
	-o autotrim=on \
	-O acltype=posixacl \
	-O compression=lz4 \
	-O devices=off \
	-O normalization=formD \
	-O atime=off \
	-O xattr=sa \
	-O canmount=off \
	-O mountpoint=/boot \
	-R /mnt \
	bpool \
	${DISK}p2
```

Next, we create the root pool

```bash
# Create root pool
zpool create -f \
	-o ashift=12 \
	-o autotrim=on \
	-R /mnt \
	-O acltype=posixacl \
	-O compression=lz4 \
	-O dnodesize=auto \
	-O normalization=formD \
	-O xattr=sa \
	-O atime=off \
	-O canmount=off \
	-O mountpoint=none \
	-O encryption=aes-256-gcm \
	-O keylocation=file://$KEY_DISK \
	-O keyformat=hex \
	rpool \
	${DISK}p3
```

I am using a similar ZFS setup to the one in Graham Christensen's blog post (linked in references). The root filesystem is reset on every boot, and there are separate datasets for persistent data that should be backed up, as opposed to data that can be regenerated easily (like the nix store).

```bash
# Create root system containers
zfs create \
	-o canmount=off \
	-o mountpoint=none \
	rpool/local
zfs create \
	-o canmount=off \
	-o mountpoint=none \
	rpool/safe

# Create and mount dataset for `/`
zfs create -p -o mountpoint=legacy rpool/local/root
# Create a blank snapshot
zfs snapshot rpool/local/root@blank
# Mount root ZFS dataset
mount -t zfs rpool/local/root /mnt

# Create and mount dataset for `/nix`
zfs create -p -o mountpoint=legacy rpool/local/nix
mkdir -p /mnt/nix
mount -t zfs rpool/local/nix /mnt/nix

# Create and mount dataset for `/home`
zfs create -p -o mountpoint=legacy rpool/safe/home
mkdir -p /mnt/home
mount -t zfs rpool/safe/home /mnt/home

# Create and mount dataset for `/persist`
zfs create -p -o mountpoint=legacy rpool/safe/persist
mkdir -p /mnt/persist
mount -t zfs rpool/safe/persist /mnt/persist

# Create and mount dataset for `/boot`
zfs create -o mountpoint=legacy bpool/root
mkdir -p /mnt/boot
mount -t zfs bpool/root /mnt/boot
```

The remainer of the setup:

```bash
# Mount EFI partition
mkdir -p /mnt/boot/efi
mkfs.vfat -F32 $(echo $DISK | cut -f1 -d\ )p1
mount -t vfat $(echo $DISK | cut -f1 -d\ )p1 /mnt/boot/efi

# Disable cache, stale cache will prevent system from booting
mkdir -p /mnt/etc/zfs/
rm -f /mnt/etc/zfs/zpool.cache
touch /mnt/etc/zfs/zpool.cache
chmod a-w /mnt/etc/zfs/zpool.cache
chattr +i /mnt/etc/zfs/zpool.cache

# Generate initial system configuration
nixos-generate-config --root /mnt

CRYPTKEY="$(blkid -o export "$DISK1_KEY" | grep "^UUID=")"
CRYPTKEY="${CRYPTKEY#UUID=*}"

CRYPTSWAP="$(blkid -o export "$DISK1_SWAP" | grep "^UUID=")"
CRYPTSWAP="${CRYPTSWAP#UUID=*}"

# Import ZFS-specific configuration
sed -i "s|./hardware-configuration.nix|./hardware-configuration.nix ./zfs.nix|g" /mnt/etc/nixos/configuration.nix

# Configure bootloader for UEFI boot
sed -i '/boot.loader/d' /mnt/etc/nixos/configuration.nix
sed -i '/services.xserver/d' /mnt/etc/nixos/configuration.nix
# Set root password
rootPwd=$(mkpasswd -m SHA-512 -s "root")
# Write zfs.nix configuration
tee -a /mnt/etc/nixos/zfs.nix <<EOF
{ config, pkgs, lib, ... }:

{ boot.supportedFilesystems = [ "zfs" ];
	# Kernel modules needed for mounting LUKS devices in initrd stage
	boot.initrd.availableKernelModules = [ "aesni_intel" "cryptd" ];

	boot.initrd.luks.devices = {
		cryptkey = {
			device = "/dev/disk/by-uuid/$CRYPTKEY";
		};

		cryptswap = {
			device = "/dev/disk/by-uuid/$CRYPTSWAP";
			keyFile = "$KEY_DISK";
			keyFileSize = 64;
		};
	};

	networking.hostId = "$(head -c 8 /etc/machine-id)";
	boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;

	boot.initrd.postDeviceCommands = lib.mkAfter ''
		zfs rollback -r rpool/local/root@blank
	'';

	boot.loader = {
		efi.efiSysMountPoint = "/boot/efi";
		generationsDir.copyKernels = true;
		grub = {
		enable = true;
		version = 2;
		efiInstallAsRemovable = true;
		copyKernels = true;
		efiSupport = true;
		zfsSupport = true;
		device = "nodev";
		};
	};

	users.users.root.initialHashedPassword = "$rootPwd";

	systemd.tmpfiles.rules = [
		"L /etc/nixos - - - - /persist/etc/nixos"
	];

}
EOF

# Install system and apply configuration
nixos-install -v --show-trace --no-root-passwd --root /mnt

# Unmount filesystems
umount -Rl /mnt
zpool export -a

# Reboot
reboot
```

## Setting up the RAIDZ2 pool
```bash
# Create a pool called ocean
zpool create -f \
	-o ashift=12 \
	-o autotrim=on \
	-O acltype=posixacl \
	-O compression=lz4 \
	-O dnodesize=auto \
	-O normalization=formD \
	-O xattr=sa \
	-O atime=off \
	-O mountpoint=legacy \
	-O encryption=aes-256-gcm \
	-O keylocation=file:///dev/mapper/cryptkey \
	-O keyformat=hex \
	ocean \
	raidz2 \
	/dev/sda /dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf

zfs create -p -o mountpoint=legacy ocean/nas
mkdir -p /ocean/nas
mount -t zfs ocean/nas /ocean/nas

zfs create -p -o mountpoint=legacy ocean/media
mkdir -p /ocean/media
mount -t zfs ocean/media /ocean/media

zfs create -p -o mountpoint=legacy ocean/public
mkdir -p /ocean/public
mount -t zfs ocean/public /ocean/public

zfs create -p -o mountpoint=legacy ocean/backup
mkdir -p /ocean/backup
mount -t zfs ocean/backup/megakill /backup
```

## Setting up SSH in Initrd for remote decrypt



## Resources
- [Erase your darlings](https://grahamc.com/blog/erase-your-darlings)