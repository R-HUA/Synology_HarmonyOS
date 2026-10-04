param([string]$ReportPath = 'work/lint/report.json')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectRoot
try {
  $reportFile = if ([System.IO.Path]::IsPathRooted($ReportPath)) {
    [System.IO.Path]::GetFullPath($ReportPath)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $projectRoot $ReportPath))
  }
  $reportDirectory = Split-Path -Parent $reportFile
  New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
  $temporaryReport = Join-Path $reportDirectory ('lint-' + [guid]::NewGuid().ToString() + '.json')
  & devecocli check lint . --config-path code-linter.json5 --format json --output-path $temporaryReport
  if ($LASTEXITCODE -ne 0) { throw 'DevEco Linter 执行失败。' }
  if (-not (Test-Path -LiteralPath $temporaryReport -PathType Leaf)) { throw 'DevEco Linter 未生成诊断报告。' }
  $report = Get-Content -LiteralPath $temporaryReport -Raw | ConvertFrom-Json
  if ($null -eq $report.summary -or $null -eq $report.issues) { throw 'DevEco Linter 报告缺少诊断信息。' }
  if ($report.summary.issues -ne @($report.issues).Count) { throw 'DevEco Linter 报告的诊断数量不一致。' }
  Move-Item -LiteralPath $temporaryReport -Destination $reportFile -Force
  Write-Output ('完整诊断报告：' + $reportFile)
  if ($report.summary.issues -gt 0) {
    throw ('DevEco Linter 未通过：' + $report.summary.errors + ' 个错误，' + $report.summary.warnings + ' 个警告，' + $report.summary.suggestions + ' 个建议。')
  }
} finally { Pop-Location }
