# C:\ProgramData\e-Monitor\bootstrap.ps1
# Read files.json, download ONLY missing or changed files, remove local version.txt,
# retry after 1 minute on critical failure, start e-Monitor.exe, and delete .bak at the end.

# ==================== CONFIG ====================
$BaseUrl              = 'http://ws.e-kontroll.com.br/emonitor/64'
$MainExe              = 'e-Monitor.exe'
$MainArgs             = '--limit 100'
$RetryCount           = 3
$TimeoutSec           = 120
$DeleteVersionTxtLocal= $true
$MaxAttemptsOnFailure = 3
$WaitBetweenAttemptsS = 60
# =================================================

if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$UserDir   = Join-Path $env:APPDATA 'e-Monitor'
$GlobalDir = 'C:\ProgramData\e-Monitor'
$LogDir    = Join-Path $GlobalDir 'logs'
New-Item -ItemType Directory -Force -Path $UserDir, $LogDir | Out-Null
$LogFile   = Join-Path $LogDir ("bootstrap-{0:yyyyMMdd}.log" -f (Get-Date))

function Write-Log($msg) {
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  ($stamp + ' ' + $msg) | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Invoke-Web($url, $outFile=$null) {
  try {
    if ($outFile) {
      Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -TimeoutSec $TimeoutSec | Out-Null
      return $true
    } else {
      return Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec
    }
  } catch {
    Write-Log ("WARN: request failed {0} : {1}" -f $url, $_.Exception.Message)
    return $null
  }
}

function Get-RemoteHead($url) {
  try {
    $resp = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec $TimeoutSec
    $len  = $null
    $lm   = $null
    if ($resp.Headers['Content-Length']) { [void][int64]::TryParse($resp.Headers['Content-Length'], [ref]$len) }
    if ($resp.Headers['Last-Modified'])   { $lm = [datetime]::Parse($resp.Headers['Last-Modified']) }
    return [pscustomobject]@{ Length = $len; LastModified = $lm }
  } catch {
    Write-Log ("WARN: HEAD failed {0} : {1}" -f $url, $_.Exception.Message)
    return $null
  }
}

function Download-WithRetry($url, $dest) {
  for ($i=1; $i -le $RetryCount; $i++) {
    try {
      $usedBits = $false
      try {
        Import-Module BitsTransfer -ErrorAction SilentlyContinue | Out-Null
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
          Start-BitsTransfer -Source $url -Destination $dest -Description 'e-Monitor sync' -RetryInterval 60 -ErrorAction Stop
          $usedBits = $true
        }
      } catch {
        Write-Log ("INFO: BITS failed {0} : {1}" -f $url, $_.Exception.Message)
      }

      if (-not $usedBits) {
        Invoke-Web $url $dest | Out-Null
      }

      if (Test-Path $dest) {
        $fi = Get-Item $dest -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 0) { return $true }
        else { throw "Empty file after download." }
      } else {
        throw "File not found after download."
      }
    } catch {
      Write-Log ("ERROR: download failed ({0}/{1}) {2} : {3}" -f $i, $RetryCount, $url, $_.Exception.Message)
      Start-Sleep -Seconds ([Math]::Max(10, 5 * $i))
    }
  }
  return $false
}

function Ensure-RemoteFile($name, $sha256=$null) {
  $remoteUrl = $BaseUrl + [Uri]::EscapeDataString($name)
  $target    = Join-Path $UserDir $name
  $targetDir = Split-Path $target -Parent
  if ($targetDir) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }

  # If exists locally, compare Content-Length via HEAD
  if (Test-Path $target) {
    $local = Get-Item $target -ErrorAction SilentlyContinue
    $head  = Get-RemoteHead $remoteUrl
    if ($head -and $head.Length -ne $null) {
      if ($local.Length -eq $head.Length) {
        Write-Log ("No changes: {0} (same size {1} bytes) -- skipping." -f $name, $local.Length)
        return
      } else {
        Write-Log ("Different size for {0}: local={1} remote={2} -- will download." -f $name, $local.Length, $head.Length)
      }
    } else {
      Write-Log ("No Content-Length for {0} -- will download." -f $name)
    }
  }

  # Download to temp
  $tmp = Join-Path $env:TEMP ($name + '.' + ([guid]::NewGuid().ToString('n')) + '.dl')
  $ok  = Download-WithRetry $remoteUrl $tmp
  if (-not $ok) { throw ("Download failed for {0}" -f $name) }

  # Optional SHA256 validation
  if ($sha256) {
    try {
      $hash = (Get-FileHash -Algorithm SHA256 -Path $tmp).Hash.ToLower()
      if ($hash -ne $sha256.ToLower()) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw ("SHA256 mismatch for {0} (expected={1}; got={2})" -f $name, $sha256, $hash)
      }
    } catch {
      throw $_
    }
  }

  # Backup and replace
  if (Test-Path $target) {
    $bak = "$target.bak"
    try { Remove-Item $bak -Force -ErrorAction SilentlyContinue } catch {}
    Rename-Item -Path $target -NewName ([IO.Path]::GetFileName($bak)) -Force
  }
  Move-Item -Path $tmp -Destination $target -Force
  Unblock-File -Path $target -ErrorAction SilentlyContinue
  Write-Log ("Updated: {0}" -f $name)
}

function Run-Once {
  Write-Log ("=== Bootstrap started for {0} ===" -f $env:USERNAME)

  # 1) Remove local version.txt (if configured)
  if ($DeleteVersionTxtLocal) {
    $verLocal = Join-Path $UserDir 'version.txt'
    if (Test-Path $verLocal) {
      try { Remove-Item $verLocal -Force -ErrorAction SilentlyContinue; Write-Log "version.txt removed." } catch { Write-Log ("WARN: cannot remove version.txt: {0}" -f $_.Exception.Message) }
    }
  }

  # 2) Read files.json
  $manifestUrl = $BaseUrl + 'files.json'
  $resp = Invoke-Web $manifestUrl
  if (-not $resp -or [string]::IsNullOrWhiteSpace($resp.Content)) {
    throw ("Cannot read {0}" -f $manifestUrl)
  }
  try {
    $json = $resp.Content | ConvertFrom-Json
  } catch {
    throw ("Invalid files.json: {0}" -f $_.Exception.Message)
  }
  if (-not $json.files -or $json.files.Count -eq 0) {
    throw "files.json has no 'files' entries."
  }

  # 3) Split missing vs existing
  $items = @()
  foreach ($f in $json.files) {
    $n = $f.name
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    $items += [pscustomobject]@{ name = $n; sha256 = $f.sha256 }
  }
  $missing  = @()
  $existing = @()
  foreach ($it in $items) {
    if (Test-Path (Join-Path $UserDir $it.name)) { $existing += $it } else { $missing += $it }
  }
  Write-Log ("Missing: {0}"   -f (($missing  | ForEach-Object { $_.name }) -join ', '))
  Write-Log ("Existing: {0}"  -f (($existing | ForEach-Object { $_.name }) -join ', '))

  # 4) Get missing first
  foreach ($it in $missing)  { Ensure-RemoteFile -name $it.name -sha256 $it.sha256 }

  # 5) Then check existing (download only if changed)
  foreach ($it in $existing) { Ensure-RemoteFile -name $it.name -sha256 $it.sha256 }

  # 6) Start main app
  $exePath = Join-Path $UserDir $MainExe
  if (Test-Path $exePath) {
    $already = Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($MainExe)) -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exePath }
    if (-not $already) {
      Start-Process -FilePath $exePath -WorkingDirectory $UserDir -ArgumentList $MainArgs | Out-Null
      Write-Log ("App started: {0} {1}" -f $MainExe, $MainArgs)
    } else {
      Write-Log ("Already running: {0}" -f $already.Id)
    }
  } else {
    Write-Log ("WARNING: {0} not found after sync." -f $MainExe)
  }

  # 7) Delete .bak at the end
  $baks = Get-ChildItem -Path $UserDir -Recurse -Filter "*.bak" -ErrorAction SilentlyContinue
  foreach ($b in $baks) {
    try { Remove-Item $b.FullName -Force; Write-Log ("Backup removed: {0}" -f $b.FullName) }
    catch { Write-Log ("WARN: cannot remove backup {0} : {1}" -f $b.FullName, $_.Exception.Message) }
  }
}

# ================= GLOBAL RETRY LOOP =================
$attempt = 0
while ($true) {
  try {
    $attempt++
    Run-Once
    break
  } catch {
    Write-Log ("FATAL: {0}" -f $_.Exception.Message)
    if ($attempt -ge $MaxAttemptsOnFailure) {
      Write-Log ("Max attempts reached ({0}). Aborting." -f $MaxAttemptsOnFailure)
      exit 1
    } else {
      Write-Log ("Retrying in {0}s (attempt {1}/{2})..." -f $WaitBetweenAttemptsS, $attempt, $MaxAttemptsOnFailure)
      Start-Sleep -Seconds $WaitBetweenAttemptsS
    }
  }
}
