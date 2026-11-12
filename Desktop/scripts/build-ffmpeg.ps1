param(
    [string]$Target = "x86_64-pc-windows-msvc",
    [string]$Msys2Root = "C:\msys64"
)
$ErrorActionPreference = "Stop"
$shell = Join-Path $Msys2Root "usr\bin\bash.exe"
if (-not (Test-Path $shell)) { throw "Install MSYS2 UCRT64 with GCC, make, curl, tar, xz and gnupg first." }
$script = (Join-Path $PSScriptRoot "build-ffmpeg.sh").Replace('\', '/')
$env:MSYSTEM = "UCRT64"
$env:CHERE_INVOKING = "1"
# Bash arguments are passed as arguments, not interpolated shell code.
& $shell --login $script $Target
if ($LASTEXITCODE -ne 0) { throw "The verified FFmpeg source build failed ($LASTEXITCODE)." }
