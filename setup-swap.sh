#!/usr/bin/env bash
set -euo pipefail

echo ">> 1/5  zram-generator"
install -Dm644 /dev/stdin /etc/systemd/zram-generator.conf <<'EOF'
# zram: swap comprimido dentro de la RAM. 8GB sobre 16GB totales, zstd.
# Prioridad alta -> el kernel lo llena antes de tocar el swapfile en disco.
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF

echo ">> 2/5  sysctls"
install -Dm644 /dev/stdin /etc/sysctl.d/99-zram.conf <<'EOF'
# Con zram, swappear cuesta una descompresion en RAM, no un viaje al disco.
# El default de 60 hace que el kernel tire page cache antes de comprimir
# paginas anonimas, que es exactamente al reves de lo que queremos.
vm.swappiness = 180

# Paginas de 16K (Asahi): el default page-cluster=3 lee 2^3 paginas = 128KB
# por fallo de pagina. zram es random-access puro, ese readahead solo gasta.
vm.page-cluster = 0
EOF

echo ">> 3/5  swapfile btrfs (subvolumen propio, fuera de futuros snapshots de @)"
btrfs subvolume create /swap
btrfs filesystem mkswapfile --size 8G --uuid clear /swap/swapfile

echo ">> 4/5  fstab"
grep -q '/swap/swapfile' /etc/fstab \
  || echo '/swap/swapfile none swap defaults,pri=-2 0 0' >> /etc/fstab

echo ">> 5/5  activando"
sysctl --system >/dev/null
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service
swapon -a

echo
echo "=== RESULTADO ==="
swapon --show
echo
sysctl vm.swappiness vm.page-cluster
echo
free -h
