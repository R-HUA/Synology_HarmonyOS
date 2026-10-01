param([string]$SdkRoot = 'C:\Program Files\command-line-tools\sdk\default')
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'compile-core.ps1') -SdkRoot $SdkRoot
Push-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
try {
  & node --test tests/unit/core.test.cjs
  if ($LASTEXITCODE -ne 0) { throw '核心协议测试失败。' }
} finally { Pop-Location }
