#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HorizonRoot,
    [string]$GameDir = (Join-Path $HOME 'HorizonOffline/game'),
    [string]$PlayerName = 'Steve',
    [ValidateRange(0,10000)][int]$SmokeFrames = 0
)
$ErrorActionPreference = 'Stop'
$HorizonRoot = (Resolve-Path -LiteralPath $HorizonRoot).Path
$resources = Join-Path $HorizonRoot '.local/horizon-client/26.3'
$exe = Join-Path $HorizonRoot 'horizon-client.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing client: $exe" }
if (-not (Test-Path -LiteralPath (Join-Path $resources 'horizon-resources.json') -PathType Leaf)) {
    throw 'Prepared resources missing. Run Prepare-Horizon.ps1 first.'
}
& (Join-Path $HorizonRoot 'horizon-prepare.exe') --check --root $HorizonRoot --output $resources
if ($LASTEXITCODE -ne 0) { throw 'Resource check failed. Run Prepare-Horizon.ps1 again.' }
$GameDir = [IO.Path]::GetFullPath($GameDir)
$gameHome = Join-Path $GameDir '.horizon-home'
New-Item -ItemType Directory -Force -Path $GameDir,$gameHome | Out-Null
$clientArgs = @('--resources',$resources,'--game-dir',$GameDir,'--home',$gameHome,'--name',$PlayerName)
if ($SmokeFrames -gt 0) {
    $report = Join-Path $gameHome 'smoke-report.json'
    if (Test-Path -LiteralPath $report) { Remove-Item -LiteralPath $report }
    $clientArgs += @('--frames',"$SmokeFrames",'--timeout-seconds','120','--smoke-report',$report)
}
& $exe @clientArgs
if ($LASTEXITCODE -ne 0) { throw "Horizon exited with code $LASTEXITCODE" }
if ($SmokeFrames -gt 0) {
    $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($result.error -or $result.frames -lt $SmokeFrames) { throw "Smoke test failed. See $report" }
    Write-Host "Smoke test passed: $($result.frames) frames. Report: $report"
}
