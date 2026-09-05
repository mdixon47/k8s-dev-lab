#!/usr/bin/env bash
# Optional: XFCE desktop on one node (DESKTOP_NODE in the Vagrantfile, default cp1) for
# learning and sandboxing. Auto-logs in as `vagrant`; Firefox and a terminal are included.
# On arm64 this needs the HWE kernel from scripts/console-kernel.sh, otherwise there is no
# framebuffer for X to draw on.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ ! -e /dev/fb0 ] && [ ! -d /dev/dri ]; then
  echo "No framebuffer or DRM device; the desktop would have nothing to draw on." >&2
  echo "On arm64, enable the console kernel (K8S_CONSOLE_KERNEL=1) first." >&2
  exit 1
fi

if dpkg -s xfce4-session >/dev/null 2>&1; then
  echo "Desktop packages already installed"
else
  apt-get update -q
  apt-get install -y -q xorg xfce4 xfce4-terminal xfce4-whiskermenu-plugin lightdm lightdm-gtk-greeter \
    dbus-x11 xdg-utils fonts-dejavu mousepad
  apt-get install -y -q firefox
fi
# No lock screen in a lab: it only asks for the vagrant password and confuses people.
apt-get purge -y -q xfce4-screensaver light-locker xscreensaver 2>/dev/null || true

# Auto-login straight into XFCE (dev sandbox; the vagrant account is already passwordless sudo)
mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/50-autologin.conf <<'L'
[Seat:*]
autologin-user=vagrant
autologin-user-timeout=0
user-session=xfce
L
# lightdm autologin needs the user in this group on Ubuntu
groupadd -f autologin
usermod -aG autologin vagrant

# VirtualBox X11 integration (shared clipboard). Only present with Oracle Guest Additions.
GA_X11="$(ls -d /opt/VBoxGuestAdditions-*/init/vboxadd-x11 2>/dev/null | head -1 || true)"
if [ -n "${GA_X11}" ]; then
  "${GA_X11}" setup || echo "WARN: Guest Additions X11 setup failed; clipboard sharing may not work" >&2
fi

# VirtualBox's GUI sends a "resize to window" hint whenever the VM window opens. Guest
# Additions' `VBoxClient --vmsvga` acts on it, but the ramfb display used for ARM64 guests
# cannot change mode, and the failed attempt leaves the only output disabled: a black
# screen behind a running desktop. Stop that service at login and keep the output enabled.
cat >/usr/local/bin/vbox-display-fix <<'F'
#!/usr/bin/env bash
xset s off -dpms 2>/dev/null || true
for _ in $(seq 1 15); do
  pkill -f 'VBoxClient --vmsvg[a]' 2>/dev/null || true
  for out in $(xrandr 2>/dev/null | awk '/ connected/ {print $1}'); do
    xrandr --output "$out" --auto 2>/dev/null || true
  done
  sleep 2
done
F
chmod +x /usr/local/bin/vbox-display-fix
cat >/etc/xdg/autostart/vbox-display-fix.desktop <<'D'
[Desktop Entry]
Type=Application
Name=VirtualBox display fix
Exec=/usr/local/bin/vbox-display-fix
NoDisplay=true
X-GNOME-Autostart-Phase=Initialization
D

systemctl set-default graphical.target
systemctl enable lightdm
# Don't kick a logged-in user off the desktop when this script is re-run
systemctl is-active -q lightdm || systemctl start lightdm
echo "Desktop ready: open the VM in the VirtualBox app and click Show"
