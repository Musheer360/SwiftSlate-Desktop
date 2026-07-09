# SwiftSlate Desktop
# https://github.com/Musheer360/SwiftSlate-Desktop
# irm https://cdn.jsdelivr.net/gh/Musheer360/SwiftSlate-Desktop@master/install.ps1 | iex

$installDir = Join-Path $env:USERPROFILE ".swiftslate"
$runtimeDir = Join-Path $installDir "runtime"
$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "SwiftSlate Desktop.lnk"
$isInstalled = Test-Path (Join-Path $installDir "SwiftSlate.pyw")
$repo = "https://cdn.jsdelivr.net/gh/Musheer360/SwiftSlate-Desktop@master"
$repoFallback = "https://raw.githubusercontent.com/Musheer360/SwiftSlate-Desktop/master"

# --- Helper: download with CDN fallback ---
function Get-File {
    param([string]$File, [string]$OutFile)
    try { Invoke-WebRequest -Uri "$repo/$File" -OutFile $OutFile -UseBasicParsing; return $true } catch {}
    try { Invoke-WebRequest -Uri "$repoFallback/$File" -OutFile $OutFile -UseBasicParsing; return $true } catch {}
    return $false
}
$pythonVersion = "3.12.7"
$pythonZipUrl = "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-embed-amd64.zip"

# --- Helper: kill running SwiftSlate instances ---
function Stop-SwiftSlate {
    Get-Process pythonw, python -ErrorAction SilentlyContinue | ForEach-Object {
        try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -EA SilentlyContinue).CommandLine
            if ($cmd -like "*SwiftSlate*") { Stop-Process -Id $_.Id -Force -EA SilentlyContinue }
        } catch {}
    }
    Start-Sleep -Milliseconds 500
}

Write-Host ""
Write-Host "  SwiftSlate Desktop" -ForegroundColor Cyan
Write-Host ""

# --- Already installed? ---
if ($isInstalled) {
    Write-Host "  Installed at $installDir" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [1] Update" -ForegroundColor White
    Write-Host "  [2] Uninstall" -ForegroundColor White
    Write-Host "  [3] Cancel" -ForegroundColor White
    Write-Host ""
    $action = Read-Host "  Choice"

    if ($action -eq "2") {
        $confirm = Read-Host "  Remove all data including config and commands? [y/N]"
        if ($confirm -ne "y" -and $confirm -ne "Y") {
            Write-Host "  Cancelled." -ForegroundColor DarkGray
            Write-Host ""
            return
        }
        Stop-SwiftSlate
        if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force }
        if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
        Write-Host ""
        Write-Host "  Uninstalled." -ForegroundColor Green
        Write-Host ""
        return
    } elseif ($action -ne "1") {
        Write-Host "  Cancelled." -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    # Update: kill running instance before replacing files
    Stop-SwiftSlate
    Write-Host ""
}

# --- Install directory ---
if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }

# --- Python ---
$pythonwExe = $null
$pythonExe = $null

$sysPython = Get-Command python -EA SilentlyContinue
if ($sysPython) {
    $ver = & python --version 2>&1
    if ($ver -match "Python 3\.(\d+)" -and [int]$Matches[1] -ge 10) {
        $pythonExe = $sysPython.Source
        $pythonwExe = Join-Path (Split-Path $pythonExe) "pythonw.exe"
        if (-not (Test-Path $pythonwExe)) { $pythonwExe = $null }
    }
}

# Check embedded runtime — validate it has essential files
$embeddedPythonw = Join-Path $runtimeDir "pythonw.exe"
$embeddedDll = Join-Path $runtimeDir "python312.dll"
if ((Test-Path $embeddedPythonw) -and (Test-Path $embeddedDll)) {
    $pythonwExe = $embeddedPythonw
    $pythonExe = Join-Path $runtimeDir "python.exe"
}

if (-not $pythonwExe) {
    Write-Host "  Downloading Python runtime..." -ForegroundColor DarkGray
    $zipPath = Join-Path $env:TEMP "python-embed.zip"
    try { Invoke-WebRequest -Uri $pythonZipUrl -OutFile $zipPath -UseBasicParsing } catch {
        Write-Host "  Failed to download Python. Install Python 3.10+ manually: python.org/downloads" -ForegroundColor Red
        return
    }
    if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }
    try { Expand-Archive -Path $zipPath -DestinationPath $runtimeDir -Force } catch {
        Write-Host "  Failed to extract Python runtime." -ForegroundColor Red
        return
    }
    Remove-Item $zipPath -Force -EA SilentlyContinue
    $pythonwExe = Join-Path $runtimeDir "pythonw.exe"
    $pythonExe = Join-Path $runtimeDir "python.exe"
    if (-not (Test-Path $pythonwExe)) { Write-Host "  Python setup failed." -ForegroundColor Red; return }
    Write-Host "  Python runtime ready." -ForegroundColor DarkGray
}

# --- Download (to temp first, then move — prevents partial overwrites) ---
Write-Host "  Downloading..." -ForegroundColor DarkGray
$tempPyw = Join-Path $env:TEMP "SwiftSlate.pyw.tmp"
if (-not (Get-File "SwiftSlate.pyw" $tempPyw)) {
    Write-Host "  Download failed." -ForegroundColor Red; return
}
Move-Item -Path $tempPyw -Destination (Join-Path $installDir "SwiftSlate.pyw") -Force

# Only download commands.json on fresh install (preserve user customizations on update)
$commandsPath = Join-Path $installDir "commands.json"
if (-not (Test-Path $commandsPath)) {
    if (-not (Get-File "commands.json" $commandsPath)) {
        Write-Host "  Download failed." -ForegroundColor Red; return
    }
}

# --- Config ---
$configPath = Join-Path $installDir "config.json"
if (-not (Test-Path $configPath)) {
    Write-Host ""
    Write-Host "  Provider:" -ForegroundColor DarkGray
    Write-Host "  [1] Groq    (free, recommended)" -ForegroundColor White
    Write-Host "  [2] Gemini  (free tier)" -ForegroundColor White
    Write-Host "  [3] Custom  (OpenAI-compatible)" -ForegroundColor White
    Write-Host ""
    $prov = Read-Host "  Choice [default: 1]"

    $provider = "groq"; $endpoint = ""; $model = ""; $apiKey = ""

    switch ($prov) {
        "2" {
            $provider = "gemini"
            Write-Host ""; Write-Host "  Key: https://aistudio.google.com/api-keys" -ForegroundColor Yellow
            Write-Host ""
            $apiKey = Read-Host "  API Key"
            Write-Host ""
            Write-Host "  [1] gemini-2.5-flash-lite (default)" -ForegroundColor White
            Write-Host "  [2] gemini-3-flash-preview" -ForegroundColor White
            Write-Host "  [3] gemini-3.1-flash-lite-preview" -ForegroundColor White
            Write-Host ""
            $m = Read-Host "  Model [default: 1]"
            $model = switch ($m) { "2" { "gemini-3-flash-preview" } "3" { "gemini-3.1-flash-lite-preview" } default { "gemini-2.5-flash-lite" } }
        }
        "3" {
            $provider = "custom"
            Write-Host ""
            $endpoint = Read-Host "  Endpoint (e.g. http://localhost:11434/v1)"
            Write-Host ""
            $apiKey = Read-Host "  API Key (Enter to skip)"
            if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = "none" }
            Write-Host ""
            $model = Read-Host "  Model name"
            if ([string]::IsNullOrWhiteSpace($model)) { $model = "default" }
        }
        default {
            $provider = "groq"
            Write-Host ""; Write-Host "  Key: https://console.groq.com/keys" -ForegroundColor Yellow
            Write-Host ""
            $apiKey = Read-Host "  API Key"
            Write-Host ""
            Write-Host "  [1] llama-3.3-70b-versatile (default)" -ForegroundColor White
            Write-Host "  [2] llama-3.1-8b-instant" -ForegroundColor White
            Write-Host "  [3] openai/gpt-oss-120b" -ForegroundColor White
            Write-Host "  [4] openai/gpt-oss-20b" -ForegroundColor White
            Write-Host "  [5] meta-llama/llama-4-scout-17b-16e-instruct" -ForegroundColor White
            Write-Host ""
            $m = Read-Host "  Model [default: 1]"
            $model = switch ($m) { "2" { "llama-3.1-8b-instant" } "3" { "openai/gpt-oss-120b" } "4" { "openai/gpt-oss-20b" } "5" { "meta-llama/llama-4-scout-17b-16e-instruct" } default { "llama-3.3-70b-versatile" } }
        }
    }

    if ([string]::IsNullOrWhiteSpace($apiKey)) { Write-Host "  No API key." -ForegroundColor Red; return }

    $cfg = @{ api_keys = @($apiKey); model = $model; provider = $provider; temperature = 0.5; prefix = "?" }
    if ($endpoint) { $cfg.endpoint = $endpoint }
    [System.IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding $false))
}

# --- Startup shortcut (create or update) ---
if (-not $isInstalled) {
    Write-Host ""
    $su = Read-Host "  Start on login? [Y/n]"
    if ($su -ne "n" -and $su -ne "N") {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($shortcutPath)
        $sc.TargetPath = $pythonwExe
        $sc.Arguments = "`"$(Join-Path $installDir 'SwiftSlate.pyw')`""
        $sc.WorkingDirectory = $installDir
        $sc.Description = "SwiftSlate Desktop"
        $sc.Save()
    }
} elseif (Test-Path $shortcutPath) {
    # Update: ensure shortcut points to current pythonwExe
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($shortcutPath)
    if ($sc.TargetPath -ne $pythonwExe) {
        $sc.TargetPath = $pythonwExe
        $sc.Arguments = "`"$(Join-Path $installDir 'SwiftSlate.pyw')`""
        $sc.WorkingDirectory = $installDir
        $sc.Save()
    }
}

# --- Done ---
Write-Host ""
if ($isInstalled) {
    Write-Host "  Updated." -ForegroundColor Green
} else {
    Write-Host "  Installed." -ForegroundColor Green
}
Write-Host ""
Write-Host "  Config:   $installDir\config.json" -ForegroundColor DarkGray
Write-Host "  Commands: $installDir\commands.json" -ForegroundColor DarkGray
Write-Host ""

$start = Read-Host "  Start now? [Y/n]"
if ($start -ne "n" -and $start -ne "N") {
    Stop-SwiftSlate
    Start-Process $pythonwExe -ArgumentList "`"$(Join-Path $installDir 'SwiftSlate.pyw')`"" -WorkingDirectory $installDir
    Write-Host "  Started." -ForegroundColor Green
}
Write-Host ""
