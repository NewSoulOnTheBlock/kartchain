# stage-shared-textures.ps1
#
# Before `convert_spm.py` (Blender) runs, the per-track .spm files reference
# texture filenames that live in the shared STK pools at:
#   stk-assets-src/textures/  (~640 files — most generic stk_*, stktex_*)
#   stk-assets-src/library/*  (model-specific atlases)
#
# Blender's io_scene_spm addon only finds textures in the .spm's own
# directory, so the previous .glb conversions produced materials with NO
# baseColorTexture for every shared-texture reference. Result: tracks look
# mostly white/gray in-engine (especially cocoa_temple, which references 40+
# stk-shared textures).
#
# This script scans the chosen tracks' existing .glb files for unbound
# texture refs, locates each one in stk-assets-src, and copies it into the
# track folder. After running, re-run convert_spm.py to re-bake the .glb
# files with all textures embedded.
#
# Usage (from repo root):
#   pwsh -File assets-import/stage-shared-textures.ps1
#   pwsh -File assets-import/stage-shared-textures.ps1 -Tracks cocoa_temple,hacienda

param(
  [string[]] $Tracks = @('cocoa_temple', 'hacienda', 'snowmountain', 'lighthouse'),
  [string]   $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..'))
)

$ErrorActionPreference = 'Stop'

$ClientTracks = Join-Path $RepoRoot 'client\tracks'
$SrcRoot      = Join-Path $RepoRoot 'assets-import\stk-assets-src'

if (-not (Test-Path $SrcRoot)) {
  Write-Error "stk-assets-src not found at $SrcRoot. Run fetch-stk-assets.ps1 first."
}

# Build a fast filename -> first-path index of every PNG/JPG in the source
# pool so we can resolve thousands of references without re-scanning.
Write-Host "[stage] Indexing shared textures under $SrcRoot ..."
$index = @{}
Get-ChildItem -Path $SrcRoot -Recurse -Include *.png, *.jpg, *.jpeg -File `
  -ErrorAction SilentlyContinue | ForEach-Object {
    $name = $_.Name
    if (-not $index.ContainsKey($name)) {
      $index[$name] = $_.FullName
    }
  }
Write-Host "[stage] Indexed $($index.Count) shared texture files"

function Get-GlbUnboundTextures {
  param([string] $GlbPath)
  $bytes = [System.IO.File]::ReadAllBytes($GlbPath)
  if ($bytes.Length -lt 20) { return @() }
  $magic = [System.Text.Encoding]::ASCII.GetString($bytes[0..3])
  if ($magic -ne 'glTF') { return @() }
  $jsonLen = [BitConverter]::ToUInt32($bytes, 12)
  $json = [System.Text.Encoding]::UTF8.GetString($bytes, 20, $jsonLen)
  try { $obj = $json | ConvertFrom-Json -ErrorAction Stop }
  catch { return @() }
  $names = New-Object System.Collections.Generic.HashSet[string]
  foreach ($m in $obj.materials) {
    $n = $m.name
    if (-not $n) { continue }
    if ($n -notmatch '\.(png|jpg|jpeg)$') { continue }
    if (-not $m.pbrMetallicRoughness.baseColorTexture) {
      [void] $names.Add($n)
    }
  }
  return $names
}

$grandTotal = 0
foreach ($t in $Tracks) {
  $trackDir = Join-Path $ClientTracks $t
  if (-not (Test-Path $trackDir)) {
    Write-Warning "[$t] track folder missing — skipping"
    continue
  }

  # Union of all unbound texture refs across every .glb in the track folder.
  $needed = New-Object System.Collections.Generic.HashSet[string]
  foreach ($glb in Get-ChildItem $trackDir -Filter *.glb -File) {
    foreach ($n in Get-GlbUnboundTextures $glb.FullName) {
      [void] $needed.Add($n)
    }
  }

  $staged = 0
  $missing = @()
  foreach ($n in $needed) {
    $dest = Join-Path $trackDir $n
    if (Test-Path $dest) { continue }
    if ($index.ContainsKey($n)) {
      Copy-Item $index[$n] $dest
      $staged++
    } else {
      $missing += $n
    }
  }

  Write-Host ("[{0}] needed={1} staged={2} already_present={3} unresolved={4}" -f `
    $t, $needed.Count, $staged, ($needed.Count - $staged - $missing.Count), $missing.Count)
  if ($missing.Count -gt 0) {
    Write-Host "  unresolved:"
    $missing | ForEach-Object { Write-Host "    $_" }
  }
  $grandTotal += $staged
}

Write-Host ""
Write-Host "[stage] DONE — staged $grandTotal texture file(s)"
Write-Host "[stage] Next: delete the affected .glb files and re-run convert_spm.py"
Write-Host "[stage]    pwsh -File assets-import/reconvert-tracks.ps1"
