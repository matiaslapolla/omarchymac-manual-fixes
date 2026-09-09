# omarchymac-manual-fixes

Manual fixes I had to apply to get [omarchy-mac](https://github.com/omarchy-mac/omarchy-mac)
installed and usable on a MacBook Air M1.

Nothing here is a fork or a patch set to be merged as-is. These are the repairs
that made a stock install boot, finish, and stop breaking on resume, written up
so they can be re-applied on a rebuild and so the ones that belong upstream can
be sent there.

## Hardware

| | |
|---|---|
| Machine | MacBook Air M1, `apple,j313` / `apple,t8103` |
| OS | Arch Linux ARM (Asahi), aarch64 |
| Distro layer | omarchy-mac, `quattro` branch, 4.0.x |
| Wi-Fi / BT | Broadcom BCM4378 (`brcmfmac` / `hci_bcm4377`) |
| Panel | 2560x1600, 16:10, no camera notch |

## The scripts

| Script | What it fixes | Status |
|---|---|---|
| [`omarchy-mac-fix-aquamarine.sh`](omarchy-mac-fix-aquamarine.sh) | Aquamarine ABI mismatch that blocks the install | Superseded upstream |
| [`omarchy-mac-fix-plymouth.sh`](omarchy-mac-fix-plymouth.sh) | `omarchy-plymouth-set --refresh-default` refusing to run as root during setup | Merged upstream |
| [`omarchy-mac-fixes.sh`](omarchy-mac-fixes.sh) | Widevine, Vulkan, Apple Silicon detection, Wi-Fi resume, Bluetooth resume | Partly merged upstream |
| [`omarchy-mac-fix-grep-hook.sh`](omarchy-mac-fix-grep-hook.sh) | Keeps the Apple Silicon detection fix applied across package upgrades | Still needed |
| [`omarchy-mac-fix-als-keyboard-unit.sh`](omarchy-mac-fix-als-keyboard-unit.sh) | Keyboard backlight from the ambient light sensor, whose unit file the package never installs | Still needed |
| [`setup-swap.sh`](setup-swap.sh) | zram + btrfs swapfile tuned for 16K pages | Personal preference |

---

### `omarchy-mac-fix-aquamarine.sh`

**Superseded upstream.** Kept for the record.

ALARM `[extra]` shipped `aquamarine 0.15.0-2` (`libaquamarine.so=14`) while its
`hyprland 0.56.1-3` and `hyprtoolkit 0.5.4-5` still linked
`libaquamarine.so=13`, so the install died in dependency resolution
([omarchy-mac#341](https://github.com/omarchy-mac/omarchy-mac/issues/341)).
The old aquamarine build is not archived anywhere, so something had to be built
locally. The script offers two ways out:

- `--rebuild` (default): build `hyprtoolkit`, `hyprland-guiutils` and `hyprland`
  against aquamarine 0.15 from the upstream Arch PKGBUILDs. ~30-45 min on an
  M1 Air, and no pacman pinning afterwards.
- `--pin`: build `aquamarine 0.14.0-2` and hold it with `IgnorePkg`. ~3 min, but
  the pin has to be re-added after the install overwrites `/etc/pacman.conf`.

Upstream's answer is
[the ARM package sources policy](https://github.com/omarchy-mac/omarchy-mac/pull/354):
an `[omarchy]` repository with `Usage = Sync` from which `hyprland`,
`hyprtoolkit` and `hyprland-guiutils` are selected explicitly, so the Hyprland
stack no longer has to match whatever ALARM last rebuilt. Machines installed
before that policy landed can reach it with `fix-arm-packages.sh` from the
omarchy-mac repository root.

### `omarchy-mac-fix-plymouth.sh`

**Merged upstream** as
[omarchy-mac#334](https://github.com/omarchy-mac/omarchy-mac/pull/334)
(issue #344). The packaged fix ships from 4.0.2-2 on; the script is only useful
on an install older than that.

`omarchy-plymouth-set` refuses to run under sudo, which is correct for every
mode that opens a caller-selected file — but system setup has to publish the
packaged Plymouth default as root, and that mode takes no caller input. One
line: exempt `refresh-plymouth` from the check.

### `omarchy-mac-fixes.sh`

Four repairs, run as `sudo bash omarchy-mac-fixes.sh`.

**1. Widevine + `vulkan-asahi`.** Both are in the repositories and install fine.
Neither had ever been installed, because both are gated behind the detection bug
in step 2. Unblocks DRM streaming (Netflix, Spotify web, Disney+, Prime Video)
and GPU acceleration for anything using Vulkan rather than plain GL
([#220](https://github.com/omarchy-mac/omarchy-mac/issues/220)).

**2. `grep -qi` → `grep -qai` — the root cause.** `/proc/device-tree/compatible`
is NUL-separated with no trailing newline, so GNU grep treats it as binary and
reports no match:

```console
$ grep -qi apple /proc/device-tree/compatible; echo $?
1
$ grep -qai apple /proc/device-tree/compatible; echo $?
0
$ tr '\0' '\n' < /proc/device-tree/compatible
apple,j313
apple,t8103
apple,arm-platform
```

Every Apple Silicon detection in the tree uses the plain form, so each one
silently no-ops on exactly the hardware it targets: the Widevine and 1Password
migrations, the `vulkan-asahi` selection, the Apple HID early-load, and
`Bar.qml`'s notch handling. Not yet fixed upstream as of `v4.0.2-2` — see the
hook below.

**3. Wi-Fi resume recovery.** BCM4378/BCM4387 firmware wedges across s2idle:
scans fail with `-52` and every association is rejected with `status_code=16`,
which NetworkManager surfaces as a wrong password. Only a driver reload clears
it ([#197](https://github.com/omarchy-mac/omarchy-mac/issues/197),
[AsahiLinux/linux#439](https://github.com/AsahiLinux/linux/issues/439)).

Deliberately a service ordered `After=suspend.target` rather than a
system-sleep hook: a sleep hook runs synchronously and would delay every single
resume. Detection reads the journal from a cursor taken at start rather than a
`--since` window, because on some Apple Silicon kernels the clock steps
backwards across resume and would leave a time window empty.

**Merged upstream** (a port of PR #255) and shipped as
`/usr/bin/omarchy-wifi-resume-fix` from 4.0.2-2. The packaged version is a
superset of this one. Note that the migration that installs it skips machines
where `omarchy-wifi-resume-fix.service` is already enabled, so a machine that
ran this script keeps the local copy in `/usr/local/bin` and never picks up
later fixes — see "Handing the Wi-Fi fix back to the package" below.

**4. Bluetooth wedge recovery.** BCM4378/4387 firmware hangs after an rfkill
block or a clamshell resume: rfkill reads unblocked, but the adapter stays
`Powered: no` and BlueZ returns `org.bluez.Error.Failed`. Only a PCI
unbind/bind of `hci_bcm4377` resets it — `omarchy restart bluetooth` does not,
it only touches rfkill
([#302](https://github.com/omarchy-mac/omarchy-mac/issues/302),
[#338](https://github.com/omarchy-mac/omarchy-mac/issues/338)).

`omarchy-bluetooth-rebind` run bare forces a rebind; `--if-wedged` acts only
when the adapter is actually stuck, and leaves a deliberately soft-blocked
radio alone. **Not fixed upstream.**

### `omarchy-mac-fix-grep-hook.sh`

**Still needed.** Run as `sudo bash omarchy-mac-fix-grep-hook.sh`.

The `grep -a` fix from step 2 above is not upstream, and `/usr/share/omarchy` is
owned by the `omarchy` package — so every upgrade reverts it. This installs a
pacman `PostTransaction` hook on the `omarchy` package that re-applies the
patch automatically, plus the idempotent script that does the work.

It also covers `shell/plugins/bar/Bar.qml`, which the original script missed
because it only walked `*.sh` and `omarchy-*`. That one is cosmetic on a
notch-less M1 Air (the derived notch height is 0 on a 16:10 panel) but matters
on M2 Airs and the Pros.

### `omarchy-mac-fix-als-keyboard-unit.sh`

**Still needed** as of `omarchy` / `omarchy-settings` 4.0.2-2. Run as your user.

4.0.2-2 added a service that drives the keyboard backlight from the ambient
light sensor — dark room, keys lit — and on an M1 Air the hardware is all there
(`aop-sensors-als` in iio, `kbd_backlight` in leds, and `brightnessctl` can
write it through logind as the session user). It just never starts:

```console
$ systemctl --user is-enabled omarchy-brightness-keyboard-auto
not-found
```

`omarchy` ships the binary and `omarchy-settings` ships the unit *source* at
`/usr/share/omarchy/default/systemd/user/`, but `omarchy-settings` never
installs that one into `/usr/lib/systemd/user/` the way it installs every other
user unit it owns. Migration `1788139121` then hides the failure instead of
reporting it: `systemctl --user enable` fails with no such unit, and the
fallback writes the symlink enable would have written — pointing at the
`/usr/lib` path that does not exist. A dangling link in
`graphical-session.target.wants`, and a service that silently never runs.

The script links the packaged source into `/etc/systemd/user` (in the user
manager's search path, and never touched by pacman), clears the dangling
symlink, and enables the unit. Linking rather than copying keeps it tracking
the packaged file across upgrades.

### `setup-swap.sh`

Not a fix — a preference, kept here so a rebuild reproduces it. zram sized at
half of RAM with zstd at high priority, a low-priority 8G btrfs swapfile on its
own subvolume (outside future snapshots of `@`), and two sysctls:

- `vm.swappiness = 180`, because with zram swapping costs a decompression in
  RAM rather than a trip to disk, and the default of 60 drops page cache before
  compressing anonymous pages — backwards for this setup.
- `vm.page-cluster = 0`, because Asahi uses 16K pages: the default
  `page-cluster=3` reads 8 pages (128K) per fault, and zram is pure random
  access, so that readahead is pure waste.

## Running these on a fresh install

Only the aquamarine fix runs mid-install; the rest go on a booted system.

```bash
# During the install, when dependency resolution fails on aquamarine:
bash omarchy-mac-fix-aquamarine.sh          # as your user, not root
sudo omarchy-mac-setup --resume

# Once booted (skip plymouth on 4.0.2-2 or newer, it is packaged):
bash omarchy-mac-fix-plymouth.sh
sudo bash omarchy-mac-fixes.sh
sudo bash omarchy-mac-fix-grep-hook.sh
bash omarchy-mac-fix-als-keyboard-unit.sh   # as your user
sudo bash setup-swap.sh
```

On a current omarchy-mac the aquamarine and plymouth scripts should both be
unnecessary.

## Handing the Wi-Fi fix back to the package

On a machine that ran `omarchy-mac-fixes.sh` before upgrading to 4.0.2-2 or
newer, the local Wi-Fi recovery shadows the packaged one. To let the package
own it:

```bash
sudo systemctl disable --now omarchy-wifi-resume-fix.service
sudo rm /etc/systemd/system/omarchy-wifi-resume-fix.service /usr/local/bin/omarchy-wifi-resume-fix
sudo systemctl daemon-reload
sudo bash /usr/share/omarchy/install/hardware/apple/fix-wifi-resume.sh
```

The Bluetooth recovery has no packaged equivalent and should be left alone.

## Still worth sending upstream

- The `grep -a` detection fix, which repairs several Apple Silicon features that
  currently no-op on every Mac.
- The Bluetooth rebind recovery for #302 / #338.
- The missing `omarchy-brightness-keyboard-auto.service` in `omarchy-settings`,
  which is a one-line packaging fix. Migration `1788139121` writing a symlink to
  a path it never checked exists is worth reporting alongside it: had it failed
  loudly, the missing unit would have surfaced during the update instead of
  looking like working hardware doing nothing.
