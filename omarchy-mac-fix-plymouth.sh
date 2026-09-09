#!/bin/bash
# Apply the one-line fix from omarchy-mac PR #334 (issue #344): let
# omarchy-plymouth-set --refresh-default run as root during system setup.
# Patches the installed copy (what runs) and the source checkout (what the
# resume rebuilds the package from). Run as your user, not root.
set -euo pipefail
(( EUID != 0 )) || { echo "run as your user, not root" >&2; exit 1; }

pattern='s/^if (( EUID == 0 )); then$/if (( EUID == 0 )) \&\& [[ $mode != "refresh-plymouth" ]]; then/'
installed=/usr/share/omarchy/bin/omarchy-plymouth-set
checkout=$HOME/.local/share/omarchy/bin/omarchy-plymouth-set

[[ -f $checkout ]] && sed -i "$pattern" "$checkout"
sudo sed -i "$pattern" "$installed"

for f in "$installed" "$checkout"; do
  [[ -f $f ]] || continue
  grep -q 'EUID == 0 )) && \[\[ \$mode != "refresh-plymouth" \]\]' "$f" ||
    { echo "patch did not apply to $f" >&2; exit 1; }
  echo "patched: $f"
done
echo "Now run:  sudo omarchy-mac-setup --resume"
