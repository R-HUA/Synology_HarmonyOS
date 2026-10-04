param([string]$SdkRoot = 'C:\Program Files\command-line-tools\sdk\default')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$compilerPath = Join-Path $SdkRoot 'openharmony\ets\build-tools\ets-loader\node_modules\typescript\bin\tsc'
if (-not (Test-Path -LiteralPath $compilerPath)) { throw '找不到 SDK TypeScript 编译器，请传入 -SdkRoot。' }
Push-Location -LiteralPath $projectRoot
try {
  $coreSources = @(Get-ChildItem -LiteralPath entry/src/main/ets/core -Recurse -Filter '*.ts' | ForEach-Object { $_.FullName })
  & node $compilerPath --target ES2020 --module commonjs --strict --skipLibCheck --outDir work/core-build $coreSources
  if ($LASTEXITCODE -ne 0) { throw '核心协议编译失败。' }
} finally { Pop-Location }
