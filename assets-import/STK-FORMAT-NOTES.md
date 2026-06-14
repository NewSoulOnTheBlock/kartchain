# STK file-format notes

The SuperTuxKart asset repo uses a few uncommon formats. Here's the lay of
the land before you try to convert anything.

## `.b3d` — Blitz3D mesh

Used by **older karts** in the STK repo. Binary chunked format.

**Convert in Blender:**
- Install the community **"Import B3D"** addon
  (https://github.com/joric/io_scene_b3d).
- Enable in Preferences → Add-ons.
- Then `convert-models.ps1` will auto-import it.

If `bpy.ops.import_scene.b3d` is missing, the addon isn't enabled.

## `.x` — DirectX Mesh (legacy)

Some older STK tracks ship with `.x` files. Blender has a built-in importer
(Add-ons → "Import-Export: DirectX Model Format (.x)").

## `.spm` — SuperTuxKart Mesh

STK's **custom** binary format introduced in STK 0.9.x. Replaces `.b3d` for
new content.

**Convert in Blender:**
- Install **blender-stk-tools**
  (https://github.com/supertuxkart/stk-blender)
- This adds `bpy.ops.import_mesh.spm`.

If you only need the textures + a rough mesh, you can also extract `.png`
files from the same folder and re-rig manually.

## Material/texture handling

After conversion, glTF will embed textures by default. If you'd rather
ship them externally:
- Pass `export_format="GLTF_SEPARATE"` instead of `GLB` in
  `convert-models.ps1`.

## Animations

`export_animations=True` exports any keyframes baked on the rig. If the
imported model has no rig, Godot will treat it as a static mesh — fine for
karts (we drive them with VehicleBody3D).

## Audio

`stk-assets/music/*.ogg` files are already Vorbis OGG. Godot imports them
natively. **Check each track's `*.music` metadata file for its license** —
some songs are CC-BY (not SA) and a few are public domain.

## What we can't easily port

- **.particle** XML — STK's particle system. We'll rewrite in Godot's
  CPUParticles3D / GPUParticles3D.
- **.kart** stats files — easy to parse but format-specific. We'll
  store kart stats as JSON next to the glTF.
- **Track AI hints** — STK uses lua AI driver lines that don't translate.
  We'll skip bot drivers in MVP.
