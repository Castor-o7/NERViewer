Hello, you found my other visualizer! good job. This is the small, but loud accompaniment to the YggdrasilSystem that provides the 
system analytics aspects of the HUD. It has a big mode that monitors all system analytics in a little window that can be stowed in 
the overhead compartment. OR you can dock this bad boy into the YggdrasilSystem and find yourself living the neofuturist pixel fantasy
you always dreamed of! Aaaahahahaha!!! You can't see me right now but I'm laughing like an anime character from the 90s. Ook, bye now! 

## Install

### macOS

    tools/build_app.sh            # dist/NERViewer.app, yggstat inside
    tools/launch_agent.sh install # start at login (remove to undo)

Needs the Xcode command line tools (swiftc, codesign) and the Godot 4.7.2
export templates. Godot is `GODOT=` if set, else `godot` or `godot4` on
PATH, else `/Applications/Godot.app`. Re-running install restarts it.

### Linux

    tools/build_app.sh            # dist/linux/NERViewer.<arch> + NERViewer.pck + yggstat
    tools/launch_agent.sh install # start at login, and now (remove to undo)

Needs python3 (the stat helper, `helper/yggstat.py`, is a script: no
compiler) and the Godot 4.7.2 Linux export templates for the machine:
`NERViewer.x86_64` from `linux_release.x86_64`, or on an ARM box (a Pi 5,
Asahi) `NERViewer.arm64` from `linux_release.arm64`.
`NERVIEWER_ARCH=arm64` (or `x86_64`) cross-exports for the other into
`dist/linux-arm64/` (or `dist/linux-x86_64/`), leaving this machine's
`dist/linux/` alone. Godot is `GODOT=/path/to/godot` if set, else `godot`
or `godot4` on PATH, else the Flathub `org.godotengine.Godot`. The
templates go where that Godot reads them, in `4.7.2.stable/` (or
`4.7.2.stable.mono/` for a .NET editor): `~/.local/share/godot/export_templates/`,
the Flatpak's `~/.var/app/org.godotengine.Godot/data/godot/export_templates/`,
or `editor_data/export_templates/` beside a self-contained (`_sc_`) editor.

Login start is an XDG autostart entry,
`~/.config/autostart/edu.pdx.josh.nerviewer.desktop`, which KDE, GNOME,
XFCE, MATE, Cinnamon and LXQt all run. Where the systemd user manager can
reach the display (Plasma and GNOME import it at every login), install
also writes the user unit `edu.pdx.josh.nerviewer.service`; the entry
starts NERViewer through it, the cockpit's `systemctl --user start` finds
the same copy, and it stops with the desktop. Without systemd, or with a
manager that has no DISPLAY, there is no unit: the entry runs the export
itself and the cockpit launches it directly (on x86_64 only, for now:
the cockpit looks for `NERViewer.x86_64`, so an arm64 box needs the
unit until it learns the other name). i3, sway and other bare
window managers skip XDG autostart; add
`exec /path/to/NERViewer/tools/launch_agent.sh start` to their config.
Re-running install after a rebuild restarts it on the new build;
`tools/launch_agent.sh remove` deletes the entry and the unit.
The window runs through XWayland (the X11 display driver), which is what
lets it stay on top and sit exactly where the cockpit docks it.

For development, `helper/build.sh` puts the helper in `game/bin/` and
`godot --path game` runs the piece.

## Platform notes

Same glyphs, same meaning on both; each number is the kernel's own, so a
few read a shade differently.

- LOAD is the load average over the logical CPUs, as `uptime` reads it:
  the top line is every hardware thread busy (on Apple Silicon, every
  core). Linux also counts tasks waiting on disk, macOS does not.
- MEM's PRESSURE rests where the Mac's does, at the share of RAM the
  kernel could not hand out without paging (1 - MemAvailable/MemTotal);
  on Linux real stalls (PSI) push it higher. OF x GIB is installed RAM
  on both.
- The thermal frame follows macOS's own throttling verdict there. On
  Linux it is the CPU package temperature in tiers; an AMD Ryzen runs up
  to its Tjmax under ordinary load by design (90 C on a 5900X, 95 C on
  Zen 4 and later, about 100 C on a laptop), so SERIOUS starts at Tjmax
  and CRITICAL only past it.
- UPTIME is time awake on both: a night asleep does not count.
