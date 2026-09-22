# Download a hitch Windows release and install the Grok plugin.
# No git clone. Plugin files are inside the binary.
#
#   irm https://raw.githubusercontent.com/LeviticusNelson/hitch/main/scripts/install.ps1 | iex
#
# $env:HITCH_VERSION = "v0.2.0"   # default: latest
# $env:HITCH_PREFIX  = "$env:LOCALAPPDATA\hitch"

$ErrorActionPreference = "Stop"
$repo = if ($env:HITCH_REPO) { $env:HITCH_REPO } else { "LeviticusNelson/hitch" }
$version = if ($env:HITCH_VERSION) { $env:HITCH_VERSION } else { "latest" }
$prefix = if ($env:HITCH_PREFIX) { $env:HITCH_PREFIX } else { Join-Path $env:LOCALAPPDATA "hitch" }

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    "ARM64" { "aarch64" }
    "AMD64" { "x86_64" }
    default { throw "unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}
$asset = "hitch-$arch-windows.exe"
if ($version -eq "latest") {
    $url = "https://github.com/$repo/releases/latest/download/$asset"
} else {
    $url = "https://github.com/$repo/releases/download/$version/$asset"
}

New-Item -ItemType Directory -Force -Path $prefix | Out-Null
$dest = Join-Path $prefix "hitch.exe"
Write-Host "downloading $url"
Invoke-WebRequest -Uri $url -OutFile $dest
& $dest install-plugin
Write-Host "hitch is at $dest"
Write-Host "edit $env:USERPROFILE\.hitch\env, then start hitch.exe"
