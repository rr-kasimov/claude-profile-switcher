# The installer: app folder with a private Python, icon, shortcuts, "Installed apps" entry, uninstall.
# install.ps1 runs it with -Install; Windows Settings runs the copy in the app folder with -Uninstall.
param(
    [switch]$Install,
    [switch]$Uninstall,
    [string]$Source,      # the project folder (with claude_profiles.py and windows\)
    [string]$Version = '0.0.0',
    [switch]$Silent,      # no message box on uninstall (used by install.ps1)
    [string]$Log          # set when re-run outside an app container; output goes to this file
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Say-Line([string]$text) {
    if ($Log) { Add-Content -Encoding UTF8 -Path $Log -Value $text } else { Write-Output $text }
}

# Inside a packaged (MSIX) app, e.g. a terminal started by Claude Desktop, Windows redirects
# AppData and HKCU writes into that app's private container, and our processes would die with it.
# In that case run this script again through Task Scheduler, which starts it outside the container.
# Processes started from such an app may have no package identity of their own, so detect the
# redirection itself: a probe file written to LOCALAPPDATA shows up inside some package's LocalCache.
function Test-Redirected {
    $probe = 'cps-probe-' + [guid]::NewGuid().ToString('N')
    $path = Join-Path $env:LOCALAPPDATA $probe
    Set-Content -Path $path -Value '' -ErrorAction SilentlyContinue
    try {
        $real = Get-ChildItem -Directory (Join-Path $env:LOCALAPPDATA 'Packages') -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "LocalCache\Local\$probe") }
        return [bool]$real
    } finally { Remove-Item -Force -ErrorAction SilentlyContinue $path }
}
$packaged = Test-Redirected
if ($packaged -and -not $Log) {
    if (-not $Source) { throw 'Run install.ps1: -Source is required inside an app container' }
    $logFile = Join-Path $Source 'setup.log'
    Remove-Item -Force -ErrorAction SilentlyContinue $logFile
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argList += "-$k" } } else { $argList += @("-$k", "`"$v`"") }
    }
    $argList += @('-Log', "`"$logFile`"")
    # A unique name: a hung earlier run with the same name would make Windows refuse to start this one.
    $task = 'ClaudeProfileSwitcherSetup-' + [guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' ')
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $task
        for ($i = 0; $i -lt 2400; $i++) {  # up to 10 minutes: the Python download can be slow
            Start-Sleep -Milliseconds 250
            if ((Test-Path $logFile) -and (Get-Content -Raw -Encoding UTF8 $logFile) -match 'CPS-(DONE|FAILED)') { break }
        }
    } finally {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $logFile)) { throw 'setup did not start outside the app container' }
    $out = Get-Content -Encoding UTF8 $logFile
    Remove-Item -Force -ErrorAction SilentlyContinue $logFile
    $out | Where-Object { $_ -notmatch '^CPS-' } | Write-Output
    if ($out -contains 'CPS-FAILED') { exit 1 }
    if ($out -notcontains 'CPS-DONE') { throw 'setup timed out' }
    exit 0
}
trap { Say-Line "error: $_"; if ($Log) { Say-Line 'CPS-FAILED' }; exit 1 }
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$Name     = 'Claude Profile Switcher'
$AppDir   = Join-Path $env:LOCALAPPDATA 'ClaudeProfileSwitcher'
$Script   = Join-Path $AppDir 'ClaudeProfileSwitcher.ps1'
$IconPath = Join-Path $AppDir 'app.ico'
$RegKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeProfileSwitcher'
$Links = @(
    @{ Path = Join-Path ([Environment]::GetFolderPath('Desktop')) "$Name.lnk"; Args = '' },
    @{ Path = Join-Path ([Environment]::GetFolderPath('Programs')) "$Name.lnk"; Args = '' },
    @{ Path = Join-Path ([Environment]::GetFolderPath('Startup')) "$Name.lnk"; Args = ' -Tray' }
)

function Stop-App {
    Get-CimInstance Win32_Process |
        Where-Object { $_.ProcessId -ne $PID -and $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*ClaudeProfileSwitcher.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# The Claude logo from the installed Claude Desktop (Store or classic install). It is copied to the
# user's app folder at install time and is not part of this project.
function Get-ClaudeLogo {
    $pkg = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) {
        $png = Join-Path $pkg.InstallLocation 'assets\Square44x44Logo.targetsize-256.png'
        if (Test-Path $png) { return [System.Drawing.Image]::FromFile($png) }
    }
    $exe = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
    if (Test-Path $exe) { return ([System.Drawing.Icon]::ExtractAssociatedIcon($exe)).ToBitmap() }
    return $null
}
$Logo = Get-ClaudeLogo

# App icon (shortcuts, window, tray, Installed apps): the Claude logo with a white badge at the
# bottom right holding terracotta circular "switch" arrows. The bottom-left corner stays free for
# the shortcut arrow Windows draws there.
function Draw-Icon([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'
    $terra = [System.Drawing.Color]::FromArgb(201, 100, 66)
    # Small sizes (tray, 16-32 px) get a bigger badge and thicker arrows, so the sign stays readable.
    $small = $size -le 32
    $logoPart = if ($small) { 0.8 } else { 0.86 }
    if ($Logo) { $g.DrawImage($Logo, 0, 0, $size * $logoPart, $size * $logoPart) }
    else { $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(217, 119, 87))), 0, 0, $size * $logoPart, $size * $logoPart) }
    $d = if ($small) { $size * 0.66 } else { $size * 0.5 }
    $x = $size - $d; $y = $x
    if (-not $small) { $x -= $size * 0.02; $y = $x }
    $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 0, 0, 0))), $x, $y + $size * 0.015, $d, $d)
    $g.FillEllipse([System.Drawing.Brushes]::White, $x, $y, $d, $d)
    $stroke = if ($small) { [Math]::Max(1.6, $d * 0.14) } else { [Math]::Max(1.3, $d * 0.11) }
    $pen = New-Object System.Drawing.Pen($terra, $stroke)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $cx = $x + $d / 2; $cy = $y + $d / 2
    $r = if ($small) { $d * 0.26 } else { $d * 0.27 }
    $head = if ($small) { $d * 0.15 } else { $d * 0.12 }
    foreach ($start in 200, 20) {
        $sweep = 125
        $g.DrawArc($pen, $cx - $r, $cy - $r, 2 * $r, 2 * $r, $start, $sweep)
        $t = ($start + $sweep) * [Math]::PI / 180
        $tx = $cx + $r * [Math]::Cos($t); $ty = $cy + $r * [Math]::Sin($t)
        $back = [Math]::Atan2([Math]::Cos($t), -[Math]::Sin($t)) + [Math]::PI
        foreach ($side in 1, -1) {
            $g.DrawLine($pen, $tx, $ty, $tx + $head * [Math]::Cos($back + $side * 0.6), $ty + $head * [Math]::Sin($back + $side * 0.6))
        }
    }
    $g.Dispose()
    return $bmp
}

# An .ico with PNG frames (supported since Windows Vista).
function Write-Icon([string]$path) {
    $frames = foreach ($size in 16, 20, 24, 32, 48, 256) {
        $ms = New-Object System.IO.MemoryStream
        (Draw-Icon $size).Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        , @($size, $ms.ToArray())
    }
    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($out)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $dim = if ($f[0] -ge 256) { 0 } else { $f[0] }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$f[1].Length); $w.Write([uint32]$offset)
        $offset += $f[1].Length
    }
    foreach ($f in $frames) { $w.Write([byte[]]$f[1]) }
    [System.IO.File]::WriteAllBytes($path, $out.ToArray())
}

# A private copy of the official "embeddable" Python from python.org (no installer, nothing system-wide),
# checked against pinned SHA-256 sums.
$PyVersion = '3.12.10'
$PySha256 = @{
    amd64 = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'
    arm64 = '3065efc3d382d1cda66757ac71ade11904fa6e350f5a97eb74811acd71ba5532'
}
function Install-Python {
    $dir = Join-Path $AppDir 'python'
    $exe = Join-Path $dir 'python.exe'
    $stamp = Join-Path $dir ".version-$PyVersion"
    if ((Test-Path $exe) -and (Test-Path $stamp)) { return $exe }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) "claude-profile-switcher-python-$PyVersion-$arch.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    # Not Say-Line: anything written to the output here would become part of the return value.
    Write-Host "downloading Python $PyVersion ($arch) from python.org"
    Invoke-WebRequest -UseBasicParsing -Uri "https://www.python.org/ftp/python/$PyVersion/python-$PyVersion-embed-$arch.zip" -OutFile $zip
    $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
    if ($hash -ne $PySha256[$arch]) { Remove-Item -Force $zip; throw "Python download checksum mismatch: $hash" }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $dir
    Expand-Archive -Path $zip -DestinationPath $dir
    Remove-Item -Force $zip
    New-Item -ItemType File -Path $stamp | Out-Null
    return $exe
}

function Start-App([string]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $Script)
    if ($extra) { $argList += $extra }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $argList
}

if ($Install) {
    Stop-App
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    Copy-Item -Force (Join-Path $Source 'windows\ClaudeProfileSwitcher.ps1'), (Join-Path $Source 'windows\setup.ps1'), (Join-Path $Source 'claude_profiles.py') $AppDir
    $python = Install-Python
    @{ python = $python; backend = (Join-Path $AppDir 'claude_profiles.py') } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $AppDir 'config.json')
    Write-Icon $IconPath
    # Windows caches shortcut icons by path: give every install its own icon file name.
    Get-ChildItem -Path $AppDir -Filter 'icon-*.ico' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $LinkIcon = Join-Path $AppDir ('icon-' + [DateTime]::Now.Ticks + '.ico')
    Copy-Item -Force $IconPath $LinkIcon
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $AppDir 'logo.png')  # left by earlier builds

    $shell = New-Object -ComObject WScript.Shell
    foreach ($l in $Links) {
        $s = $shell.CreateShortcut($l.Path)
        $s.TargetPath = 'powershell.exe'
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`"$($l.Args)"
        $s.WorkingDirectory = $AppDir
        $s.IconLocation = "$LinkIcon,0"
        $s.Description = 'Switch Claude accounts'
        $s.Save()
    }

    New-Item -Force -Path $RegKey | Out-Null
    $uninstallCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AppDir\setup.ps1`" -Uninstall"
    $values = @{
        DisplayName = $Name; DisplayVersion = $Version; Publisher = 'Claude Profile Switcher contributors'
        DisplayIcon = $LinkIcon; InstallLocation = $AppDir; UninstallString = $uninstallCmd; QuietUninstallString = $uninstallCmd
    }
    foreach ($k in $values.Keys) { Set-ItemProperty -Path $RegKey -Name $k -Value $values[$k] }
    Set-ItemProperty -Path $RegKey -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty -Path $RegKey -Name NoRepair -Value 1 -Type DWord

    Start-Process -FilePath "$env:WINDIR\System32\ie4uinit.exe" -ArgumentList '-show' -WindowStyle Hidden -ErrorAction SilentlyContinue
    Start-App '-Tray'
    Say-Line "installed: $AppDir"
}
elseif ($Uninstall) {
    Stop-App
    foreach ($l in $Links) { Remove-Item -Force -ErrorAction SilentlyContinue $l.Path }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $RegKey
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $AppDir
    $store = Join-Path $env:USERPROFILE '.claude-profiles'
    # The language chosen in the app's settings, otherwise the one of Windows.
    $lang = try { (Get-Content -Raw -Encoding UTF8 (Join-Path $store '.settings.json') -ErrorAction Stop | ConvertFrom-Json).language } catch { $null }
    $ru = if ($lang -in 'en', 'ru') { $lang -eq 'ru' } else { (Get-UICulture).TwoLetterISOLanguageName -eq 'ru' }
    $msg = if ($ru) { "$Name удалён. Сохранённые входы остались в $store." }
           else { "$Name was removed. Saved sign-ins remain in $store." }
    if (-not $Silent) { [void][System.Windows.Forms.MessageBox]::Show($msg, $Name) }
    Say-Line 'uninstalled'
}
if ($Log) { Say-Line 'CPS-DONE' }
