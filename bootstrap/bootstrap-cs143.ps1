<#
.SYNOPSIS
    Bootstraps a Windows machine for CS143 -- no administrator rights needed.

.DESCRIPTION
    - Installs Git (per-user)
    - Helps pin Windows Terminal to the taskbar
    - Installs Python (per-user)
    - Installs Claude Code
    - Adds the Claude Code location ($HOME\.local\bin) to the user PATH

    Everything installs into the current user's profile. Safe to re-run: each
    step checks whether it is already done.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\bootstrap-cs143.ps1
#>
[CmdletBinding()]
param(
    [string]$PythonVersion = '3.13',
    # Don't pause for the taskbar pin (for unattended runs).
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes Invoke-WebRequest much faster
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Helpers -----------------------------------------------------------------
function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Test-Command([string]$Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Add-UserPath([string]$Dir) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries  = @($userPath -split ';' | Where-Object { $_ })
    if ($entries | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }) {
        Write-Host "$Dir is already on PATH."
    } else {
        [Environment]::SetEnvironmentVariable('Path', (($entries + $Dir) -join ';'), 'User')
        Write-Host "Added $Dir to user PATH."
    }
    Update-SessionPath
}

# Tries a per-user winget install. Returns $true on success, $false otherwise
# (winget missing, blocked by policy, or package has no per-user installer).
function Install-WithWinget([string]$Id) {
    if (-not (Test-Command 'winget')) { return $false }
    winget install --id $Id --exact --scope user --silent `
        --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
    $ok = ($LASTEXITCODE -eq 0)
    Update-SessionPath
    return $ok
}

function Invoke-Download([string]$Url, [string]$FileName) {
    $dest = Join-Path $env:TEMP $FileName
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing
    return $dest
}

# --- 1. Git ------------------------------------------------------------------
Write-Step 'Installing Git'
if (Test-Command 'git') {
    Write-Host 'Git is already installed.'
} elseif (-not (Install-WithWinget 'Git.Git')) {
    Write-Host 'winget unavailable for Git; using the Git for Windows installer instead.'
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' `
        -Headers @{ 'User-Agent' = 'cs143-bootstrap' }
    $asset = $release.assets | Where-Object { $_.name -match '^Git-[\d.]+-64-bit\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw 'Could not find the Git for Windows installer in the latest release.' }
    $installer = Invoke-Download $asset.browser_download_url $asset.name
    # /CURRENTUSER installs into %LOCALAPPDATA%\Programs\Git without admin.
    Start-Process -FilePath $installer -Wait -ArgumentList `
        '/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NOCANCEL', '/SP-'
    Update-SessionPath
    if (-not (Test-Command 'git')) { Add-UserPath (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd') }
}

# --- 2. Pin Windows Terminal to the taskbar ---------------------------------
# Windows 11 only allows programmatic taskbar pinning through admin-controlled
# policy, so the script opens Terminal and the student pins it with one click.
Write-Step 'Pinning Windows Terminal to the taskbar'
$terminalAumid = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App'
if (-not (Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue)) {
    Write-Host 'Windows Terminal not found; installing it (per-user).'
    if (-not (Install-WithWinget 'Microsoft.WindowsTerminal')) {
        Write-Warning 'Could not install Windows Terminal. Install it from the Microsoft Store, then pin it.'
    }
}
if (Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue) {
    Start-Process "shell:AppsFolder\$terminalAumid"
    Write-Host 'Windows Terminal has been opened.' -ForegroundColor Yellow
    Write-Host 'Right-click its icon in the taskbar and choose "Pin to taskbar".' -ForegroundColor Yellow
    if (-not $NoWait) { Read-Host 'Press Enter once it is pinned to continue' }
}

# --- 3. Python ---------------------------------------------------------------
Write-Step "Installing Python $PythonVersion"
$pythonDir = Join-Path $env:LOCALAPPDATA ("Programs\Python\Python" + $PythonVersion.Replace('.', ''))
if (Test-Path (Join-Path $pythonDir 'python.exe')) {
    Write-Host "Python $PythonVersion is already installed."
} elseif (-not (Install-WithWinget "Python.Python.$PythonVersion")) {
    Write-Host 'winget unavailable for Python; using the python.org installer instead.'
    # Find the newest patch release of the requested version.
    $index   = Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/' -UseBasicParsing
    $pattern = '^' + [regex]::Escape($PythonVersion) + '\.\d+/$'
    $latest  = $index.Links.href | Where-Object { $_ -match $pattern } |
        ForEach-Object { [version]$_.TrimEnd('/') } | Sort-Object -Descending | Select-Object -First 1
    if (-not $latest) { throw "Could not find a Python $PythonVersion release on python.org." }
    $file      = "python-$latest-amd64.exe"
    $installer = Invoke-Download "https://www.python.org/ftp/python/$latest/$file" $file
    Start-Process -FilePath $installer -Wait -ArgumentList `
        '/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_launcher=0', 'Include_test=0'
}
# Make sure the real python.exe wins over the Microsoft Store "python" alias.
if (Test-Path (Join-Path $pythonDir 'python.exe')) {
    Add-UserPath $pythonDir
    Add-UserPath (Join-Path $pythonDir 'Scripts')
}

# --- 4. Claude Code ----------------------------------------------------------
Write-Step 'Installing Claude Code'
$claudeBin = Join-Path $HOME '.local\bin'
if (Test-Path (Join-Path $claudeBin 'claude.exe')) {
    Write-Host 'Claude Code is already installed.'
} else {
    # Official native installer; installs into the user profile, no admin needed.
    Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' | Invoke-Expression
}

# --- 5. Add $HOME\.local\bin to the user PATH -------------------------------
Write-Step "Adding $claudeBin to PATH"
Add-UserPath $claudeBin

# --- Summary -----------------------------------------------------------------
Write-Step 'Verifying'
foreach ($cmd in 'git', 'python', 'claude') {
    $exe = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($exe -and $exe.Source -notlike '*\WindowsApps\*') {
        $version = & $cmd --version 2>$null | Select-Object -First 1
        Write-Host ("  {0,-7} OK   {1}" -f $cmd, $version) -ForegroundColor Green
    } else {
        Write-Host ("  {0,-7} NOT FOUND (open a new terminal and try again)" -f $cmd) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host 'CS143 setup complete. Open a new terminal so PATH changes take effect.' -ForegroundColor Green
