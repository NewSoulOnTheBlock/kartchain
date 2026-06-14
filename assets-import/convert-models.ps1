# convert-models.ps1
# Convert STK .b3d / .x / .spm models found in ./curated/ to glTF .glb
# using Blender's Python API as a CLI driver.
#
# Requires: Blender 4.x on PATH (or pass -Blender "C:\Program Files\Blender Foundation\Blender 4.2\blender.exe")
#
# Usage:
#   pwsh ./convert-models.ps1
#   pwsh ./convert-models.ps1 -Blender "C:\Tools\Blender\blender.exe"
#
# Notes:
#  - .b3d (Blitz3D) is the historical STK format. Blender has community
#    importers but coverage varies. If a model fails to import, open it in
#    Blender manually and re-export to .glb.
#  - .spm (SuperTuxKart Mesh) is STK's custom format — requires the
#    blender-stk-tools addon. See ./STK-FORMAT-NOTES.md.

param(
    [string]$Blender = "blender",
    [string]$Source = "$PSScriptRoot\curated",
    [string]$Out = "$PSScriptRoot\out"
)

$ErrorActionPreference = "Stop"

# Check Blender is available
try {
    & $Blender --version | Out-Null
} catch {
    Write-Error "Blender not found at '$Blender'. Install Blender 4.x or pass -Blender <path>."
    exit 1
}

if (-not (Test-Path $Source)) {
    Write-Error "No curated folder at $Source. Copy the karts/tracks you want from ./stk-assets-src/karts and ./stk-assets-src/tracks first."
    exit 1
}

New-Item -ItemType Directory -Force -Path "$Out\karts","$Out\tracks" | Out-Null

$script = @'
import sys, os, bpy
infile  = sys.argv[sys.argv.index("--") + 1]
outfile = sys.argv[sys.argv.index("--") + 2]

# Fresh scene
bpy.ops.wm.read_factory_settings(use_empty=True)

ext = os.path.splitext(infile)[1].lower()
if ext == ".b3d":
    # Requires "Import B3D" community addon to be enabled.
    bpy.ops.import_scene.b3d(filepath=infile)
elif ext in (".x", ".x-ascii"):
    bpy.ops.import_scene.x(filepath=infile)
elif ext == ".spm":
    bpy.ops.import_mesh.spm(filepath=infile)   # blender-stk-tools
elif ext in (".obj",):
    bpy.ops.wm.obj_import(filepath=infile)
elif ext in (".fbx",):
    bpy.ops.import_scene.fbx(filepath=infile)
else:
    raise RuntimeError(f"unsupported extension: {ext}")

bpy.ops.export_scene.gltf(
    filepath=outfile,
    export_format="GLB",
    export_yup=True,
    export_apply=True,
    export_animations=True,
)
print("[convert] wrote", outfile)
'@

$scriptPath = Join-Path $env:TEMP "kartchain-convert.py"
Set-Content -Path $scriptPath -Value $script -Encoding UTF8

$any = $false
Get-ChildItem -Path $Source -Recurse -Include *.b3d,*.x,*.spm,*.obj,*.fbx | ForEach-Object {
    $rel = $_.FullName.Substring($Source.Length).TrimStart('\','/')
    $kind = if ($rel.StartsWith("karts")) { "karts" } elseif ($rel.StartsWith("tracks")) { "tracks" } else { "misc" }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    $outDir = Join-Path $Out $kind
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $outFile = Join-Path $outDir "$stem.glb"
    Write-Host "→ $rel -> $kind/$stem.glb"
    & $Blender --background --python $scriptPath -- $_.FullName $outFile
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  failed: $rel (continuing)"
    } else {
        $any = $true
    }
}

if (-not $any) {
    Write-Warning "Nothing converted. Did you copy any .b3d/.x/.spm models into $Source?"
}

Remove-Item $scriptPath -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Done. Copy $Out\karts\*.glb to ..\client\karts\ and $Out\tracks\*.glb to ..\client\tracks\"
