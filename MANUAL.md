# Manual setup

Setting up EqTool under plain Wine with real .NET Framework 4.8, by hand. No
Steam, no Proton.

[The Ansible role](README.md) does all of this in one command. This file is the
same steps written out, for when you would rather not run Ansible, or when
something has gone wrong and you need to do one piece at a time and watch it.

The application itself is not installed by either path — see
[Install the build](#5-install-the-build).

---

## Prerequisites

Written and tested on **Fedora 44** with **wine-staging 11.0**, GNOME on
Wayland (Wine itself using the X11 driver through XWayland), and an NVIDIA GPU
on the proprietary driver. Nothing else has been tried. Only this step is
distribution-specific — everything after it is Wine configuration and files
under `$HOME`.

```bash
sudo dnf install wine winetricks          # Fedora
# sudo apt install wine winetricks        # Debian/Ubuntu
# sudo pacman -S wine winetricks          # Arch
```

`wine --version` should report 9.x or newer.

---

## 1. Create the Wine prefix

A prefix dedicated to EqTool, so nothing here disturbs anything else you run
under Wine.

```bash
export WINEPREFIX=~/.wine-eqtool
export WINEARCH=win64

WINEDLLOVERRIDES="mscoree,mshtml=" wineboot --init
wineserver --wait
```

**The `WINEDLLOVERRIDES` part is the important bit.** It suppresses the wine-mono
and wine-gecko installer prompts, so wine-mono is never installed in the first
place.

Do not instead let wine-mono install and remove it afterwards. That ordering
leaves a window where neither runtime exists, and if the .NET install then fails
you are left with a prefix that cannot run any managed executable at all —
`err:module:fixup_imports_ilonly mscoree.dll not found` and status `c0000135`.

If you used `winecfg` and accepted the Mono prompt by accident:

```bash
winetricks remove_mono
```

## 2. Install .NET Framework 4.8

```bash
winetricks -q dotnet48
```

Ten to twenty minutes, several installer windows, and some alarming errors you
should click through. **Its exit status means nothing either way** — it reports
failure for post-install steps Wine does not implement (ngen, performance
counters, service registration) even when every assembly landed correctly. Check
the files instead, in step 4.

Why bother: wine-mono's WPF leaks roughly 50 MB/min — 10 GB in under an hour,
allocated natively, with no managed object growth at all. Real .NET 4.8 measures
flat over the same period.

## 3. Install fonts

```bash
winetricks -q corefonts
```

Not optional. Real WPF calls `Environment.FailFast` out of
`TypefaceMap.MapUnresolvedCharacters` when it cannot resolve *any* font, which
kills the process during startup with no catchable exception. A fresh prefix has
almost no fonts.

## 4. Registry settings

```bash
wine reg add 'HKCU\Software\Microsoft\Avalon.Graphics' \
  /v DisableHWAcceleration /t REG_DWORD /d 1 /f

wine reg add 'HKCU\Software\Wine\Drivers' \
  /v Graphics /t REG_SZ /d x11 /f
```

`DisableHWAcceleration` forces WPF's software renderer. Its hardware path goes
through Direct3D9, which fails pixel format negotiation under Wine
(`err:d3d:context_choose_pixel_format`) and renders every window black.

`Graphics=x11` rather than wayland. Wine's Wayland driver has no system tray
support: the icon becomes a detached window that ignores clicks, and the tray
menu is the only way into this application.

**Verify both writes.** Wine says nothing when a value is missing or misspelled,
and a typo here is invisible until the app misbehaves:

```bash
wine reg query 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration
wine reg query 'HKCU\Software\Wine\Drivers' /v Graphics
```

Then confirm the runtime actually installed:

```bash
ls $WINEPREFIX/drive_c/windows/system32/mscoree.dll
ls $WINEPREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll
ls $WINEPREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/mscorlib.dll
ls $WINEPREFIX/drive_c/windows/Fonts/arial.ttf
```

All four must exist. If `mscoree.dll` is missing, nothing will launch.

## 5. Install the build

Two options.

**Stock upstream** — grab the Linux zip from
[smasherprog/EqTool releases](https://github.com/smasherprog/EqTool/releases)
and unzip it. This works once the prefix is set up, with one visible flaw: WPF's
themed progress bar renders as disconnected blocks under Wine rather than a
smooth fill, in both the Triggers window and the overlay timer bars.

**The Linux fork** —
[brandor5/EqTool, branch `fix/proton-overlay-stability`](https://github.com/brandor5/EqTool/tree/fix/proton-overlay-stability)
— fixes the progress bars and carries a few other changes, documented in
[FORK.md](https://github.com/brandor5/EqTool/blob/fix/proton-overlay-stability/FORK.md).
It has no releases; builds come from CI:

```bash
gh run list --repo brandor5/EqTool --limit 1
gh run download <run-id> --repo brandor5/EqTool \
  -n EQTool-Linux-build -D /tmp/eqtool-new

mkdir -p ~/storage/Games/EQTool
cp -r /tmp/eqtool-new/* ~/storage/Games/EQTool/
```

Set `eqtool_install_dir` (Ansible) or `EQTOOL_DIR` (the launcher) if you put it
somewhere other than `~/storage/Games/EQTool`.

**Extract over the top; never delete the directory first.** `settings.json`,
`Errors.txt` and `maps/` live beside the executable, so `rm -rf` takes your
configuration with it. The artifact contains no config files, so nothing you have
set can be overwritten.

## 6. Launcher script

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/eqtool <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

EQTOOL_DIR="${EQTOOL_DIR:-$HOME/storage/Games/EQTool}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-eqtool}"

# wintab32 and winebus enumerate XInput devices and ask them for button
# mappings. Under XWayland those X device ids are recreated whenever the Wayland
# seat changes, so an id can go stale in between; the resulting XI_BadDevice is
# an unhandled X protocol error, which Xlib turns into an immediate exit.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-wintab32=d,winebus.sys=d}"

# Drops the noisiest channel but keeps err: and warn:. Not -all - the crash that
# revealed 32-bit address space exhaustion and the font FailFast were both err:.
export WINEDEBUG="${WINEDEBUG:-fixme-all}"

exec wine "$EQTOOL_DIR/EQTool.exe" "$@"
EOF
chmod +x ~/.local/bin/eqtool
```

Add `~/.local/bin` to `PATH` if it is not already there.

## 7. Desktop entry

The icon ships with this repo:

```bash
mkdir -p ~/.local/share/icons/hicolor/256x256/apps
cp roles/eqtool/files/eqtool.png ~/.local/share/icons/hicolor/256x256/apps/
```

It came out of EqTool's own `EQTool/Images/logo.ico`, whose first directory
entry is already a 256×256 PNG — so it was extracted as a byte range rather
than converted:

```bash
dd if=/path/to/EqTool/EQTool/Images/logo.ico of=eqtool.png \
   bs=1 skip=150 count=13051 status=none
```

```bash
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/eqtool.desktop <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=EqTool
GenericName=EverQuest Log Parser
Comment=Parses the EverQuest log for triggers, timers, maps and DPS
Exec=eqtool
Icon=eqtool
Terminal=false
Categories=Game;Utility;
Keywords=everquest;eq;p99;pigparse;parser;triggers;timers;
StartupNotify=false
StartupWMClass=eqtool.exe
EOF

update-desktop-database ~/.local/share/applications 2>/dev/null || true
gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor 2>/dev/null || true
```

If GNOME shows a second generic entry in the dash instead of highlighting your
launcher, `StartupWMClass` is wrong. Run `xprop WM_CLASS`, click an EqTool
window, and use what it reports.

## 8. Diagnostic scripts (optional)

```bash
cp tools/watch-eqtool-memory.sh ~/.local/bin/
cp tools/capture-eqtool-hang.sh ~/.local/bin/
chmod +x ~/.local/bin/watch-eqtool-memory.sh ~/.local/bin/capture-eqtool-hang.sh
```

Both find the right process themselves. That is less trivial than it sounds —
several processes carry `EQTool.exe` in their command line, including Steam's
launcher shim, which sits at a steady three threads and would otherwise look
like a perfectly flat memory graph.

### watch-eqtool-memory.sh

Samples RSS, virtual size and thread count every 30 seconds. Start EqTool, then:

```bash
watch-eqtool-memory.sh            # 30s interval, finds the pid itself
watch-eqtool-memory.sh 10         # every 10 seconds
watch-eqtool-memory.sh 30 12345   # pin to a specific pid
```

```
TIME      THREADS      RSS_MB    VMSIZE_MB     DELTA_MB
01:19:41  18              409         3147           +0
01:20:11  17              409         3147           +0
```

Ctrl-C prints a summary with a growth rate and a verdict, and leaves a CSV in
`$HOME` (override with `EQTOOL_OUT_DIR`). Flat, or drifting slightly down, is
correct. Sustained growth of
tens of MB per minute means something is wrong — most often the prefix has
fallen back to wine-mono. For scale, wine-mono's WPF leaked about 50 MB/min, so
a bad setup is obvious within two or three minutes.

Thread count matters too: around 20 is normal, and a climb into the hundreds
means work is queued and never completing.

### capture-eqtool-hang.sh

For when the application is still running but unresponsive. Run it **before**
killing the process — everything useful disappears with it:

```bash
capture-eqtool-hang.sh            # finds the pid itself
capture-eqtool-hang.sh 12345      # or pin one
```

Writes a timestamped directory under `$HOME` — override with `EQTOOL_OUT_DIR`
— containing:

| File | Contents |
|---|---|
| `summary.txt` | pid, thread count, process state |
| `threads.txt` | per-thread state and kernel wait channel |
| `sockets.txt` | open connections — a pile of stalled HTTPS is diagnostic |
| `gdb-backtrace.txt` | native stacks, if gdb is installed |
| `processes.txt` | every EqTool/wine process, to sanity-check the pid |
| `dmesg.txt` | kernel log, for GPU resets and OOM kills |

`threads.txt` and `sockets.txt` do most of the work. Hundreds of threads parked
in `futex_wait` with no network sockets open means the process is deadlocked on
a lock rather than waiting on a server. The gdb backtrace is the least useful
part under Wine — without symbols it is mostly `?? ()` — so do not be put off if
gdb is missing.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Won't start, `c0000135`, `mscoree.dll not found` | No .NET runtime in the prefix | Step 2, then verify with step 4 |
| Dies instantly at startup, `FailFast` in `TypefaceMap` | No usable fonts | Step 3 |
| Windows are black | WPF hardware rendering via D3D9 | `DisableHWAcceleration`, step 4 |
| Crashes with `XI_BadDevice` / `XInputExtension` | Stale X input device id | `WINEDLLOVERRIDES` in the launcher, step 6 |
| Tray icon is a floating window that ignores clicks | Wine's Wayland driver has no tray | `Graphics=x11`, step 4 |
| Memory climbs ~50 MB/min | Running on wine-mono, not real .NET | Step 2 |
| Progress bars render as disconnected blocks | Stock WPF template under Wine | Use the fork build, which replaces it |

**Check which build is running** — the tray menu's version entry shows the commit
it was built from, e.g. `Linux1.0.0.0 (1718976d)`. A locally built copy shows
`(local)`.

**Confirm you are on real .NET and not wine-mono:**

```bash
WINEPREFIX=~/.wine-eqtool WINEDEBUG=+loaddll wine ~/storage/Games/EQTool/EQTool.exe 2>&1 \
  | grep -icE "wine-mono"     # want 0
```

**Watch memory over a session:**

```bash
watch-eqtool-memory.sh
```

Flat, or drifting slightly down, is correct. Sustained growth of tens of MB per
minute means something is wrong — most likely the prefix fell back to wine-mono.
