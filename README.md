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
    tools/launch_agent.sh install # systemd user unit edu.pdx.josh.nerviewer.service
    systemctl --user start edu.pdx.josh.nerviewer.service

Needs python3 (the stat helper, `helper/yggstat.py`, is a script: no
compiler) and the Godot 4.7.2 Linux export templates
(`~/.local/share/godot/export_templates/4.7.2.stable/linux_release.x86_64`).
The unit is part of `graphical-session.target`, so it starts and stops
with the desktop; `tools/launch_agent.sh remove` disables and deletes it.
The window runs through XWayland (the X11 display driver), which is what
lets it stay on top and sit exactly where the cockpit docks it.

For development, `helper/build.sh` puts the helper in `game/bin/` and
`godot --path game` runs the piece.
