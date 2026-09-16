#!/usr/bin/env bash
# Optional: the stock Ubuntu desktop (GNOME Shell, Ubuntu dock, Yaru theme) on one node
# (DESKTOP_NODE in the Vagrantfile, default cp1) for learning and sandboxing. Auto-logs in
# as `vagrant`; Firefox, Files, App Center and a terminal are included, no lock screen.
# Needs a framebuffer for the session to draw on; the stock Ubuntu 26.04 kernel (7.0,
# simpledrm) provides one for VirtualBox guests on both amd64 and arm64.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ ! -e /dev/fb0 ] && [ ! -d /dev/dri ]; then
  echo "No framebuffer or DRM device; the desktop would have nothing to draw on." >&2
  echo "The running kernel has no driver for the VirtualBox display; check 'dmesg | grep -i drm'." >&2
  exit 1
fi

# Auto-login straight into GNOME (dev sandbox; the vagrant account is already passwordless sudo).
# Written before the packages so GDM reads it on its very first start. The session is Wayland
# (GNOME 50 on 26.04 ships no Xorg session); Guest Additions' clipboard attaches to XWayland
# and mutter bridges it to Wayland apps, so copy/paste with the host works in both directions.
mkdir -p /etc/gdm3
cat >/etc/gdm3/custom.conf <<'G'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=vagrant

[security]

[xdmcp]

[chooser]

[debug]
G

if dpkg -s ubuntu-desktop-minimal >/dev/null 2>&1; then
  echo "Desktop packages already installed"
else
  apt-get update -q
  # gdm3 is the display manager; answer the debconf question in case lightdm is present
  echo "gdm3 shared/default-x-display-manager select gdm3" | debconf-set-selections
  apt-get install -y -q ubuntu-desktop-minimal gdm3 gnome-terminal xdg-utils fonts-dejavu wl-clipboard xclip
  apt-get install -y -q firefox
fi
# App Center lives in the Ubuntu dock; it is a snap, not a deb, so it is best effort here.
snap list snap-store >/dev/null 2>&1 || snap install snap-store 2>/dev/null || true

# Earlier versions of this script installed XFCE + lightdm; retire them so only GDM owns the tty.
if dpkg -s lightdm >/dev/null 2>&1 || dpkg -s xfce4-session >/dev/null 2>&1; then
  systemctl disable --now lightdm 2>/dev/null || true
  apt-get purge -y -q 'xfce4*' lightdm lightdm-gtk-greeter xfce4-screensaver light-locker 2>/dev/null || true
  apt-get autoremove -y -q || true
fi
echo /usr/sbin/gdm3 >/etc/X11/default-display-manager

# No lock screen or blanking in a lab: it only asks for the vagrant password and confuses people.
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
cat >/etc/dconf/profile/user <<'P'
user-db:user
system-db:local
P
cat >/etc/dconf/db/local.d/00-lab <<'C'
[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/lockdown]
disable-lock-screen=true

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
C
dconf update
# The first-login "Welcome to Ubuntu" tour and the "N updates available" pop-up are noise in
# a lab (and an unattended kernel upgrade would break the Guest Additions modules).
apt-get purge -y -q gnome-initial-setup update-notifier 2>/dev/null || true

# VirtualBox integration (VBoxClient clipboard service on XWayland). Only present with Oracle Guest Additions.
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
systemctl enable gdm3
# Don't kick a logged-in user off the desktop when this script is re-run
systemctl is-active -q gdm3 || systemctl start gdm3
echo "Desktop ready: the VM window opens at boot (K8S_GUI), or open the VirtualBox app and click Show"
