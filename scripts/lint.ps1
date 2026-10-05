param(
  [string]$ReportPath = 'work/lint/report.json',
  [string]$NativeLogPath = ''
)
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
  if ([string]::IsNullOrWhiteSpace($NativeLogPath) -and $env:DEVECO_CLI_CLT_PATH) {
    $NativeLogPath = Join-Path $env:DEVECO_CLI_CLT_PATH 'codelinter/linter/result/arkPerfCheck.log'
  }
  $previousLog = if ($NativeLogPath -and (Test-Path -LiteralPath $NativeLogPath -PathType Leaf)) {
    [System.IO.File]::ReadAllText($NativeLogPath)
  } else { '' }
  & devecocli check lint . --config-path code-linter.json5 --format json --output-path $temporaryReport
  if ($LASTEXITCODE -ne 0) { throw 'DevEco Linter 执行失败。' }
  if (-not (Test-Path -LiteralPath $temporaryReport -PathType Leaf)) { throw 'DevEco Linter 未生成诊断报告。' }
  $report = Get-Content -LiteralPath $temporaryReport -Raw | ConvertFrom-Json
  if ($null -eq $report.summary -or $null -eq $report.issues) { throw 'DevEco Linter 报告缺少诊断信息。' }
  if ($report.summary.issues -ne @($report.issues).Count) { throw 'DevEco Linter 报告的诊断数量不一致。' }
  Move-Item -LiteralPath $temporaryReport -Destination $reportFile -Force
  Write-Output ('完整诊断报告：' + $reportFile)
  # CLI 的 filesChecked 来自诊断文件集合；本次扫描覆盖须由新增的原生日志证明。
  if (-not $NativeLogPath -or -not (Test-Path -LiteralPath $NativeLogPath -PathType Leaf)) {
    throw '缺少本次扫描的覆盖证据，请通过 -NativeLogPath 指定 Homecheck 日志。'
  }
  $currentLog = [System.IO.File]::ReadAllText($NativeLogPath)
  if (-not $currentLog.StartsWith($previousLog, [System.StringComparison]::Ordinal)) {
    throw 'Homecheck 日志已轮换或改写，无法确认本次扫描覆盖，请重新检查。'
  }
  $newLog = $currentLog.Substring($previousLog.Length)
  $fileCounts = [regex]::Matches($newLog, '\[CheckEntry\] File count:\s*(\d+)')
  if ($fileCounts.Count -eq 0 -or [int]$fileCounts[$fileCounts.Count - 1].Groups[1].Value -le 0) {
    throw '本次 Homecheck 日志没有有效文件数，不能确认代码检查通过。'
  }
  $filesAnalyzed = [int]$fileCounts[$fileCounts.Count - 1].Groups[1].Value
  $filesWithDiagnostics = @($report.issues | Select-Object -ExpandProperty file -Unique).Count
  $report | Add-Member -NotePropertyName coverage -NotePropertyValue @{
    source = 'Homecheck'; filesAnalyzed = $filesAnalyzed; filesWithDiagnostics = $filesWithDiagnostics
  } -Force
  $report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $reportFile -Encoding UTF8
  Write-Output ('实际扫描文件数：' + $filesAnalyzed + '；包含诊断的文件数：' + $filesWithDiagnostics)
  if ($report.summary.issues -gt 0) {
    throw ('DevEco Linter 未通过：' + $report.summary.errors + ' 个错误，' + $report.summary.warnings + ' 个警告，' + $report.summary.suggestions + ' 个建议。')
  }
} finally { Pop-Location }
