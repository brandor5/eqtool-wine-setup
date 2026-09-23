# EqTool on Wine

Ansible that sets up [EqTool / PigParse](https://github.com/smasherprog/EqTool)
— the EverQuest log parser — to run properly on Linux under plain Wine. No Steam
and no Proton.

It builds the Wine prefix, installs real .NET Framework 4.8 and the fonts WPF
needs, applies the registry settings that stop it rendering black windows,
and sets up a launcher, a GNOME desktop entry and two diagnostic scripts.
Everything lives under `$HOME` apart from installing `wine` and `winetricks`,
which needs root.

Prefer to do it by hand, or need to debug one step? **[MANUAL.md](MANUAL.md)**
is the same process written out, with a symptom → cause → fix table for the
things that commonly go wrong.

```
site.yml            the play
roles/eqtool/       prefix, launcher, desktop entry, tools
tools/              diagnostic scripts, usable standalone
MANUAL.md           the same setup by hand
```

## Tested on

Built and verified on exactly one configuration:

| | |
|---|---|
| Distribution | Fedora 44 (kernel 7.2.x) |
| Wine | wine-staging 11.0 |
| Desktop | GNOME on Wayland, with Wine using the **X11** driver via XWayland |
| GPU | NVIDIA, proprietary driver |

It should work anywhere with a recent Wine and winetricks, but nothing else has
been tried. Two things to look at if you are elsewhere:

- The package install step uses `ansible.builtin.package` with the names `wine`
  and `winetricks`, which are right for Fedora. Set `eqtool_packages`, or skip
  the step with `-e eqtool_install_packages=false` and install them yourself.
- `MANUAL.md` uses `dnf` directly.

Nothing else in the role is distribution-specific — it is all Wine
configuration and files under `$HOME`.

## Run it

```bash
ansible-playbook site.yml --ask-become-pass
```

Skip the package step if wine is managed elsewhere:

```bash
ansible-playbook site.yml -e eqtool_install_packages=false
```

Tags: `packages`, `prefix`, `desktop`, `tools`.

```bash
ansible-playbook site.yml --tags desktop
```

**The prefix step takes 10-20 minutes.** `winetricks dotnet48` runs a real
Microsoft installer with no progress output; it has not hung.

## What it does not do

The EqTool build itself. That comes from CI and is extracted to
`eqtool_install_dir` by hand — and `settings.json` lives in the same directory
as the exe, so nothing here may clean it. Extract new builds over the top.

## Why each piece exists

Nothing here is a default someone liked. Each was the outcome of a measurement:

| Setting | Reason |
|---|---|
| `dotnet48` | wine-mono's WPF leaks ~50 MB/min — 10 GB in under an hour, entirely native, with no managed object growth. Real .NET 4.8 measures flat. |
| `corefonts` | Real WPF calls `FailFast` from `TypefaceMap.MapUnresolvedCharacters` when it cannot resolve any font, killing the process at startup. |
| `DisableHWAcceleration` | WPF's hardware path uses Direct3D9, which fails pixel format negotiation under Wine and renders every window black. |
| `Graphics=x11` | Wine's Wayland driver has no system tray support. The icon becomes a detached window that ignores clicks, and the tray menu is the only way into the app. |
| `wintab32=d,winebus.sys=d` | These enumerate XInput devices and request button mappings. Under XWayland the device ids are recreated when the seat changes, so a stale id raises `XI_BadDevice` — an unhandled X protocol error, which Xlib turns into an immediate `exit()`. |
| `WINEDEBUG=fixme-all` | Silences the noisiest channel while keeping `err:`/`warn:`. Not `-all`: the 32-bit address space exhaustion and the font `FailFast` were both `err:` lines. |

Creating the prefix with `WINEDLLOVERRIDES="mscoree,mshtml="` suppresses the
wine-mono and wine-gecko prompts. Doing it the other way round — installing
wine-mono and removing it afterwards — is what left a Proton prefix with no
runtime at all and an application that would not start (`c0000135`).

## Idempotency

- Prefix creation keys off `system.reg`
- winetricks verbs are checked against `$WINEPREFIX/winetricks.log`
- Registry values are read before being written
- `.NET` is verified by file presence afterwards, because the dotnet48 installer
  reports failure for post-install steps Wine does not implement even when it
  succeeded — its exit status proves nothing either way

## Diagnostic scripts

Installed to `~/.local/bin` from `tools/`, and usable standalone since they
were written to be run by hand mid-incident:

- `watch-eqtool-memory.sh` — samples RSS and thread count, finds the pid itself
- `capture-eqtool-hang.sh` — per-thread states, wait channels, sockets and a
  gdb backtrace while the process is still wedged

## Verify afterwards

```bash
desktop-file-validate ~/.local/share/applications/eqtool.desktop
ls ~/.wine-eqtool/drive_c/windows/system32/mscoree.dll
WINEPREFIX=~/.wine-eqtool wine reg query 'HKCU\Software\Wine\Drivers' /v Graphics
```

If GNOME shows a second generic dash entry rather than highlighting the
launcher, `StartupWMClass` is wrong. Run `xprop WM_CLASS`, click an EqTool
window, and set `eqtool_wm_class` to match.
