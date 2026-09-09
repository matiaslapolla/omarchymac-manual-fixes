#!/bin/bash
#
# omarchy-mac fixes for MacBook Air M1 (apple,j313 / t8103), BCM4378.
# Run with: sudo bash omarchy-mac-fixes.sh
#
#   1. Widevine + vulkan-asahi        (unblocks DRM streaming; issue #220)
#   2. grep -qi -> grep -qai          (root cause of #220, so it stays fixed)
#   3. Wi-Fi resume recovery          (issue #197, port of open PR #255)
#   4. Bluetooth wedge recovery       (issues #302 / #338)
#
set -uo pipefail

(( EUID == 0 )) || { echo "Run me with sudo." >&2; exit 1; }

CHECKOUT=/home/omarchymac/.local/share/omarchy
LIVE=/usr/share/omarchy
log() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  ! \033[0m%s\n' "$*"; }

# ---------------------------------------------------------------- 1. Widevine
# The migration that installs this is gated behind the broken grep in step 2,
# so it has never run. The package itself is in [asahi-alarm] and installs fine.
log "Installing Widevine (Netflix / Spotify web / Disney+ / Prime Video)"
pacman -S --needed --noconfirm widevine || warn "widevine failed"

# Same gate blocked the Vulkan driver, which is what gives GPU acceleration
# to anything using Vulkan rather than plain GL.
log "Installing vulkan-asahi"
pacman -S --needed --noconfirm vulkan-asahi || warn "vulkan-asahi not available"

# ------------------------------------------------------------- 2. grep -a fix
# /proc/device-tree/compatible is NUL-separated with no trailing newline, so
# GNU grep treats it as binary and reports no match. Every Apple Silicon
# detection in the tree uses the plain form and therefore never fires on the
# exact hardware it targets. -a makes grep read it as text.
log "Patching Apple Silicon detection (grep -qi -> grep -qai)"
for root in "$LIVE" "$CHECKOUT"; do
  [[ -d $root ]] || continue
  mapfile -t files < <(grep -rl --include='*.sh' --include='omarchy-*' \
    -e 'grep -qi "apple" /proc/device-tree/compatible' \
    -e 'grep -qi apple /proc/device-tree/compatible' "$root" 2>/dev/null)
  for f in "${files[@]}"; do
    sed -i \
      -e 's|grep -qi "apple" /proc/device-tree/compatible|grep -qai "apple" /proc/device-tree/compatible|g' \
      -e 's|grep -qi apple /proc/device-tree/compatible|grep -qai apple /proc/device-tree/compatible|g' "$f"
    echo "    patched ${f#$root/}  (in ${root})"
  done
done

# ------------------------------------------------------- 3. Wi-Fi on resume
# BCM4378/BCM4387 firmware wedges across s2idle: scans fail with -52 and every
# association is rejected with status_code=16, which NetworkManager surfaces as
# a wrong password. Only a driver reload clears it.
# Upstream: https://github.com/AsahiLinux/linux/issues/439
#
# Deliberately a service ordered After=suspend.target, NOT a system-sleep hook:
# a sleep hook runs synchronously and would delay every single resume.
log "Installing Wi-Fi resume recovery"
cat > /usr/local/bin/omarchy-wifi-resume-fix <<'EOWIFI'
#!/bin/bash
# Reload brcmfmac if Wi-Fi does not come back after resume.
# Logs: journalctl -u omarchy-wifi-resume-fix
WAIT_BEFORE=12   # backstop: reload anyway if wifi is still down after this
WAIT_AFTER=30    # seconds to wait for reconnect after the reload
REJECTS=2        # ASSOC-REJECT status_code=16 events that confirm a wedge

START=$(date '+%Y-%m-%d %H:%M:%S')
# Journal cursor rather than a --since window: on some Apple Silicon kernels the
# clock steps backwards across resume, which would leave a time window empty.
CURSOR=$(journalctl -q -n 0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')

wifi_iface() { nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1;exit}'; }
wifi_state() { nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v d="$1" '$1==d{print $2;exit}'; }

# \b keeps status_code=160-169 from counting as the signature.
REJECT_SIGNATURE='CTRL-EVENT-ASSOC-REJECT.*status_code=16\b'
wedged() {
  local n
  if [[ -n $CURSOR ]]; then
    n=$(journalctl -q --after-cursor "$CURSOR" -t wpa_supplicant --no-pager 2>/dev/null | grep -c "$REJECT_SIGNATURE")
  else
    n=$(journalctl -q --since "$START" -t wpa_supplicant --no-pager 2>/dev/null | grep -c "$REJECT_SIGNATURE")
  fi
  (( ${n:-0} >= REJECTS ))
}

# Respect a deliberately disabled radio.
[[ $(nmcli radio wifi 2>/dev/null) == "disabled" ]] && { echo "wifi radio disabled, nothing to do"; exit 0; }

IFACE=$(wifi_iface); : "${IFACE:=wlan0}"
i=0
while (( i < WAIT_BEFORE )); do
  state=$(wifi_state "$IFACE")
  [[ $state == "connected" ]] && { echo "wifi back after ${i}s on $IFACE - no reload needed"; exit 0; }
  if wedged; then echo "wedged firmware confirmed after ${i}s (iface=$IFACE state=${state:-none}) - reloading"; break; fi
  i=$((i+1)); sleep 1
done
(( i >= WAIT_BEFORE )) && echo "wifi not back after ${WAIT_BEFORE}s (iface=$IFACE state=${state:-none}) - reloading"

modprobe -r brcmfmac_wcc brcmfmac || { echo "failed to unload brcmfmac - reboot needed"; exit 1; }
sleep 1
modprobe brcmfmac || { echo "failed to reload brcmfmac - reboot needed"; exit 1; }
echo "brcmfmac reloaded, waiting for NetworkManager"

i=0
while (( i < WAIT_AFTER )); do
  IFACE=$(wifi_iface); : "${IFACE:=wlan0}"
  state=$(wifi_state "$IFACE")
  [[ $state == "connected" ]] && { echo "reconnected ${i}s after reload on $IFACE"; exit 0; }
  i=$((i+1)); sleep 1
done
echo "still not connected ${WAIT_AFTER}s after reload (iface=$IFACE state=${state:-none})"
exit 1
EOWIFI
chmod +x /usr/local/bin/omarchy-wifi-resume-fix

cat > /etc/systemd/system/omarchy-wifi-resume-fix.service <<'EOWIFISVC'
[Unit]
Description=Reload brcmfmac if Wi-Fi does not return after resume
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/omarchy-wifi-resume-fix
TimeoutStartSec=120

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOWIFISVC

# --------------------------------------------------------- 4. Bluetooth wedge
# BRCM4378/4387 firmware hangs after an rfkill block or a clamshell resume:
# rfkill reads unblocked, but the adapter stays Powered: no and BlueZ returns
# org.bluez.Error.Failed. Only a PCI unbind/bind of hci_bcm4377 resets it --
# "omarchy restart bluetooth" does not, it only touches rfkill.
log "Installing Bluetooth rebind recovery"
cat > /usr/local/bin/omarchy-bluetooth-rebind <<'EOBT'
#!/bin/bash
# Reset wedged BRCM Bluetooth firmware by rebinding its PCI device.
# Run bare to force a rebind; --if-wedged only acts when the adapter is stuck.
DRV=/sys/bus/pci/drivers/hci_bcm4377
[[ -d $DRV ]] || { echo "hci_bcm4377 not loaded"; exit 0; }

# The Bluetooth function is the .1 of the same card as Wi-Fi.
SLOT=$(basename "$(ls -d "$DRV"/0000:* 2>/dev/null | head -1)" 2>/dev/null)

powered() { bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; }
blocked()  { rfkill list bluetooth 2>/dev/null | grep -q "Soft blocked: yes"; }

if [[ ${1:-} == "--if-wedged" ]]; then
  # A deliberately-off radio is not a wedge; leave it alone.
  blocked  && { echo "bluetooth soft blocked by user, leaving it"; exit 0; }
  powered  && { echo "bluetooth healthy, nothing to do"; exit 0; }
  # Give BlueZ a normal chance to bring it up before resetting the hardware.
  rfkill unblock bluetooth 2>/dev/null
  bluetoothctl power on >/dev/null 2>&1
  sleep 3
  powered && { echo "bluetooth recovered without a rebind"; exit 0; }
  echo "bluetooth wedged - rebinding $SLOT"
fi

if [[ -z $SLOT ]]; then
  # Already unbound by a previous half-failed attempt: rebinding needs the slot
  # name, which is the Wi-Fi function's .1 sibling.
  SLOT=$(lspci -D 2>/dev/null | awk '/Bluetooth/{print $1; exit}')
  [[ -n $SLOT ]] || { echo "cannot find the Bluetooth PCI slot"; exit 1; }
else
  echo "$SLOT" > "$DRV/unbind" 2>/dev/null && echo "unbound $SLOT"
  sleep 2
fi

echo "$SLOT" > "$DRV/bind" 2>/dev/null || echo "bind returned an error (it may have re-bound on its own)"
sleep 2
rfkill unblock bluetooth 2>/dev/null
bluetoothctl power on >/dev/null 2>&1
sleep 2
if powered; then echo "bluetooth back up"; else echo "still down - a reboot is the last resort"; exit 1; fi
EOBT
chmod +x /usr/local/bin/omarchy-bluetooth-rebind

cat > /etc/systemd/system/omarchy-bluetooth-resume-fix.service <<'EOBTSVC'
[Unit]
Description=Recover wedged Broadcom Bluetooth after resume
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
After=bluetooth.service

[Service]
Type=oneshot
ExecStartPre=/usr/bin/sleep 5
ExecStart=/usr/local/bin/omarchy-bluetooth-rebind --if-wedged
TimeoutStartSec=90

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOBTSVC

systemctl daemon-reload
systemctl enable omarchy-wifi-resume-fix.service omarchy-bluetooth-resume-fix.service

log "Done. Verify with:"
echo "    ls -d /usr/lib/chromium/WidevineCdm"
echo "    systemctl is-enabled omarchy-wifi-resume-fix omarchy-bluetooth-resume-fix"
echo "    journalctl -u omarchy-wifi-resume-fix -u omarchy-bluetooth-resume-fix"
