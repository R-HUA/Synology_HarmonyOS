param(
  [Parameter(Mandatory = $true)][string]$Address,
  [switch]$Login,
  [switch]$WithOtp,
  [string]$SdkRoot = 'C:\Program Files\command-line-tools\sdk\default'
)
$ErrorActionPreference = 'Stop'
# PowerShell 5.1 默认按系统 ANSI 解码原生进程输出、并按 ASCII 编码管道输入：
# 前者会让 Node 的 UTF-8 中文输出变成乱码，后者会让含非 ASCII 字符的密码在管道里被替换成 '?'。
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
& (Join-Path $PSScriptRoot 'compile-core.ps1') -SdkRoot $SdkRoot
$probeScript = Join-Path $PSScriptRoot 'probe-nas.cjs'
if ($Login) {
  $nasCredential = Get-Credential -Message 'NAS 普通用户账号（凭证仅在本机内存使用）'
  if ($null -eq $nasCredential) { throw '已取消凭证输入。' }
  $nasOtp = if ($WithOtp) { Read-Host '输入当前 6 位动态码' } else { '' }
  $probeInput = @{ account = $nasCredential.UserName; password = $nasCredential.GetNetworkCredential().Password; otp = $nasOtp }
  try { $probeInput | ConvertTo-Json -Compress | & node $probeScript $Address --login }
  finally { $probeInput.Clear(); $nasCredential = $null; $nasOtp = $null }
} else {
  & node $probeScript $Address
}
if ($LASTEXITCODE -ne 0) { throw 'NAS 诊断未通过，详见脱敏结果。' }
