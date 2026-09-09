#!/bin/bash
#
# Work around the Arch Linux ARM aquamarine ABI mismatch that blocks Omarchy
# Mac installs and updates (omarchy-mac/omarchy-mac#341, 2026-09-04).
#
# ALARM [extra] ships aquamarine 0.15.0-2 (libaquamarine.so=14) while its
# hyprland 0.56.1-3 and hyprtoolkit 0.5.4-5 still link libaquamarine.so=13.
# The old aquamarine build is not archived anywhere, so something has to be
# built locally. Two ways out:
#
#   --rebuild  (default) Build hyprtoolkit 0.5.4-5, hyprland-guiutils 0.2.2-3
#              and hyprland 0.56.2-2 against aquamarine 0.15 using the upstream
#              Arch PKGBUILDs. Ends in the same state x86_64 Arch is in today.
#              ~30-45 min on an M1 Air. No pacman pinning needed afterwards;
#              ALARM's eventual rebuild (pkgrel bump) replaces these normally.
#
#   --pin      Build aquamarine 0.14.0-2 (~3 min), install it, and set
#              IgnorePkg = aquamarine so pacman keeps it. Then the stock ALARM
#              hyprland/hyprtoolkit install fine. Omarchy's post-install step
#              overwrites /etc/pacman.conf, so re-add the IgnorePkg line after
#              the install finishes, and drop it once ALARM rebuilds.
#
# Run as your regular user (the one omarchy-mac-setup created), not root.
# When done, continue the install with:  sudo omarchy-mac-setup --resume

set -euo pipefail

readonly arch_gitlab="https://gitlab.archlinux.org/archlinux/packaging/packages"
readonly build_root="$HOME/build/hypr-abi-fix"
mode="rebuild"

log() { printf '\033[32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  "" | --rebuild) mode="rebuild" ;;
  --pin) mode="pin" ;;
  *) fail "usage: $0 [--rebuild|--pin]" ;;
esac

[[ $(uname -m) == aarch64 ]] || fail "this is for Apple Silicon (aarch64)"
if (( EUID == 0 )); then
  user=$(sed -n 's/^SETUP_USER=//p' /etc/omarchy-mac-setup.conf 2>/dev/null | tr -d "'\"" || true)
  fail "makepkg refuses to run as root. Switch to your user first:  su - ${user:-<your-user>}"
fi
sudo -v || fail "need sudo"

# makepkg config: parallel build, no debug packages (halves build time and
# disk), no LTO (slower to link on aarch64, no benefit here).
mkdir -p "$build_root"
cat >"$build_root/makepkg.conf" <<EOF
source /etc/makepkg.conf
MAKEFLAGS="-j$(nproc)"
OPTIONS+=(!debug !lto)
PKGDEST="$build_root/out"
EOF
mkdir -p "$build_root/out"
export MAKEPKG_CONF="$build_root/makepkg.conf"

# fetch_pkgbuild <name> <tag>
fetch_pkgbuild() {
  local name="$1" tag="$2" dir="$build_root/$name"
  rm -rf "$dir" && mkdir -p "$dir"
  curl -fsSL "$arch_gitlab/$name/-/raw/$tag/PKGBUILD" -o "$dir/PKGBUILD" ||
    fail "could not fetch PKGBUILD for $name $tag"
  # hyprtoolkit is arch=(x86_64) upstream even though it builds fine here.
  sed -i 's/^arch=(x86_64)$/arch=(x86_64 aarch64)/' "$dir/PKGBUILD"
}

# build_install <name> <tag>: makepkg -s pulls deps from the repos, -i installs.
build_install() {
  local name="$1" tag="$2"
  log "Building $name $tag"
  fetch_pkgbuild "$name" "$tag"
  (cd "$build_root/$name" && makepkg -si --noconfirm --needed)
}

log "Refreshing databases and installing build tools"
# hyprwayland-scanner is a find_package() requirement the upstream PKGBUILDs
# do not declare (it arrives transitively in Arch's build chroots).
sudo pacman -Sy --needed --noconfirm base-devel git cmake meson ninja pkgconf \
  hyprwayland-scanner hyprland-protocols glslang glaze xorgproto python

if [[ $mode == pin ]]; then
  build_install aquamarine 0.14.0-2

  log "Pinning aquamarine in /etc/pacman.conf"
  if grep -qE '^IgnorePkg' /etc/pacman.conf; then
    grep -qE '^IgnorePkg.*\baquamarine\b' /etc/pacman.conf ||
      sudo sed -i 's/^IgnorePkg\s*=\s*/&aquamarine /' /etc/pacman.conf
  else
    sudo sed -i 's/^#IgnorePkg\s*=.*/IgnorePkg = aquamarine/' /etc/pacman.conf
  fi

  log "Installing the stock ALARM hyprland stack against ABI 13"
  sudo pacman -S --needed --noconfirm hyprtoolkit hyprland-guiutils hyprland
else
  # An existing hyprland 0.56.1-3 would block the aquamarine upgrade through
  # normal dependency checks; the packages built right after satisfy it again.
  if pacman -Q hyprland >/dev/null 2>&1; then
    log "Upgrading aquamarine to 0.15 (old hyprland stays until rebuilt)"
    sudo pacman -Sdd --needed --noconfirm aquamarine
  else
    sudo pacman -S --needed --noconfirm aquamarine
  fi
  pacman -Q aquamarine | grep -q ' 0.15' || fail "expected aquamarine 0.15.x installed"

  build_install hyprtoolkit 0.5.4-5
  build_install hyprland-guiutils 0.2.2-3
  build_install hyprland 0.56.2-2
fi

log "Sanity check"
pacman -Q aquamarine hyprtoolkit hyprland-guiutils hyprland
sudo pacman -Dk || fail "pacman -Dk reports broken dependencies"

log "Done. Built packages are in $build_root/out"
echo "Continue the Omarchy install with:  sudo omarchy-mac-setup --resume"
if [[ $mode == pin ]]; then
  echo "After the install finishes, re-add 'IgnorePkg = aquamarine' to /etc/pacman.conf"
  echo "(post-install overwrites it). Remove the pin once ALARM rebuilds hyprland."
fi
