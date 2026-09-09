#!/bin/bash
#
# El parche `grep -qi` -> `grep -qai` no está upstream (verificado en el tag
# v4.0.2-2), así que cada upgrade del paquete `omarchy` sobreescribe
# /usr/share/omarchy y lo revierte. En vez de re-aplicarlo a mano, esto instala
# un hook de pacman que lo vuelve a poner después de cada transacción que toque
# el paquete.
#
# Fondo: /proc/device-tree/compatible es NUL-separado y sin newline final, así
# que GNU grep lo trata como binario y no reporta match. Toda la detección de
# Apple Silicon del árbol usa la forma sin -a y por lo tanto nunca dispara en
# el hardware al que apunta.
#
# Run: sudo bash omarchy-mac-fix-grep-hook.sh
set -euo pipefail
(( EUID == 0 )) || { echo "Run me with sudo." >&2; exit 1; }

log() { printf '\033[32m==>\033[0m %s\n' "$*"; }

install -Dm755 /dev/stdin /usr/local/bin/omarchy-mac-reapply-grep-fix <<'EOF'
#!/bin/bash
# Re-aplica grep -qi -> grep -qai en el árbol vivo de Omarchy.
# Idempotente: si ya está parcheado no cambia nada.
set -uo pipefail
root=${1:-/usr/share/omarchy}
[[ -d $root ]] || exit 0

mapfile -t files < <(grep -rl \
  -e 'grep -qi "apple" /proc/device-tree/compatible' \
  -e 'grep -qi apple /proc/device-tree/compatible' "$root" 2>/dev/null)

(( ${#files[@]} )) || exit 0

for f in "${files[@]}"; do
  sed -i \
    -e 's|grep -qi "apple" /proc/device-tree/compatible|grep -qai "apple" /proc/device-tree/compatible|g' \
    -e 's|grep -qi apple /proc/device-tree/compatible|grep -qai apple /proc/device-tree/compatible|g' "$f"
  echo "  reapplied: ${f#$root/}"
done
EOF
log "Instalado /usr/local/bin/omarchy-mac-reapply-grep-fix"

install -Dm644 /dev/stdin /etc/pacman.d/hooks/99-omarchy-mac-grep-fix.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy

[Action]
Description = Re-applying Apple Silicon detection fix (grep -a)...
When = PostTransaction
Exec = /usr/local/bin/omarchy-mac-reapply-grep-fix
EOF
log "Instalado /etc/pacman.d/hooks/99-omarchy-mac-grep-fix.hook"

log "Aplicando ahora sobre el árbol vivo"
/usr/local/bin/omarchy-mac-reapply-grep-fix

log "Verificación"
if grep -rq 'grep -qi.*apple.*/proc/device-tree/compatible' /usr/share/omarchy 2>/dev/null; then
  echo "  quedan sitios sin parchear:" >&2
  grep -rn 'grep -qi.*apple.*/proc/device-tree/compatible' /usr/share/omarchy 2>/dev/null >&2
  exit 1
fi
echo "  ok: no queda ningún 'grep -qi' contra device-tree/compatible"
