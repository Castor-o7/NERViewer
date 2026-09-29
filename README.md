Hello, you found my other visualizer! good job. This is the small, but loud accompaniment to the YggdrasilSystem that provides the 
system analytics aspects of the HUD. It has a big mode that monitors all system analytics in a little window that can be stowed in 
the overhead compartment. OR you can dock this bad boy into the YggdrasilSystem and find yourself living the neofuturist pixel fantasy
you always dreamed of! Aaaahahahaha!!! You can't see me right now but I'm laughing like an anime character from the 90s. Ook, bye now! 

## Install

### macOS

    tools/build_app.sh            # dist/NERViewer.app, yggstat inside
    tools/launch_agent.sh install # start at login (remove to undo)

Needs the Xcode command line tools (swiftc, codesign) and the Godot 4.7.2
export templates.

### Linux (KDE Plasma)

    tools/build_app.sh            # dist/linux/NERViewer.x86_64 + NERViewer.pck + yggstat
    tools/launch_agent.sh install # systemd user unit edu.pdx.josh.nerviewer.service, started now

Needs python3 (the stat helper, `helper/yggstat.py`, is a script: no
compiler) and the Godot 4.7.2 Linux export templates
(`~/.local/share/godot/export_templates/4.7.2.stable/linux_release.x86_64`).
The unit is part of `graphical-session.target`, so it starts and stops
with the desktop; `tools/launch_agent.sh remove` disables and deletes it.
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
