param([string]$OutputRoot='C:\dev\converse-round')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-Location (Split-Path $PSScriptRoot -Parent)
$version=Get-Content VERSION.json -Raw | ConvertFrom-Json
$root=Join-Path $OutputRoot ([string]$version.build)
New-Item -ItemType Directory -Force $root | Out-Null
& dotnet run --project windows/src/Converse.Core.Tests -c Release *> (Join-Path $root 'core-tests.log')
if ($LASTEXITCODE -ne 0) { throw 'Core tests failed; see core-tests.log' }
foreach($edition in @('production','demo')) {
    $out=Join-Path $root $edition
    if (Test-Path $out) { throw "Output exists; preserve it and choose another OutputRoot: $out" }
    $demo=if ($edition -eq 'demo') {'true'} else {'false'}
    & dotnet build windows/src/Converse.Windows -t:Rebuild -c Release -p:Platform=ARM64 -p:RuntimeIdentifier=win-arm64 "-p:ConverseDemo=$demo" -o $out *> (Join-Path $root "$edition-build.log")
    if ($LASTEXITCODE -ne 0) { throw "$edition build failed" }
    $help=Get-Content (Join-Path $out 'Assets\help.json') -Raw | ConvertFrom-Json
    if ($help.appBuild -ne $version.build -or $help.appVersion -ne $version.version) { throw 'Help is missing or stale' }
    Get-ChildItem $out -File -Recurse | ForEach-Object { [pscustomobject]@{path=$_.FullName.Substring($out.Length+1);sha256=(Get-FileHash $_.FullName).Hash} } | ConvertTo-Json | Set-Content (Join-Path $root "$edition-manifest.json")
}
Write-Output "Paired builds ready: $root (not installed)"
