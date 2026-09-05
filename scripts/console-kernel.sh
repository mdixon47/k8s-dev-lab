#!/usr/bin/env bash
# Optional, arm64 hosts only: make the VirtualBox console window usable.
#
# Ubuntu 22.04's stock 5.15 kernel has no driver for the display VirtualBox gives ARM64
# guests, so the console window freezes at "EFI stub: Exiting boot services" even though
# the OS is up. The HWE kernel (6.8, simpledrm) fixes that. The kernel switch has two
# side effects this script handles:
#   * Oracle Guest Additions (vboxsf, which backs /vagrant) must be rebuilt for the new
#     kernel with the compiler the kernel was built with.
#   * Guest Additions 7.2.x only expect CONFIG_PAGE_SHIFT on kernels >= 6.9, but Ubuntu's
#     6.8 HWE kernel already ships it, so the headers need a one-line patch.
# The Vagrantfile reboots the node after this script so the new kernel is running before
# kubeadm touches the node.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ "$(dpkg --print-architecture)" != "arm64" ]; then
  echo "Not an arm64 guest; console kernel not needed"; exit 0
fi
if [ ! -x /sbin/rcvboxadd ]; then
  echo "Oracle Guest Additions installer not present; skipping console kernel (would break /vagrant)"; exit 0
fi
if ls /lib/modules/6.*/misc/vboxsf.ko* >/dev/null 2>&1; then
  echo "Console kernel already installed with Guest Additions modules"; exit 0
fi

apt-get update -q
apt-get install -y -q linux-generic-hwe-22.04 make

KVER="$(ls /lib/modules | grep -E '^6\.' | sort -V | tail -1)"
CC="$(grep -oE 'gcc-[0-9]+' "/lib/modules/${KVER}/build/.config" | head -1)"
apt-get install -y -q "${CC:-gcc}"

for f in /opt/VBoxGuestAdditions-*/src/vboxguest-*/*/include/iprt/param.h; do
  # headers have CRLF line endings; keep the \r
  sed -i -E 's/RTLNX_VER_MIN\(6,9,0\)(\r?)$/RTLNX_VER_MIN(6,9,0) || defined(CONFIG_PAGE_SHIFT)\1/' "$f"
done

echo "Building Guest Additions modules for ${KVER}"
/sbin/rcvboxadd quicksetup "${KVER}"
ls /lib/modules/"${KVER}"/misc/vboxsf.ko* >/dev/null \
  || { echo "ERROR: vboxsf did not build for ${KVER}; see /var/log/vboxadd-setup.log" >&2; exit 1; }
echo "Console kernel ${KVER} ready; reboot required"
