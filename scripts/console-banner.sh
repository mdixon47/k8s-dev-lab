#!/usr/bin/env bash
# Every VM: keep kernel/cloud-init chatter off the tty login prompt and print the lab
# credentials in the banner (dev-only box; the vagrant user is passwordless sudo anyway).
set -euo pipefail
echo "kernel.printk = 3 4 1 3" >/etc/sysctl.d/k8s-console.conf
sysctl -q -p /etc/sysctl.d/k8s-console.conf
cat >/etc/issue <<'I'
\n (\l)  k8s-dev-lab node
Login: vagrant   Password: vagrant   (sudo needs no password)
Press Enter if this prompt is buried under boot messages.

I
