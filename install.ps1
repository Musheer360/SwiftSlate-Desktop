# SwiftSlate Desktop
# https://github.com/Musheer360/SwiftSlate-Desktop
# irm https://raw.githubusercontent.com/Musheer360/SwiftSlate-Desktop/master/install.ps1 | iex

$installDir = Join-Path $env:USERPROFILE ".swiftslate"
$runtimeDir = Join-Path $installDir "runtime"
$startupDir = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
$shortcutPath = Join-Path $startupDir "SwiftSlate Desktop.lnk"
$isInstalled = Test-Path (Join-Path $installDir "SwiftSlate.pyw")
$repo = "https://raw.githubusercontent.com/Musheer360/SwiftSlate-Desktop/master"
$pythonVersion = "3.12.7"
$pythonZipUrl = "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-embed-amd64.zip"

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
        Get-Process pythonw, python -ErrorAction SilentlyContinue | ForEach-Object {
            try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -EA SilentlyContinue).CommandLine
                if ($cmd -like "*SwiftSlate*") { Stop-Process -Id $_.Id -Force -EA SilentlyContinue }
            } catch {}
        }
        if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force }
        if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
        Write-Host ""
        Write-Host "  Uninstalled." -ForegroundColor Green
        Write-Host ""
        exit 0
    } elseif ($action -ne "1") { exit 0 }
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

$embeddedPythonw = Join-Path $runtimeDir "pythonw.exe"
if (Test-Path $embeddedPythonw) {
    $pythonwExe = $embeddedPythonw
    $pythonExe = Join-Path $runtimeDir "python.exe"
}

if (-not $pythonwExe) {
    Write-Host "  Downloading Python runtime..." -ForegroundColor DarkGray
    $zipPath = Join-Path $env:TEMP "python-embed.zip"
    try { Invoke-WebRequest -Uri $pythonZipUrl -OutFile $zipPath -UseBasicParsing } catch {
        Write-Host "  Failed. Install Python 3.10+ manually: python.org/downloads" -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }
    Expand-Archive -Path $zipPath -DestinationPath $runtimeDir -Force
    Remove-Item $zipPath -Force
    $pythonwExe = Join-Path $runtimeDir "pythonw.exe"
    $pythonExe = Join-Path $runtimeDir "python.exe"
    if (-not (Test-Path $pythonwExe)) { Write-Host "  Python setup failed." -ForegroundColor Red; exit 1 }
}

# --- Download ---
Write-Host "  Downloading..." -ForegroundColor DarkGray
try { Invoke-WebRequest -Uri "$repo/SwiftSlate.pyw" -OutFile (Join-Path $installDir "SwiftSlate.pyw") -UseBasicParsing } catch {
    Write-Host "  Download failed." -ForegroundColor Red; exit 1
}
# Only download commands.json on fresh install (preserve user customizations on update)
$commandsPath = Join-Path $installDir "commands.json"
if (-not (Test-Path $commandsPath)) {
    try { Invoke-WebRequest -Uri "$repo/commands.json" -OutFile $commandsPath -UseBasicParsing } catch {
        Write-Host "  Download failed." -ForegroundColor Red; exit 1
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

    if ([string]::IsNullOrWhiteSpace($apiKey)) { Write-Host "  No API key." -ForegroundColor Red; exit 1 }

    $cfg = @{ api_keys = @($apiKey); model = $model; provider = $provider; temperature = 0.3; prefix = "?" }
    if ($endpoint) { $cfg.endpoint = $endpoint }
    [System.IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding $false))
}

# --- Startup ---
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
}

# --- Done ---
Write-Host ""
Write-Host "  Done. Type a trigger (e.g. ?fix) in any app." -ForegroundColor Green
Write-Host ""
Write-Host "  Config:   $installDir\config.json" -ForegroundColor DarkGray
Write-Host "  Commands: $installDir\commands.json" -ForegroundColor DarkGray
Write-Host ""

$start = Read-Host "  Start now? [Y/n]"
if ($start -ne "n" -and $start -ne "N") {
    # Kill any existing instance first
    Get-Process pythonw, python -ErrorAction SilentlyContinue | ForEach-Object {
        try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -EA SilentlyContinue).CommandLine
            if ($cmd -like "*SwiftSlate*") { Stop-Process -Id $_.Id -Force -EA SilentlyContinue }
        } catch {}
    }
    Start-Sleep -Milliseconds 500
    Start-Process $pythonwExe -ArgumentList "`"$(Join-Path $installDir 'SwiftSlate.pyw')`"" -WorkingDirectory $installDir
    Write-Host "  Started." -ForegroundColor Green
}
Write-Host ""
