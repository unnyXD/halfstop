# Fetches the pinned SpektraLab engine source into third_party/spektrafilm.
#
# github.com itself is not reachable from this machine, but codeload.github.com
# is, so the tarball is used instead of a git clone. The tree is pinned to
# `445e314` on the `assist/vulkan-engine-1.3.4` branch, which is the engine the
# Android port in this repo is built and measured against.
#
# Two patches are applied after extraction:
#
#   1. tool/patches/engine-android.patch -- the Android fixes from
#      SAINTTaiYi/SpektraLab-Android (GPL-3.0-or-later): row-banded dispatches
#      that keep every binding inside maxStorageBufferRange, the 2^24-element
#      dispatch split, the IIR watchdog chunking, banded RGBA16 packing, and
#      mapped export buffers. Without them a Vulkan phone cannot render above
#      roughly 11 MP (128 MiB / 12 bytes per RGB float pixel).
#   2. The glslc flag hook, because the Android build has no Vulkan SDK and
#      uses the NDK's shaderc front end instead of glslangValidator.
#
#   .\tool\fetch-engine.ps1          # install if missing
#   .\tool\fetch-engine.ps1 -Force   # replace the current tree
#
# After fetching, run .\tool\build-shaders.ps1 once (Gradle also does it).

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$ref = "445e314"
$url = "https://codeload.github.com/JamesQiu2005/SpektraLab/tar.gz/$ref"

$repo = Split-Path -Parent $PSScriptRoot
$thirdParty = Join-Path $repo "third_party"
$dest = Join-Path $thirdParty "spektrafilm"

if ((Test-Path (Join-Path $dest "engine/CMakeLists.txt")) -and -not $Force) {
    Write-Host "Engine already vendored at $dest (use -Force to replace)."
    exit 0
}

$archive = Join-Path ([System.IO.Path]::GetTempPath()) "spektralab-$ref.tar.gz"
Write-Host "Downloading $url"
curl.exe -sS -L --retry 3 --connect-timeout 30 -o $archive $url
if ($LASTEXITCODE -ne 0) { throw "Download failed" }

# Keep only what the Android build needs. The macOS app, the Windows hosts and
# the test suites are dropped; the engine, its baked resources, the product
# profile overlay and the print LUTs are not.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "spektralab-$ref"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
tar -xzf $archive -C $tmp --strip-components=1 `
    "*/engine" `
    "*/license" `
    "*/modern_UI/Spektrafilm/Spektrafilm/Resources/DI" 2>$null
Remove-Item $archive

if (Test-Path $dest) {
    # Keep fetched dependencies (LibRaw) so a re-vendor does not re-download
    # 90 MB of third-party source.
    $keep = Join-Path $dest "build"
    $saved = Join-Path ([System.IO.Path]::GetTempPath()) "spektralab-build"
    if (Test-Path $saved) { Remove-Item $saved -Recurse -Force }
    if (Test-Path $keep) { Move-Item $keep $saved }
    Remove-Item $dest -Recurse -Force
    New-Item -ItemType Directory -Force $dest | Out-Null
    if (Test-Path $saved) { Move-Item $saved $keep }
} else {
    New-Item -ItemType Directory -Force $dest | Out-Null
}
Copy-Item (Join-Path $tmp "engine") (Join-Path $dest "engine") -Recurse
Copy-Item (Join-Path $tmp "license") (Join-Path $dest "license") -Recurse
New-Item -ItemType Directory -Force (Join-Path $dest "modern_UI/Spektrafilm/Spektrafilm/Resources") | Out-Null
Copy-Item (Join-Path $tmp "modern_UI/Spektrafilm/Spektrafilm/Resources/DI") `
    (Join-Path $dest "modern_UI/Spektrafilm/Spektrafilm/Resources/DI") -Recurse
Remove-Item $tmp -Recurse -Force

# --- 1. the Android engine fixes ---------------------------------------
$patch = Join-Path $repo "tool/patches/engine-android.patch"
if (-not (Test-Path $patch)) { throw "Android engine patch is missing at $patch" }
Push-Location $dest
try {
    git apply --check -p1 $patch
    if ($LASTEXITCODE -ne 0) { throw "Android engine patch does not apply to this tree" }
    git apply -p1 $patch
    if ($LASTEXITCODE -ne 0) { throw "Android engine patch failed" }
} finally {
    Pop-Location
}

# --- 2. glslc instead of glslangValidator ------------------------------
$cmakePath = Join-Path $dest "engine/CMakeLists.txt"
$cmake = Get-Content -Raw $cmakePath
if ($cmake -notmatch "SPEKTRALAB_GLSLANG_FLAGS") {
    $anchor = "    find_program(SPEKTRALAB_GLSLANG NAMES glslangValidator glslang`r`n        HINTS `"`$ENV{VULKAN_SDK}/Bin`" `"`$ENV{VULKAN_SDK}/bin`")"
    if (-not $cmake.Contains($anchor)) {
        # Tolerate LF line endings.
        $anchor = $anchor.Replace("`r`n", "`n")
    }
    if (-not $cmake.Contains($anchor)) { throw "Could not find the glslang find_program block to patch" }

    $insert = @"

    # The arguments that turn GLSL into SPIR-V. glslangValidator spells this
    # "-V --target-env vulkan1.0"; shaderc's glslc (shipped with the Android
    # NDK) spells it "--target-env=vulkan1.0". Hosts with only glslc set this.
    set(SPEKTRALAB_GLSLANG_FLAGS "-V;--target-env;vulkan1.0" CACHE STRING
        "Arguments passed to SPEKTRALAB_GLSLANG before -I/-o")
"@
    $cmake = $cmake.Replace("-V --target-env vulkan1.0", '${SPEKTRALAB_GLSLANG_FLAGS}')
    $cmake = $cmake.Replace($anchor, $anchor + $insert)
    [System.IO.File]::WriteAllText($cmakePath, $cmake)
}

Write-Host "Vendored engine at $dest (445e314 + Android patch)"
