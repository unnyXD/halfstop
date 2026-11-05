# Fetches the pinned LibRaw 0.22.2 source the engine's RAW decoder builds against.
#
# The engine vendors its own setup script (engine/setup-libraw.ps1), which
# downloads the official tag from codeload.github.com and verifies the archive
# SHA256 before extracting. This wrapper only decides where it goes: the path
# the engine's CMake already expects, so nothing has to be passed on the
# command line.
#
#   .\tool\fetch-libraw.ps1
#
# github.com is unreachable here but codeload.github.com is, which is why the
# upstream script uses a zipball rather than a clone. Idempotent: an existing
# tree is re-verified file by file and left untouched.

param()

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $repo "third_party/spektrafilm/engine"
$deps = Join-Path $repo "third_party/spektrafilm/build/deps"

if (-not (Test-Path (Join-Path $engine "setup-libraw.ps1"))) {
    throw "Engine sources are missing; run .\tool\fetch-engine.ps1 first."
}

& (Join-Path $engine "setup-libraw.ps1") -DependencyDirectory $deps
