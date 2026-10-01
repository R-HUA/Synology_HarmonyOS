param(
  [Parameter(Mandatory = $true)][string]$Address,
  [switch]$Login,
  [switch]$WithOtp,
  [string]$SdkRoot = 'C:\Program Files\command-line-tools\sdk\default'
)
$ErrorActionPreference = 'Stop'
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
