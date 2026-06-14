# Kartchain asset import

Scripts and notes for legally pulling kart/track/music assets out of the
[SuperTuxKart project](https://github.com/supertuxkart/stk-assets) and
converting them to glTF 2.0 for our Godot 4 client.

> **License reminder.** STK assets are **CC-BY-SA 4.0** unless noted otherwise
> in their individual `.license` files. You must (a) attribute the original
> authors and (b) release your derivatives under the same license. Read
> [`../docs/LICENSING.md`](../docs/LICENSING.md) before shipping anything.

## Scripts

| Script | Purpose |
|---|---|
| `fetch-stk-assets.ps1` | Sparse-clone karts + tracks from supertuxkart/stk-assets |
| `convert-models.ps1`   | Convert `.b3d`/`.x`/`.spm` models to `.glb` via Blender CLI |
| `gen-attribution.ps1`  | Walk imported asset folders and produce ATTRIBUTION.md |

All scripts are PowerShell so they run on the user's Windows dev box. They
should also work in pwsh on macOS/Linux with minor tweaks.

## Manual steps

1. **Install Blender 4.x** — used as the model converter CLI.
   https://www.blender.org/download/
2. Run `fetch-stk-assets.ps1` from this directory. It clones into
   `./stk-assets-src/` (gitignored).
3. Pick the karts and tracks you want and copy them under
   `./curated/karts/<name>/` and `./curated/tracks/<name>/`.
4. Run `convert-models.ps1` — produces `./out/karts/*.glb` and
   `./out/tracks/*.glb`.
5. Copy `./out/karts/*` into `../client/karts/` and `./out/tracks/*` into
   `../client/tracks/` so Godot can import them.
6. Run `gen-attribution.ps1` to regenerate `ATTRIBUTION.md` based on
   the licenses of imported assets. Ship it with every build.

## Why not auto-import?

The STK asset repo is huge (~3 GB) and tracks have lots of repo-specific
bits (lua AI hints, custom particle XML, etc.) that Godot won't use
directly. Curating which karts/tracks to ship is a manual decision so we
keep this scripted, not automated.

## Recommended starter set

For the MVP, port these first — they're well-modeled, low-poly, and have
clean licensing:

**Karts (free CC-BY-SA, attribute the artist names from each `.license`):**
- Tux
- Beastie
- Sara the Wizard
- Pidgin
- Hexley

**Tracks:**
- Lighthouse (small, oval, great for testing)
- Cocoa Temple
- Volcano Island
- Black Forest
