param([string]$OutputRoot='C:\dev\converse-round', [ValidateSet('ARM64','x64')][string]$Architecture='ARM64')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-Location (Split-Path $PSScriptRoot -Parent)
$version=Get-Content VERSION.json -Raw | ConvertFrom-Json
$root=Join-Path $OutputRoot ([string]$version.build)
$runtime=if ($Architecture -eq 'ARM64') {'win-arm64'} else {'win-x64'}
New-Item -ItemType Directory -Force $root | Out-Null
& dotnet run --project windows/src/Converse.Core.Tests -c Release *> (Join-Path $root 'core-tests.log')
if ($LASTEXITCODE -ne 0) { throw 'Core tests failed; see core-tests.log' }
foreach($edition in @('production','demo')) {
    $out=Join-Path $root $edition
    if (Test-Path $out) { throw "Output exists; preserve it and choose another OutputRoot: $out" }
    $demo=if ($edition -eq 'demo') {'true'} else {'false'}
    & dotnet publish windows/src/Converse.Windows -c Release --self-contained true "-p:PublishTrimmed=false" "-p:Platform=$Architecture" "-p:RuntimeIdentifier=$runtime" "-p:ConverseDemo=$demo" -o $out *> (Join-Path $root "$edition-build.log")
    if ($LASTEXITCODE -ne 0) { throw "$edition build failed" }
    # Both the Windows App SDK and .NET runtime must travel in the ZIP.
    foreach($required in @('coreclr.dll','hostfxr.dll','hostpolicy.dll','System.Private.CoreLib.dll')) {
        if (!(Test-Path (Join-Path $out $required))) { throw "Self-contained runtime file missing: $required" }
    }
    $runtimeConfig=Get-Content (Join-Path $out 'Converse.Windows.runtimeconfig.json') -Raw | ConvertFrom-Json
    if ($runtimeConfig.runtimeOptions.framework -or $runtimeConfig.runtimeOptions.frameworks) {
        throw 'Release package still requires an installed .NET runtime'
    }
    $help=Get-Content (Join-Path $out 'Assets\help.json') -Raw | ConvertFrom-Json
    if ($help.appBuild -ne $version.build -or $help.appVersion -ne $version.version) { throw 'Help is missing or stale' }
    Get-ChildItem $out -File -Recurse | ForEach-Object { [pscustomobject]@{path=$_.FullName.Substring($out.Length+1);sha256=(Get-FileHash $_.FullName).Hash} } | ConvertTo-Json | Set-Content (Join-Path $root "$edition-manifest.json")
}
Write-Output "Paired builds ready: $root (not installed)"
