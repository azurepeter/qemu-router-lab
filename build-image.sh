#!/usr/bin/env bash
# Build router-base.qcow2: Ubuntu 22.04.4 server with FRRouting, by unattended
# install in a KVM virtual machine. Takes about seven minutes.
#
#   ./build-image.sh path/to/ubuntu-22.04.4-live-server-amd64.iso
set -euo pipefail

ISO=${1:?usage: $0 path/to/ubuntu-22.04.4-live-server-amd64.iso}
ISO_SHA256=45f873de9f8cb637345d6e66a583762730bbea30277ef7b32c9c3bd6700a32b2
cd "$(dirname "$0")"

[ -w /dev/kvm ] || { echo "needs read-write access to /dev/kvm" >&2; exit 1; }
echo "$ISO_SHA256  $ISO" | sha256sum -c --quiet

# The key every router accepts. Generated locally, never committed.
[ -f admin_key ] || ssh-keygen -q -t ed25519 -N '' -C lab-admin -f admin_key

rm -rf build && mkdir -p build/nocloud
cat > build/nocloud/user-data <<EOF
#cloud-config
autoinstall:
  version: 1
  ssh:
    install-server: true
    allow-pw: false
  storage:
    layout:
      name: lvm
  packages:
    - frr
  user-data:
    hostname: router-base
    users:
      - name: admin
        lock_passwd: true
        shell: /bin/bash
        sudo: ALL=(ALL) NOPASSWD:ALL
        ssh_authorized_keys:
          - $(cat admin_key.pub)
  late-commands:
    - echo 'net.ipv4.ip_forward=1' > /target/etc/sysctl.d/90-router.conf
    # Every clone generates its own machine-id on first boot.
    - truncate -s 0 /target/etc/machine-id
    - sed -i -e 's/^ospfd=no/ospfd=yes/' -e 's/^bgpd=no/bgpd=yes/' -e 's/^bfdd=no/bfdd=yes/' /target/etc/frr/daemons
  shutdown: poweroff
EOF
: > build/nocloud/meta-data

# Boot straight into the installer, unattended, with its log on the serial port.
osirrox -indev "$ISO" -extract /boot/grub/grub.cfg build/grub.cfg 2>/dev/null
chmod u+w build/grub.cfg
python3 - build/grub.cfg <<'PY'
import re, sys
path = sys.argv[1]
cfg = open(path).read()
cfg = re.sub(r'^set timeout=.*$', 'set timeout=1', cfg, count=1, flags=re.M)
# In GRUB an unescaped ';' ends the command, so the backslash is required.
cfg, n = re.subn(r'(linux\s+/casper/vmlinuz)\s+---',
                 r'\1 autoinstall ds=nocloud\\;s=/cdrom/nocloud/ console=ttyS0 ---', cfg, count=1)
if n != 1:
    sys.exit("could not find the kernel line in grub.cfg")
open(path, 'w').write(cfg)
PY

xorriso -indev "$ISO" -outdev build/router-autoinstall.iso \
  -map build/nocloud /nocloud -map build/grub.cfg /boot/grub/grub.cfg \
  -boot_image any replay 2>/dev/null

rm -f router-base.qcow2
qemu-img create -q -f qcow2 router-base.qcow2 10G
echo "installing; progress in build/install.log"
start=$(date +%s)
timeout 1800 qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 4 \
  -drive file=router-base.qcow2,if=virtio,format=qcow2 \
  -cdrom build/router-autoinstall.iso -boot once=d \
  -display none -serial file:build/install.log \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
if grep -aq "An error occurred" build/install.log; then
  echo "the install failed; see build/install.log" >&2
  exit 1
fi
echo "router-base.qcow2 built in $(( $(date +%s) - start ))s"
