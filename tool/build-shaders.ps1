# Compiles the engine's Vulkan compute kernels to SPIR-V.
#
# The engine loads <resources>/vulkan/<kernel>.spv at run time. The macOS and
# Windows builds generate these during their own build; the Android build ships
# the resources as APK assets, which are packaged before CMake runs, so the
# SPIR-V has to exist beforehand. This mirrors the upstream repo, which tracks
# its baked resources.
#
#   .\tool\build-shaders.ps1
#
# Re-run whenever engine/src/shaders/vulkan/*.comp or a *.glsl include changes.

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $repo "third_party\spektrafilm\engine"
$shaderDir = Join-Path $engine "src\shaders\vulkan"
$outDir = Join-Path $engine "resources\vulkan"

$toolchain = $env:SPK_TOOLCHAIN
if (-not $toolchain) {
    $toolchain = "C:\Users\qliu2\Documents\Workspaces\test\mobile_app\photo_watermark\.tools"
}
$ndkRoot = Join-Path $toolchain "android-sdk\ndk"
$ndk = Get-ChildItem $ndkRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $ndk) { throw "No NDK under $ndkRoot" }

if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $hostTag = "windows-x86_64"
    $exe = ".exe"
} elseif ($IsMacOS) {
    $hostTag = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq "Arm64") { "darwin-aarch64" } else { "darwin-x86_64" }
    $exe = ""
} else {
    $hostTag = "linux-x86_64"
    $exe = ""
}

$glslc = Join-Path $ndk.FullName "shader-tools\$hostTag\glslc$exe"
if (-not (Test-Path $glslc)) { throw "glslc not found at $glslc" }

New-Item -ItemType Directory -Force $outDir | Out-Null
$shaders = Get-ChildItem (Join-Path $shaderDir "*.comp")
$failed = @()
foreach ($shader in $shaders) {
    $target = Join-Path $outDir ($shader.BaseName + ".spv")
    & $glslc --target-env=vulkan1.0 "-I$shaderDir" -o $target $shader.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $shader.Name }
}

if ($failed.Count -gt 0) {
    throw "Shader compilation failed: $($failed -join ', ')"
}

$bytes = (Get-ChildItem $outDir -Filter *.spv | Measure-Object Length -Sum).Sum
Write-Host ("Compiled {0} kernels to {1} ({2:N0} kB)" -f $shaders.Count, $outDir, ($bytes / 1kB))
