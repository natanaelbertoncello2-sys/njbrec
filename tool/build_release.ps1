# Compila NJB Rec en modo release, arma el zip portable y el instalador.
# Uso:  powershell -ExecutionPolicy Bypass -File tool/build_release.ps1 [-SkipBranding]
param([switch]$SkipBranding)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $root

# Versión desde pubspec.yaml (ej. "1.0.0+1" -> 1.0.0)
$versionLine = (Get-Content pubspec.yaml | Where-Object { $_ -match '^version:' })
$version = ($versionLine -replace 'version:\s*', '') -replace '\+.*$', ''
Write-Output "Versión: $version"

if (-not (Test-Path 'windows/ffmpeg/ffmpeg.exe')) {
  Write-Warning 'No existe windows/ffmpeg/ffmpeg.exe: la app dependerá de un ffmpeg instalado en el sistema.'
}

if (-not $SkipBranding) { python tool/make_branding.py }
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'La compilación falló.' }

$src = Join-Path $root 'build/windows/x64/runner/Release'
$distDir = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $distDir | Out-Null

# Zip portable
$zip = Join-Path $distDir "NJB-Rec-$version-portable-win64.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path "$src\*" -DestinationPath $zip
Write-Output "Zip portable: $zip"

# Instalador (Inno Setup)
$isccPath = $null
$cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if ($cmd) { $isccPath = $cmd.Source }
elseif (Test-Path 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe') { $isccPath = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' }
if ($isccPath) {
  $issFile = Join-Path $root 'installer\njbrec.iss'
  & $isccPath $issFile "/DAppVersion=$version"
  if ($LASTEXITCODE -ne 0) { throw 'Inno Setup falló.' }
  Write-Output "Instalador: $distDir\NJB-Rec-Setup-$version.exe"
} else {
  Write-Warning 'No se encontró Inno Setup (ISCC.exe); se omitió el instalador.'
}
