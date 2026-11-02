# SCons custom profile for Wordbox 2: a 2D-only, release-only engine with just the modules the game uses
# (GDScript, FreeType + the fallback text server for the Baloo 2 font, MP3 for the sound effects).
# Use: scons platform=<platform> arch=<arch> target=template_release profile=wordbox/profile.py
# Rebuild the game's tests if a module is added here: anything switched off simply is not in the engine.
optimize = "size"
lto = "full"
production = "yes"
debug_symbols = "no"
deprecated = "no"
disable_3d = "yes"
vulkan = "no"
opengl3 = "yes"
openxr = "no"
accesskit = "no"
minizip = "no"
modules_enabled_by_default = "no"
module_gdscript_enabled = "yes"
module_freetype_enabled = "yes"
module_text_server_fb_enabled = "yes"
module_mp3_enabled = "yes"
module_webp_enabled = "yes"
