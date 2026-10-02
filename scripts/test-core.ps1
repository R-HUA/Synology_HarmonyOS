param([string]$SdkRoot = 'C:\Program Files\command-line-tools\sdk\default')
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'compile-core.ps1') -SdkRoot $SdkRoot
Push-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
$previousSdkRoot = $env:HARMONY_SDK_ROOT
try {
  $env:HARMONY_SDK_ROOT = $SdkRoot
  $testPaths = @(Get-ChildItem -LiteralPath tests/unit -Filter '*.test.cjs' | ForEach-Object { $_.FullName })
  & node --test $testPaths
  if ($LASTEXITCODE -ne 0) { throw '核心协议测试失败。' }
} finally { $env:HARMONY_SDK_ROOT = $previousSdkRoot; Pop-Location }
