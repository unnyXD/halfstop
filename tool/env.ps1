# Puts the portable Flutter/Android toolchain on PATH for this shell.
#
# The toolchain lives beside this repo, in the .tools/ directory of an older
# project. Override SPK_TOOLCHAIN to point somewhere else.
#
#   . .\tool\env.ps1
#   flutter build apk --debug

$toolchain = $env:SPK_TOOLCHAIN
if (-not $toolchain) {
    $toolchain = "C:\Users\qliu2\Documents\Workspaces\test\mobile_app\photo_watermark\.tools"
}
if (-not (Test-Path "$toolchain\flutter\bin\flutter.bat")) {
    throw "Flutter not found under $toolchain. Set SPK_TOOLCHAIN to a directory with flutter/, jdk/, android-sdk/."
}

$jdk = Get-ChildItem "$toolchain\jdk" -Directory | Select-Object -First 1
if (-not $jdk) { throw "No JDK under $toolchain\jdk" }

$env:FLUTTER_ROOT = "$toolchain\flutter"
$env:JAVA_HOME = $jdk.FullName
$env:ANDROID_HOME = "$toolchain\android-sdk"
$env:ANDROID_SDK_ROOT = "$toolchain\android-sdk"
$env:PUB_CACHE = "$toolchain\pub-cache"
$env:GRADLE_USER_HOME = "$toolchain\gradle-home"
$env:FLUTTER_SUPPRESS_ANALYTICS = "true"

$entries = $env:PATH -split ';' | Where-Object { $_ -and $_ -notlike "$toolchain*" }
$prefix = @(
    "$toolchain\flutter\bin",
    "$env:JAVA_HOME\bin",
    "$toolchain\android-sdk\cmdline-tools\latest\bin",
    "$toolchain\android-sdk\platform-tools",
    "$toolchain\android-sdk\build-tools\36.0.0"
) -join ';'
$env:PATH = "$prefix;" + ($entries -join ';')

Write-Host "Flutter : $toolchain\flutter"
Write-Host "JDK     : $env:JAVA_HOME"
Write-Host "SDK     : $env:ANDROID_HOME"
