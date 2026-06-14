# fetch-stk-assets.ps1
# Sparse-clone the SuperTuxKart assets repo so we don't pull the full ~3 GB.
# Targets only karts/ and tracks/ subtrees.
#
# Usage:
#   pwsh ./fetch-stk-assets.ps1                   # default: latest main
#   pwsh ./fetch-stk-assets.ps1 -Ref stk-1.4      # pin to release tag

param(
    [string]$Ref = "main",
    [string]$Dest = "$PSScriptRoot\stk-assets-src"
)

$ErrorActionPreference = "Stop"

$repo = "https://github.com/supertuxkart/stk-assets.git"

if (Test-Path $Dest) {
    Write-Host "Updating existing clone in $Dest..."
    git -C $Dest fetch --depth 1 origin $Ref
    git -C $Dest checkout FETCH_HEAD
    git -C $Dest sparse-checkout reapply
    Write-Host "Done."
    exit 0
}

Write-Host "Sparse-cloning supertuxkart/stk-assets ($Ref) into $Dest..."
git clone --depth 1 --filter=blob:none --sparse --branch $Ref $repo $Dest
Push-Location $Dest
try {
    git sparse-checkout init --cone
    git sparse-checkout set karts tracks music library
    git -c core.longpaths=true checkout
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "Cloned. Inspect with:"
Write-Host "  Get-ChildItem $Dest\karts | Select-Object -First 10"
Write-Host "  Get-ChildItem $Dest\tracks | Select-Object -First 10"
Write-Host ""
Write-Host "Next: copy the karts/tracks you want into ./curated/ and run convert-models.ps1"
