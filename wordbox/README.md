# Wordbox 2 slim templates

Godot 4.7.2-stable with a build profile for the game (`profile.py`): release templates only, no 3D, no Vulkan,
no XR, no multiplayer, only the modules the game uses. Branch `wordbox/slim-2d-templates` of this fork, cut from
the `4.7.2-stable` tag with no engine source changes, so the editor and the game's tests stay on stock 4.7.2.

Build: `wordbox/build.sh linux|android|windows`. Point the game's export presets at the result
(`custom_template/release`), then check the game still runs: every menu, the puzzles, sound, the font.
