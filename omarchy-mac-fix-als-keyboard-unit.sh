#!/bin/bash
#
# The keyboard-backlight-from-ALS service never starts, because its unit file
# is not where anything looks for it.
#
# omarchy 4.0.2-2 ships the binary (/usr/bin/omarchy-brightness-keyboard-auto)
# and omarchy-settings 4.0.2-2 ships the unit *source* at
# /usr/share/omarchy/default/systemd/user/omarchy-brightness-keyboard-auto.service
# -- but omarchy-settings never installs that one into /usr/lib/systemd/user/,
# the way it installs every other user unit it owns. So:
#
#   $ systemctl --user is-enabled omarchy-brightness-keyboard-auto
#   not-found
#
# Migration 1788139121 then makes it worse rather than louder: `systemctl --user
# enable` fails (no such unit), and its fallback writes the symlink that enable
# would have written -- pointing at the /usr/lib path that does not exist. The
# result is a dangling link in graphical-session.target.wants and a service that
# silently never runs.
#
# This links the packaged source into /etc/systemd/user, which is in the user
# manager's search path and is never touched by pacman, and repairs the dangling
# wants symlink. Linking rather than copying means the unit keeps tracking the
# packaged file across upgrades. When omarchy-settings eventually installs the
# unit itself, remove /etc/systemd/user/omarchy-brightness-keyboard-auto.service
# and re-enable.
#
# Run as your user, not root.
set -euo pipefail
(( EUID != 0 )) || { echo "run as your user, not root" >&2; exit 1; }

readonly unit=omarchy-brightness-keyboard-auto.service
readonly source=/usr/share/omarchy/default/systemd/user/$unit
readonly packaged=/usr/lib/systemd/user/$unit
readonly admin=/etc/systemd/user/$unit
readonly wants=$HOME/.config/systemd/user/graphical-session.target.wants/$unit

log() { printf '\033[32m==>\033[0m %s\n' "$*"; }

[[ -f $source ]] || { echo "no packaged unit source at $source" >&2; exit 1; }

if [[ -f $packaged ]]; then
  log "omarchy-settings now installs $unit itself -- nothing to do."
  log "If $admin exists, remove it and run: systemctl --user reenable $unit"
  exit 0
fi

# A dangling wants symlink left by migration 1788139121. Removing it lets
# `systemctl --user enable` write a correct one from the unit's [Install].
if [[ -L $wants && ! -e $wants ]]; then
  log "Removing the dangling wants symlink from migration 1788139121"
  rm -f "$wants"
fi

log "Linking the packaged unit source into /etc/systemd/user"
sudo install -d -m 755 /etc/systemd/user
sudo ln -sfn "$source" "$admin"

log "Reloading and enabling"
systemctl --user daemon-reload
systemctl --user enable --now "$unit"

log "Result"
systemctl --user is-enabled "$unit"
systemctl --user is-active "$unit"
echo
echo "Ambient light now: $(cat /sys/bus/iio/devices/iio:device0/in_illuminance_input 2>/dev/null || echo '?') lux"
echo "Keyboard backlight: $(brightnessctl -d kbd_backlight get 2>/dev/null || echo '?') / 255"
echo
echo "In a bright room 0 is the correct answer. Cover the sensor (top of the"
echo "screen, next to the camera) for a few seconds to see it come up."
