#!/bin/sh

# apk add util-linux qemu-riscv64 qemu-img qemu-openrc losetup blkid sgdisk e2fsprogs wget tar
set -eu

: "${DISK:=pine64-star64-mmc.img}"
: "${DISKSIZE:=1200M}"

readonly SCRIPT="${0##*/}"
readonly TMPDIR="$(mktemp -dt "${SCRIPT%.*}".XXXXXX)"
readonly APK_KEY="alpine-devel@lists.alpinelinux.org-60ac2099.rsa.pub"
readonly MIRROR="https://dl-cdn.alpinelinux.org/alpine"
readonly LOOPDEV="$(losetup --find)"
readonly BOOTDEV="$LOOPDEV"p3
readonly ROOTDEV="$LOOPDEV"p4

cleanup() {
	set +e
	mountpoint -q "$TMPDIR"/boot && umount "$TMPDIR"/boot
	mountpoint -q "$TMPDIR" && umount "$TMPDIR"
	losetup --detach-all
	rm -rf "$TMPDIR"
}

trap cleanup EXIT INT

rm -f $DISK
truncate -s $DISKSIZE $DISK

echo "Paritioning disk"
sgdisk --clear \
  --set-alignment=2 \
  --new=1:4096:+2MiB: --change-name=1:spl --typecode=1:2E54B353-1271-4842-806F-E436D6AF6985\
  --new=2::+4MiB: --change-name=2:uboot --typecode=2:BC13C2FF-59E6-4262-A352-B275FD6F7172  \
  --new=3::+128MiB: --change-name=3:boot --typecode=3:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
  --new 4::: -c 4:root \
"${DISK}"
sgdisk --attributes=3:set:2 ${DISK}
#-n 4::: -c 4:root -A 4:set:2 \

echo "Creating dirs and mounting"
losetup -P "$LOOPDEV" "$DISK"
mkfs.ext4 -qL mmc1.bfs "$BOOTDEV"
mkfs.ext4 -qL mmc1.rfs "$ROOTDEV"
mount -t ext4 "$ROOTDEV" "$TMPDIR"
mkdir -p "$TMPDIR"/boot
mkdir -p "$TMPDIR"/etc/apk/keys
mount -t ext4 "$BOOTDEV" "$TMPDIR"/boot

echo "Setup apk keys and repositories"
wget -qP "$TMPDIR"/etc/apk/keys https://alpinelinux.org/keys/"$APK_KEY"
printf "$MIRROR/edge/%s\n" main community testing > "$TMPDIR"/etc/apk/repositories

echo "installing base packages"
apk --allow-untrusted --root "$TMPDIR" --arch riscv64 --initdb add \
	alpine-base alpine-baselayout alpine-conf kmod openrc \
	dbus util-linux blkid chrony \
	sysfsutils ssl_client ca-certificates-bundle alpine-keys \
	ethtool e2fsprogs e2fsprogs-extra libudev-zero libudev-zero-helper \
	iwd linux-firmware-brcm linux-firmware-cypress installkernel mkinitfs \
	agetty openresolv tar tzdata openssh wget sgdisk \
	u-boot-starfive linux-lts linux-lts-dev \
	make gcc build-base linux-headers iw pciutils \
	akms apk-tools bubblewrap \
	micro tmux btop pfetch-rs

dd if="$TMPDIR"/usr/share/u-boot/starfive_visionfive2/u-boot-spl.bin.normal.out of=${LOOPDEV}p1
dd if="$TMPDIR"/usr/share/u-boot/starfive_visionfive2/u-boot.itb of=${LOOPDEV}p2

echo "Setting up services"
for rc in boot/bootmisc boot/hostname boot/modules boot/sysctl boot/urandom boot/networking \
	sysinit/devfs sysinit/hwdrivers sysinit/mdev sysinit/modules \
	shutdown/mount-ro shutdown/killprocs \
	default/dbus default/chronyd default/local; do
	ln -s /etc/init.d/"${rc##*/}" "$TMPDIR"/etc/runlevels/"$rc"
done

echo 'SUBSYSTEM=drm;.*   root:video 660 */usr/libexec/libudev-zero-helper' >>  $TMPDIR/etc/mdev.conf
echo 'SUBSYSTEM=input;.* root:input 660 */usr/libexec/libudev-zero-helper' >>  $TMPDIR/etc/mdev.conf
# echo 'blacklist jh7110_crypto' >>  $TMPDIR/etc/modprobe.d/blacklist-local.conf
echo "LABEL=mmc1.bfs	/boot	ext4	auto" >> $TMPDIR/etc/fstab

echo "Copying rtl8852bu driver src"
mkdir -p "$TMPDIR"/usr/src/
if [ ! -d rtl8852bu-20240418 ]; then 
	git clone https://github.com/morrownr/rtl8852bu-20240418.git
else
	cd rtl8852bu-20240418 && git pull && cd ..
fi
cp -r rtl8852bu-20240418 "$TMPDIR"/usr/src/

echo "Writing rtl8852bu AKMBUILD"
install -m644 AKMBUILD "$TMPDIR"/usr/src/rtl8852bu-20240418/AKMBUILD

echo "Setting boot loader"
bootuuid=$(blkid -s UUID -o value $BOOTDEV)
rootuuid=$(blkid -s UUID -o value $ROOTDEV)

mkdir -p "$TMPDIR"/boot/extlinux
cat <<EOF > "$TMPDIR"/boot/extlinux/extlinux.conf
menu title StarFive VisionFive
timeout 50
default linux-lts

label linux-lts
	menu label Alpine LTS
	kernel /vmlinuz-lts
	initrd /initramfs-lts
	fdtdir /dtbs-lts/
	append earlycon=sbi rw root=UUID=$rootuuid rootfstype=ext4 rootwait console=ttyS0,115200 console=tty0

EOF

echo "Setting up inittab"
sed -i 's/^tty1.*/tty1::respawn:\/sbin\/agetty -L 115200 tty1 linux --login-pause --autologin root --noclear/' $TMPDIR/etc/inittab
sed -i 's/^#ttyS0/ttyS0/' $TMPDIR/etc/inittab
sed -i 's/^ttyS0.*/ttyS0::respawn:\/sbin\/agetty -L 115200 ttyS0 linux --login-pause --autologin root --noclear/' $TMPDIR/etc/inittab

echo "Finished, cleaning up"
