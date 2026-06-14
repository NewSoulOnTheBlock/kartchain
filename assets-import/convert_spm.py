"""
convert_spm.py
Headless Blender script — converts every kart and track .spm in
client/karts/ and client/tracks/ to .glb next to the source file.

Run from assets-import/ as:

  blender --background --python convert_spm.py -- <client_dir>

Loads the bundled io_scene_spm addon from blender-addons/ in this folder
(no Blender install/enable step required).
"""

import sys
import os
import glob
import importlib.util
import traceback

import bpy

# ─── locate args (everything after "--") ─────────────────────────────────
argv = sys.argv
try:
    sep = argv.index("--")
    user_args = argv[sep + 1:]
except ValueError:
    user_args = []

if len(user_args) < 1:
    print("usage: blender --background --python convert_spm.py -- <client_dir>")
    sys.exit(1)

CLIENT_DIR = os.path.abspath(user_args[0])
HERE       = os.path.dirname(os.path.abspath(__file__))
ADDON_DIR  = os.path.join(HERE, "blender-addons")

print(f"[convert] CLIENT_DIR = {CLIENT_DIR}")
print(f"[convert] ADDON_DIR  = {ADDON_DIR}")

# ─── load io_scene_spm by direct path import ─────────────────────────────
# Blender 5.1+ uses the new "extensions" system (bl_ext.user_default.*)
# which we can't easily enable from script. Instead, just add our bundled
# addon dir to sys.path and call its register() — that's enough to make
# the operator class visible via bpy.ops.import_scene.spm.
addon_path = os.path.join(ADDON_DIR, "io_scene_spm")
if not os.path.isdir(addon_path):
    print(f"[convert] FATAL: addon dir missing at {addon_path}")
    sys.exit(2)

sys.path.insert(0, ADDON_DIR)

try:
    import io_scene_spm
    io_scene_spm.register()
    if not hasattr(bpy.ops.screen, "spm_import"):
        print("[convert] FATAL: bpy.ops.screen.spm_import not registered after register()")
        sys.exit(3)
    print("[convert] io_scene_spm registered (op visible)")
except Exception as e:
    print(f"[convert] register failed: {e}")
    traceback.print_exc()
    sys.exit(4)


def _clear_scene():
    """Delete all objects from the current scene without resetting addons."""
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    # Also purge orphans so meshes/materials from previous imports don't leak
    bpy.ops.outliner.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)


def convert_one(spm_path: str, glb_path: str) -> bool:
    """Import a .spm into an empty scene, then export GLB."""
    try:
        _clear_scene()
        # The stk addon registers under screen.spm_import, NOT import_scene.spm
        bpy.ops.screen.spm_import(filepath=spm_path)
        bpy.ops.export_scene.gltf(
            filepath=glb_path,
            export_format="GLB",
            export_yup=True,
            export_apply=True,
            export_animations=True,
            export_image_format="AUTO",
            export_materials="EXPORT",
        )
        return True
    except Exception as e:
        print(f"  ✗ {os.path.basename(spm_path)}: {e}")
        return False


def main():
    # Skip wheel .spm files for now — they need to be parented under the
    # kart body, which we'd do at runtime in Godot anyway. Just convert
    # the main body .spm per kart.
    total = 0
    ok = 0

    # Karts: convert <name>.spm only (skip wheels/headlights/etc — too noisy)
    kart_dir = os.path.join(CLIENT_DIR, "karts")
    for kart in sorted(os.listdir(kart_dir)) if os.path.isdir(kart_dir) else []:
        sub = os.path.join(kart_dir, kart)
        if not os.path.isdir(sub):
            continue
        spm = os.path.join(sub, f"{kart}.spm")
        if not os.path.isfile(spm):
            # Some karts use a different naming; fall back to first .spm in the dir.
            candidates = [p for p in glob.glob(os.path.join(sub, "*.spm"))
                          if "wheel" not in os.path.basename(p).lower()
                          and "headlight" not in os.path.basename(p).lower()]
            if not candidates:
                continue
            spm = candidates[0]
        glb = os.path.splitext(spm)[0] + ".glb"
        total += 1
        if convert_one(spm, glb):
            ok += 1
            print(f"  ✓ kart  {kart}")

    # Tracks: convert ALL .spm files in each track dir (so scene assembly works)
    track_dir = os.path.join(CLIENT_DIR, "tracks")
    for track in sorted(os.listdir(track_dir)) if os.path.isdir(track_dir) else []:
        sub = os.path.join(track_dir, track)
        if not os.path.isdir(sub):
            continue
        spms = sorted(glob.glob(os.path.join(sub, "*.spm")))
        for spm in spms:
            glb = os.path.splitext(spm)[0] + ".glb"
            if os.path.isfile(glb):
                continue  # already converted
            total += 1
            if convert_one(spm, glb):
                ok += 1
        print(f"  ✓ track {track}  ({len(spms)} meshes)")

    # Library objects too — props can be reused
    lib_dir = os.path.join(CLIENT_DIR, "library")
    if os.path.isdir(lib_dir):
        for sub in sorted(os.listdir(lib_dir)):
            d = os.path.join(lib_dir, sub)
            if not os.path.isdir(d):
                continue
            for spm in sorted(glob.glob(os.path.join(d, "*.spm"))):
                glb = os.path.splitext(spm)[0] + ".glb"
                if os.path.isfile(glb):
                    continue
                total += 1
                if convert_one(spm, glb):
                    ok += 1

    print("")
    print(f"[convert] DONE — {ok}/{total} converted")


main()
