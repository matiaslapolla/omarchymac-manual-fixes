#!/bin/bash
#
# Qt 6.12 (que ALARM sacó antes que Arch x86) agrega a QtQuick un tipo builtin
# `Color` que tapa al singleton `qs.Commons.Color` de omarchy-shell. Cada
# `Color.bar`, `Color.accent`, etc. resuelve a undefined y la barra, el
# launcher, el lock y los temas se ven negros. No hay crash ni coredump: solo
# cientos de `TypeError: Cannot read property ... of undefined` en `qs log`.
# Sin arreglar upstream en omarchy 4.0.4-2.
#
# El fix renombra el singleton a `ShellColor`. Como /usr/share/omarchy es del
# paquete `omarchy`, cada upgrade lo revierte, así que esto instala un hook de
# pacman que lo vuelve a aplicar. Se apaga solo: si upstream deja de declarar
# `singleton Color` en el qmldir, el reaplicador no toca nada.
#
# Run: sudo bash omarchy-mac-fix-shellcolor-hook.sh
set -euo pipefail
(( EUID == 0 )) || { echo "Run me with sudo." >&2; exit 1; }

log() { printf '\033[32m==>\033[0m %s\n' "$*"; }

install -Dm755 /dev/stdin /usr/local/bin/omarchy-mac-reapply-shellcolor-fix <<'EOF'
#!/bin/bash
# Renombra el singleton Color -> ShellColor en el árbol vivo de omarchy-shell.
# Idempotente: si ya está parcheado, o upstream cambió el qmldir, no hace nada.
set -uo pipefail
shell=${1:-/usr/share/omarchy/shell}
qmldir=$shell/Commons/qmldir
grep -q '^singleton Color 1.0 Color.qml$' "$qmldir" 2>/dev/null || exit 0

sed -i 's/^singleton Color 1.0 Color.qml$/singleton ShellColor 1.0 Color.qml/' "$qmldir"
find "$shell" -type f \( -name '*.qml' -o -name '*.js' \) \
  -exec sed -i -E 's/\bColor\./ShellColor./g' {} +
echo "  reapplied: Color -> ShellColor (restart the shell: omarchy-restart-shell)"
EOF
log "Instalado /usr/local/bin/omarchy-mac-reapply-shellcolor-fix"

install -Dm644 /dev/stdin /etc/pacman.d/hooks/99-omarchy-mac-shellcolor-fix.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy

[Action]
Description = Re-applying omarchy-shell Qt 6.12 Color fix (ShellColor)...
When = PostTransaction
Exec = /usr/local/bin/omarchy-mac-reapply-shellcolor-fix
EOF
log "Instalado /etc/pacman.d/hooks/99-omarchy-mac-shellcolor-fix.hook"

log "Aplicando ahora sobre el árbol vivo"
/usr/local/bin/omarchy-mac-reapply-shellcolor-fix

log "Verificación"
if grep -rqE '\bColor\.' /usr/share/omarchy/shell --include='*.qml' --include='*.js'; then
  echo "  quedan referencias a Color. sin renombrar:" >&2
  grep -rnE '\bColor\.' /usr/share/omarchy/shell --include='*.qml' --include='*.js' >&2
  exit 1
fi
echo "  ok: omarchy-shell usa ShellColor"
