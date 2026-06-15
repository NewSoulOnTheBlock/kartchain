# reconvert-tracks.ps1
#
# Re-runs Blender's STK .spm → .glb conversion for specific tracks.
# convert_spm.py skips tracks whose .glb already exists, so this helper
# nukes the existing .glb sidecars first, then drives Blender headlessly.
#
# Always run stage-shared-textures.ps1 FIRST so the shared STK textures
# are present in each track folder before Blender opens the .spm files.
#
# Usage (from repo root):
#   pwsh -File assets-import/stage-shared-textures.ps1
#   pwsh -File assets-import/reconvert-tracks.ps1
#   pwsh -File assets-import/reconvert-tracks.ps1 -Tracks cocoa_temple

param(
  [string[]] $Tracks = @('cocoa_temple', 'hacienda', 'snowmountain', 'lighthouse'),
  [string]   $Blender = 'C:\Program Files\Blender Foundation\Blender 5.1\blender.exe',
  [string]   $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..'))
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Blender)) {
  Write-Error "Blender not found at $Blender. Pass -Blender '<path-to-blender.exe>'."
}

$ClientDir = Join-Path $RepoRoot 'client'
$ConvertPy = Join-Path $PSScriptRoot 'convert_spm.py'

if (-not (Test-Path $ConvertPy)) {
  Write-Error "convert_spm.py missing at $ConvertPy"
}

# Delete existing .glb files (and Godot .import sidecars) for the chosen
# tracks so convert_spm.py actually re-runs on them.
foreach ($t in $Tracks) {
  $trackDir = Join-Path $ClientDir "tracks\$t"
  if (-not (Test-Path $trackDir)) {
    Write-Warning "[$t] track folder missing — skipping"
    continue
  }
  $glbs = Get-ChildItem $trackDir -Filter *.glb -File
  $imports = Get-ChildItem $trackDir -Filter *.glb.import -File
  foreach ($f in $glbs)     { Remove-Item $f.FullName -Force }
  foreach ($f in $imports)  { Remove-Item $f.FullName -Force }
  Write-Host "[$t] deleted $($glbs.Count) .glb + $($imports.Count) .import files"
}

# Drive Blender headlessly. convert_spm.py walks karts/ + tracks/ + library/
# but skips anything where the .glb already exists, so only the tracks we
# just nuked will be re-converted.
Write-Host ""
Write-Host "[convert] launching Blender — this can take a few minutes per track..."
$logPath = Join-Path $PSScriptRoot 'reconvert.log'
& $Blender --background --python $ConvertPy -- $ClientDir 2>&1 | Tee-Object -FilePath $logPath
Write-Host ""
Write-Host "[convert] full log saved to $logPath"
