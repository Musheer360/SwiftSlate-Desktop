# SwiftSlate Desktop
# https://github.com/Musheer360/SwiftSlate-Desktop
# irm https://raw.githubusercontent.com/Musheer360/SwiftSlate-Desktop/master/install.ps1 | iex
# (CDN mirror: irm https://cdn.jsdelivr.net/gh/Musheer360/SwiftSlate-Desktop@master/install.ps1 | iex)

# --- Locations ---
$installDir = Join-Path $env:USERPROFILE ".swiftslate"
$runtimeDir = Join-Path $installDir "runtime"
$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "SwiftSlate Desktop.lnk"

# --- Download sources ---
# Raw is always tried first: it never caches, so it always serves the latest push.
# jsDelivr is the fallback: fast, but can lag a push by up to ~12 hours.
$repoRaw = "https://raw.githubusercontent.com/Musheer360/SwiftSlate-Desktop/master"
$repoCdn = "https://cdn.jsdelivr.net/gh/Musheer360/SwiftSlate-Desktop@master"
$pythonVersion = "3.13.15"
$pythonZipUrl = "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-embed-amd64.zip"
# "3.13.15" -> "313" for python313.dll / python313.zip (major.minor only)
$pyTag = (($pythonVersion -split '\.')[0] + ($pythonVersion -split '\.')[1])

# Pinned SHA-256 hashes. Changing SwiftSlate.pyw or commands.json requires updating the
# matching hash in the SAME commit; CI fails the build otherwise. The python.zip pin is
# verified at install time and by CI (URL reachability); bump it whenever $pythonVersion
# changes. Recompute with: sha256sum <file>  (or `Get-FileHash -Algorithm SHA256` on Windows)
$hashes = @{
    "SwiftSlate.pyw" = "DCE0BD60C2DE145368A5975D0D0C1F20CCDD792D68756117FA5831EF49A440DE"
    "commands.json"  = "CE38B3C4B48B56BA40B8BD23C58AE873C3B29D78BD8319FA96CEBB923A478E9A"
    "python.zip"     = "D1F04D990AEE1253D8569E8E5104E30FA9F5FA830899F14843448872D936A2CF"
}

# Fail loudly on errors instead of pretending; skip progress-bar overhead (slow on PS 5.1)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# TLS 1.2+ (older PowerShell defaults to TLS 1.0, which CDNs reject; Tls13 guard for old .NET)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# --- Download a file (GitHub raw first, jsDelivr fallback), verifying its SHA-256 ---
function Get-File {
    param([string]$Name, [string]$OutFile)
    $urls = @("$repoRaw/$Name", "$repoCdn/$Name")
    foreach ($url in $urls) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -TimeoutSec 30
            $actual = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
            if ($actual -ieq $hashes[$Name]) { return }
            Write-Host "  [BAD HASH] $url (expected $($hashes[$Name]), got $actual)" -ForegroundColor DarkGray
        } catch {
            Write-Host "  [ERR] $url - $($_.Exception.Message)" -ForegroundColor DarkGray
        }
        Remove-Item $OutFile -Force -EA SilentlyContinue
    }
    throw "Could not download $Name from any source (network failure or failed integrity check). Check your internet connection, proxy/VPN, or antivirus, then run this command again. If the message above says BAD HASH, the CDN is mid-update - wait a minute and re-run."
}

# --- Stop running SwiftSlate instances and wait for them to exit ---
function Stop-SwiftSlate {
    $procIds = Get-CimInstance Win32_Process -EA SilentlyContinue |
        Where-Object {
            $_.CommandLine -like "*SwiftSlate.pyw*" -and (
                # Our embedded runtime lives under the install dir; a system-Python
                # launch is any python process whose command line references our
                # script. This never matches an unrelated process (e.g. an editor
                # that merely has the file open).
                $_.ExecutablePath -like "$installDir*" -or $_.Name -like "python*"
            )
        } |
        ForEach-Object { $_.ProcessId }
    foreach ($procId in $procIds) {
        Stop-Process -Id $procId -Force -EA SilentlyContinue
    }
    foreach ($procId in $procIds) {
        Wait-Process -Id $procId -Timeout 10 -EA SilentlyContinue
    }
}

# --- API key prompt that keeps the key out of the terminal history ---
function Read-SecureKey {
    param([string]$Prompt)
    $sec = Read-Host $Prompt -AsSecureString
    if ($null -eq $sec -or $sec.Length -eq 0) { return "" }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# --- Read the provider's model catalog from the downloaded app file itself ---
# Single source of truth: no hardcoded model names to drift. Returns @() if the
# catalog can't be parsed, in which case the app's own defaults are used.
function Get-ProviderModels {
    param([string]$PywPath, [string]$Provider)
    $dictName = if ($Provider -eq "groq") { "GROQ_MODEL_PARAMS" } else { "GEMINI_MODEL_PARAMS" }
    try {
        $text = [IO.File]::ReadAllText($PywPath)
        $block = [regex]::Match(
            $text,
            "$dictName\s*=\s*\{(?<body>.*?)\n\}",
            [Text.RegularExpressions.RegexOptions]::Singleline
        )
        if (-not $block.Success) { return @() }
        # Model entries are dicts ("name": {...}); inner keys are strings/bools.
        return @([regex]::Matches($block.Groups["body"].Value, '"([^"]+)":\s*\{') |
            ForEach-Object { $_.Groups[1].Value })
    } catch {
        return @()
    }
}

# --- Smoke test: does the runtime actually execute? ---
function Test-Runtime {
    param([string]$PythonExe)
    try {
        & $PythonExe -c "import sys" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        # A corrupt python.exe fails to start (terminating error under EAP=Stop) —
        # treat that as a failed smoke test, never as an installer crash.
        return $false
    }
}

# --- Find or install a Python runtime; returns the path to pythonw.exe ---
function Get-Pythonw {
    $pywExe = Join-Path $runtimeDir "pythonw.exe"

    # 1) Already-extracted embedded runtime (validated file set + smoke test).
    # File names derive from $pythonVersion so a version bump never pins an old
    # runtime forever or re-downloads on every run.
    $required = @("pythonw.exe", "python.exe", "python$pyTag.dll", "python$pyTag.zip", "vcruntime140.dll")
    $missing = $required | Where-Object { -not (Test-Path (Join-Path $runtimeDir $_)) }
    if (-not $missing -and (Test-Runtime (Join-Path $runtimeDir "python.exe"))) {
        return $pywExe
    }

    # 2) System Python 3.10+ with pythonw.exe
    $sysPython = Get-Command python -EA SilentlyContinue
    if ($sysPython) {
        $ver = & python --version 2>&1
        if ($ver -match "Python 3\.(\d+)" -and [int]$Matches[1] -ge 10) {
            $pythonw = Join-Path (Split-Path $sysPython.Source) "pythonw.exe"
            if (Test-Path $pythonw) { return $pythonw }
        }
    }

    # 3) Download the portable runtime from python.org
    Write-Host "  Downloading Python runtime..." -ForegroundColor DarkGray
    $zipPath = Join-Path $env:TEMP "python-embed.zip"
    try {
        Invoke-WebRequest -Uri $pythonZipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 300
        $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash
        if ($actual -ine $hashes["python.zip"]) {
            throw "integrity check failed (expected $($hashes['python.zip']), got $actual)"
        }
        # Extract to a fresh directory, verify, then swap — a mid-extract failure must
        # never destroy a previously-working runtime.
        $newDir = Join-Path $installDir "runtime.new"
        Remove-Item $newDir -Recurse -Force -EA SilentlyContinue
        Expand-Archive -Path $zipPath -DestinationPath $newDir
        $missing = $required | Where-Object { -not (Test-Path (Join-Path $newDir $_)) }
        if ($missing -or -not (Test-Runtime (Join-Path $newDir "python.exe"))) {
            Remove-Item $newDir -Recurse -Force -EA SilentlyContinue
            throw "Python runtime extraction was incomplete or corrupt."
        }
        Remove-Item $runtimeDir -Recurse -Force -EA SilentlyContinue
        Move-Item $newDir $runtimeDir
    } catch {
        Remove-Item $zipPath -Force -EA SilentlyContinue
        throw "Could not download the Python runtime from python.org ($($_.Exception.Message)). Check your internet connection or proxy and try again, or install Python 3.10+ from https://python.org/downloads - the installer will detect it."
    }
    Write-Host "  Python runtime ready." -ForegroundColor DarkGray
    return $pywExe
}

# --- Let the user pick a model from the catalog read out of the app file ---
function Select-Model {
    param([string]$Provider)
    $models = @(Get-ProviderModels (Join-Path $installDir "SwiftSlate.pyw") $Provider)
    if ($models.Count -eq 0) {
        # Catalog unreadable — let the app use its own default.
        return $null
    }
    Write-Host ""
    for ($i = 0; $i -lt $models.Count; $i++) {
        $defaultMark = if ($i -eq 0) { " (default)" } else { "" }
        Write-Host "  [$($i + 1)] $($models[$i])$defaultMark" -ForegroundColor White
    }
    Write-Host ""
    $choice = Read-Host "  Model [default: 1]"
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $models.Count) {
        return $models[$idx - 1]
    }
    return $models[0]
}

# --- Main ---
Write-Host ""
Write-Host "  SwiftSlate Desktop" -ForegroundColor Cyan
Write-Host ""

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Host "  SwiftSlate requires 64-bit Windows." -ForegroundColor Red
    Write-Host ""
    return
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Host "  Run this installer in a normal (non-admin) window so it installs for your own user account." -ForegroundColor Red
    Write-Host ""
    return
}

try {
    $isInstalled = Test-Path (Join-Path $installDir "SwiftSlate.pyw")

    # --- Already installed: update / uninstall / cancel ---
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
            if ($confirm -notmatch "^[yY]$") {
                Write-Host "  Cancelled." -ForegroundColor DarkGray
                Write-Host ""
                return
            }
            Stop-SwiftSlate
            Remove-Item $shortcutPath -Force -EA SilentlyContinue
            try {
                Remove-Item $installDir -Recurse -Force
            } catch {
                Write-Host "  Could not remove $installDir (a file is still in use). Close SwiftSlate and delete it manually." -ForegroundColor Red
                Write-Host ""
                return
            }
            Write-Host ""
            Write-Host "  Uninstalled." -ForegroundColor Green
            Write-Host ""
            return
        } elseif ($action -ne "1") {
            Write-Host "  Cancelled." -ForegroundColor DarkGray
            Write-Host ""
            return
        }
        Stop-SwiftSlate
        Write-Host ""
    }

    # --- Ensure install directory ---
    if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }

    # --- Python runtime ---
    $pythonwExe = Get-Pythonw

    # --- App files: download to temp, verify, then move into place ---
    Write-Host "  Downloading..." -ForegroundColor DarkGray
    $tempPyw = Join-Path $env:TEMP "swiftslate-download.tmp"
    Get-File "SwiftSlate.pyw" $tempPyw
    Move-Item -Path $tempPyw -Destination (Join-Path $installDir "SwiftSlate.pyw") -Force

    # commands.json: only on fresh install, to preserve user customizations; non-fatal
    $commandsPath = Join-Path $installDir "commands.json"
    if (-not (Test-Path $commandsPath)) {
        try {
            Get-File "commands.json" $commandsPath
        } catch {
            Write-Host "  Could not download commands.json - continuing with built-in commands." -ForegroundColor DarkGray
        }
    }

    # --- Config (only on fresh install) ---
    $configPath = Join-Path $installDir "config.json"
    if (-not (Test-Path $configPath)) {
        Write-Host ""
        Write-Host "  Provider:" -ForegroundColor DarkGray
        Write-Host "  [1] Gemini  (free tier, recommended)" -ForegroundColor White
        Write-Host "  [2] Groq    (free tier)" -ForegroundColor White
        Write-Host "  [3] Custom  (OpenAI-compatible)" -ForegroundColor White
        Write-Host ""
        $prov = Read-Host "  Choice [default: 1]"

        $cfg = @{ provider = "gemini" }
        if ($prov -eq "2") {
            $cfg.provider = "groq"
            Write-Host ""
            Write-Host "  Key: https://console.groq.com/keys" -ForegroundColor Yellow
            Write-Host ""
            $cfg.api_keys = @(Read-SecureKey "  API Key")
            $cfg.model = Select-Model "groq"
        } elseif ($prov -eq "3") {
            $cfg.provider = "custom"
            Write-Host ""
            $cfg.endpoint = Read-Host "  Endpoint (e.g. http://localhost:11434/v1)"
            Write-Host ""
            $key = Read-SecureKey "  API Key (Enter to skip)"
            if ([string]::IsNullOrWhiteSpace($key)) { $key = "none" }
            $cfg.api_keys = @($key)
            Write-Host ""
            $model = Read-Host "  Model name (Enter for default)"
            if ([string]::IsNullOrWhiteSpace($model)) { $model = "default" }
            $cfg.model = $model
        } else {
            Write-Host ""
            Write-Host "  Key: https://aistudio.google.com/api-keys" -ForegroundColor Yellow
            Write-Host ""
            $cfg.api_keys = @(Read-SecureKey "  API Key")
            $cfg.model = Select-Model "gemini"
        }

        if ([string]::IsNullOrWhiteSpace([string]$cfg.api_keys[0]) -and $cfg.provider -ne "custom") {
            Write-Host "  No API key." -ForegroundColor Red
            Write-Host ""
            return
        }

        # --- Spinner & timing ---
        Write-Host ""
        Write-Host "  Spinner speed (how fast text animates while processing):" -ForegroundColor DarkGray
        Write-Host "  [1] Fast (100ms, high-end PC)" -ForegroundColor White
        Write-Host "  [2] Normal (200ms, recommended)" -ForegroundColor White
        Write-Host "  [3] Slow (300ms, older machines)" -ForegroundColor White
        Write-Host "  [4] Static [Processing...] (safest, no animation)" -ForegroundColor White
        Write-Host ""
        $sp = Read-Host "  Choice [default: 2]"
        $keyDelay = 200
        $spinner = "animated"
        if ($sp -eq "1") { $keyDelay = 100 }
        elseif ($sp -eq "3") { $keyDelay = 300 }
        elseif ($sp -eq "4") { $keyDelay = 200; $spinner = "static" }
        $cfg.key_delay = $keyDelay
        $cfg.spinner = $spinner

        [IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    }

    # --- Startup shortcut ---
    if (-not $isInstalled) {
        Write-Host ""
        $su = Read-Host "  Start on login? [Y/n]"
        if ($su -notmatch "^[nN]$") {
            $sh = New-Object -ComObject WScript.Shell
            $sc = $sh.CreateShortcut($shortcutPath)
            $sc.TargetPath = $pythonwExe
            $sc.Arguments = "`"$(Join-Path $installDir 'SwiftSlate.pyw')`""
            $sc.WorkingDirectory = $installDir
            $sc.Description = "SwiftSlate Desktop"
            $sc.Save()
        }
    } elseif (Test-Path $shortcutPath) {
        # Update: keep the shortcut pointing at the current runtime
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($shortcutPath)
        $sc.TargetPath = $pythonwExe
        $sc.Arguments = "`"$(Join-Path $installDir 'SwiftSlate.pyw')`""
        $sc.WorkingDirectory = $installDir
        $sc.Description = "SwiftSlate Desktop"
        $sc.Save()
    }

    # --- Done ---
    Write-Host ""
    if ($isInstalled) { Write-Host "  Updated." -ForegroundColor Green }
    else { Write-Host "  Installed." -ForegroundColor Green }
    Write-Host ""
    Write-Host "  Config:   $configPath" -ForegroundColor DarkGray
    Write-Host "  Commands: $commandsPath" -ForegroundColor DarkGray
    Write-Host ""

    $start = Read-Host "  Start now? [Y/n]"
    if ($start -notmatch "^[nN]$") {
        Stop-SwiftSlate
        Start-Process $pythonwExe -ArgumentList "`"$(Join-Path $installDir 'SwiftSlate.pyw')`"" -WorkingDirectory $installDir
        Write-Host "  Started." -ForegroundColor Green
    }
    Write-Host ""
} catch {
    Write-Host ""
    Write-Host "  Installer failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_ -is [System.IO.IOException]) {
        Write-Host "  If a file is in use, close SwiftSlate from the tray icon and run the installer again." -ForegroundColor DarkGray
    }
    Write-Host ""
}
