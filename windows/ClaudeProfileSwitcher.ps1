# Claude Profile Switcher: tray app to sign Claude Desktop and Claude Code (Windows and WSL) into
# one of several saved e-mail profiles. File work is done by claude_profiles.py (bundled Python).
param([switch]$Tray)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- single instance: a second launch only brings the window up ----------
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeProfileSwitcher', [ref]$created)
$showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\ClaudeProfileSwitcherShow')
if (-not $created) {
    if (-not $Tray) { [void]$showEvent.Set() }
    exit
}

# ---------- settings ----------
# config.json (written by setup.ps1): the Python to run and the path of claude_profiles.py.
$Config = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'config.json') | ConvertFrom-Json

# ---------- strings ----------
$Strings = @{ ru = @{
    Title = 'Профили Claude'; Cancel = 'Отмена'; Email = 'Аккаунт'; Active = '● активен'; Saved = 'сохранён'; Pending = 'ждёт входа'
    SyncSessions = 'Синхронизировать сессии'; Accounts = 'Аккаунты'; Settings = 'Настройки'; SignInTo = 'Входить в'; AddEmail = 'Добавить аккаунт'
    DeskTip = 'При переключении Claude Desktop перезапускается'; SyncTip = 'При переключении Claude Desktop объединять его сессии Code всех сохранённых аккаунтов'
    SignIn = 'Войти'; ActiveBtn = 'Активен'; Remove = 'Удалить'; Open = 'Открыть окно'; Quit = 'Выход'
    NotSignedIn = 'не выполнен вход'; UnknownEmail = 'аккаунт не определён'; Asleep = 'WSL не запущен'
    NewEmailPrompt = 'Почта нового аккаунта:'
    AskDeskEmail = 'Под каким аккаунтом сейчас вошёл Claude Desktop? Введите его почту — вход сохранится в этот аккаунт.'
    NoSaved = 'Для {0} нет сохранённого входа в {1}. Выйти из текущего и войти заново?'
    DeskRelogin = 'Claude Desktop перезапустится на экран входа. Продолжить?'
    RemoveAsk = 'Удалить сохранённые входы для {0}?'
    CantStop = 'Не удалось закрыть Claude Desktop.'; NoReply = 'Нет ответа от бэкенда: {0}'
    Loading = 'Загрузка профилей…'; Language = 'Язык'; LangAuto = 'Как в Windows'
}; en = @{
    Title = 'Claude Profiles'; Cancel = 'Cancel'; Email = 'Account'; Active = '● active'; Saved = 'saved'; Pending = 'awaiting sign-in'
    SyncSessions = 'Sync sessions'; Accounts = 'Accounts'; Settings = 'Settings'; SignInTo = 'Sign in to'; AddEmail = 'Add account'
    DeskTip = 'Claude Desktop restarts when switching'; SyncTip = 'On a Claude Desktop switch, merge its Code sessions of all saved accounts'
    SignIn = 'Sign in'; ActiveBtn = 'Active'; Remove = 'Remove'; Open = 'Open window'; Quit = 'Quit'
    NotSignedIn = 'signed out'; UnknownEmail = 'unknown account'; Asleep = 'WSL not running'
    NewEmailPrompt = 'E-mail of the new account:'
    AskDeskEmail = 'Which account is Claude Desktop signed in with now? Enter its e-mail; the sign-in will be saved to that account.'
    NoSaved = 'No saved {1} sign-in for {0}. Sign out of the current one and sign in again?'
    DeskRelogin = 'Claude Desktop will restart to the sign-in screen. Continue?'
    RemoveAsk = 'Remove saved sign-ins for {0}?'
    CantStop = 'Could not close Claude Desktop.'; NoReply = 'No reply from the backend: {0}'
    Loading = 'Loading profiles…'; Language = 'Language'; LangAuto = 'Same as Windows'
} }
$LangCodes = @('auto', 'en', 'ru')  # the order of the language list in the settings
function Resolve-Language([string]$choice) {
    if ($choice -in 'en', 'ru') { return $choice }
    if ((Get-UICulture).TwoLetterISOLanguageName -eq 'ru') { return 'ru' }
    return 'en'
}
# The saved choice is read from the settings file directly: the window needs its texts before the
# backend has answered. Changes go through the backend (`set language ...`).
$StoreDir = if ($env:CLAUDE_PROFILES_HOME) { $env:CLAUDE_PROFILES_HOME } else { Join-Path $env:USERPROFILE '.claude-profiles' }
$script:LangChoice = 'auto'
try {
    $savedSettings = Get-Content -Raw -Encoding UTF8 (Join-Path $StoreDir '.settings.json') -ErrorAction Stop | ConvertFrom-Json
    if ($savedSettings.language -in $LangCodes) { $script:LangChoice = $savedSettings.language }
} catch { }
$script:Txt = $Strings[(Resolve-Language $script:LangChoice)]

# ---------- backend ----------
function Parse-Reply([string]$raw) {
    $line = ($raw -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $line) { return [pscustomobject]@{ ok = $false; error = ($Txt.NoReply -f $raw.Trim()) } }
    return $line | ConvertFrom-Json
}

function Invoke-Backend([string[]]$CmdArgs) {
    return Parse-Reply (& $Config.python $Config.backend @CmdArgs 2>&1 | Out-String)
}

# Arguments for Start-Process / ProcessStartInfo: quote those with spaces.
function Join-Args([string[]]$list) {
    return ($list | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
}

# Status is polled in the background so the UI never freezes and always shows the current sign-in.
$script:Poll = $null; $script:PollOut = $null; $script:LastPoll = [datetime]::MinValue
function Start-Poll {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Config.python
    $psi.Arguments = Join-Args @($Config.backend, 'status')
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $script:Poll = [System.Diagnostics.Process]::Start($psi)
    $script:PollOut = $script:Poll.StandardOutput.ReadToEndAsync()
}

# ---------- Claude Desktop process ----------
function Find-DesktopLauncher {
    $pkg = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) {
        $app = Get-StartApps | Where-Object { $_.AppID -like "$($pkg.PackageFamilyName)!*" } | Select-Object -First 1
        if ($app) { return "shell:AppsFolder\$($app.AppID)" }
    }
    $exe = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
    if (Test-Path $exe) { return $exe }
    return $null
}
$DesktopLauncher = Find-DesktopLauncher

# Only the Desktop app: a Windows build of Claude Code is also named claude.exe.
function Get-DesktopProcess {
    Get-Process -Name Claude -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like '*\WindowsApps\Claude_*' -or $_.Path -like '*\AnthropicClaude\*' }
}

# First ask Claude Desktop to close, so it can finish writing its files. It runs ~10 processes;
# whatever is still there after 5 seconds (or keeps being restarted by the main one) is stopped by
# force for up to 30 seconds more. The backend repairs a cookie database left mid-write.
function Stop-Desktop {
    @(Get-DesktopProcess) | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
        ForEach-Object { [void]$_.CloseMainWindow() }
    for ($i = 0; $i -lt 140; $i++) {
        $left = @(Get-DesktopProcess)
        if (-not $left.Count) { Start-Sleep -Milliseconds 700; return $true }
        if ($i -ge 20) { $left | Stop-Process -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Start-Desktop {
    if ($DesktopLauncher -like 'shell:*') { Start-Process explorer.exe $DesktopLauncher }
    elseif ($DesktopLauncher) { Start-Process $DesktopLauncher }
}

# ---------- dialogs ----------
function Owner {
    $f = New-Object System.Windows.Forms.Form
    $f.TopMost = $true; $f.ShowInTaskbar = $false
    return $f
}
function Say([string]$text, [string]$icon = 'Warning') {
    [void][System.Windows.Forms.MessageBox]::Show((Owner), $text, $Txt.Title, 'OK', $icon)
}
function Ask([string]$text) {
    return [System.Windows.Forms.MessageBox]::Show((Owner), $text, $Txt.Title, 'YesNo', 'Question') -eq 'Yes'
}
function Ask-Email([string]$prompt) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Txt.Title; $dlg.TopMost = $true; $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $dlg.ClientSize = New-Object System.Drawing.Size(480, 150)
    if ($form.Icon) { $dlg.Icon = $form.Icon }
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $prompt; $label.Location = New-Object System.Drawing.Point(16, 14)
    $label.Size = New-Object System.Drawing.Size(448, 44)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 13)
    $box.Location = New-Object System.Drawing.Point(16, 60); $box.Width = 448
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.DialogResult = 'OK'
    $ok.Size = New-Object System.Drawing.Size(100, 34); $ok.Location = New-Object System.Drawing.Point(256, 104)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = $Txt.Cancel; $cancel.DialogResult = 'Cancel'
    $cancel.Size = New-Object System.Drawing.Size(100, 34); $cancel.Location = New-Object System.Drawing.Point(364, 104)
    $dlg.Controls.AddRange(@($label, $box, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Add_Shown({ $dlg.Activate(); $box.Focus() })
    $result = $dlg.ShowDialog()
    $value = $box.Text.Trim().ToLower()
    $dlg.Dispose()
    if ($result -ne 'OK') { return '' }
    return $value
}

# ---------- actions ----------
# Runs a Desktop backend call with the app closed; asks for the e-mail of an unknown current sign-in.
# Afterwards Desktop is started again if it was running, or always with -Start (a sign-in screen).
function Invoke-DesktopOp([string[]]$CmdArgs, [switch]$Start) {
    $wasRunning = [bool]@(Get-DesktopProcess).Count
    if (-not (Stop-Desktop)) { return [pscustomobject]@{ ok = $false; error = $Txt.CantStop } }
    $r = Invoke-Backend $CmdArgs
    if (-not $r.ok -and $r.error -like 'unknown e-mail*') {
        $e = Ask-Email $Txt.AskDeskEmail
        if ($e) {
            $saved = Invoke-Backend @('save', '--target', 'desktop', '--email', $e)
            $r = if ($saved.ok) { Invoke-Backend $CmdArgs } else { $saved }
        }
    }
    if ($wasRunning -or $Start) { Start-Desktop }
    return $r
}

# Opens the target's own sign-in (`claude auth login`) in a console.
function Start-Login($t) {
    $cmd = @($t.login)
    if ($cmd.Count) { Start-Process $cmd[0] -ArgumentList (Join-Args ($cmd | Select-Object -Skip 1)) }
}

function Report([object[]]$results) {
    $errs = @($results | Where-Object { $_ -and -not $_.ok } | ForEach-Object { $_.error })
    if ($errs.Count) { Say ($errs -join "`n") }
    Request-Refresh
}

function Checked-Targets {
    return @($script:State.targets | Where-Object { $script:Checks[$_.id] -and $script:Checks[$_.id].Checked })
}

function Switch-Profile([string]$e) {
    $p = $script:State.profiles | Where-Object { $_.email -eq $e } | Select-Object -First 1
    $results = @()
    foreach ($t in (Checked-Targets)) {
        # Already signed in with this e-mail: leave that app alone (no re-login, no Desktop restart).
        if ($t.signed_in -and $t.email -eq $e) { continue }
        $saved = @($p.saved) -contains $t.id
        if ($t.kind -eq 'desktop') {
            if ($saved) { $results += Invoke-DesktopOp @('switch', $e, '--target', 'desktop') }
            elseif (Ask ($Txt.NoSaved -f $e, $t.label)) { $results += Invoke-DesktopOp @('logout', '--target', 'desktop', '--email', $e) -Start }
        } elseif ($saved) {
            $results += Invoke-Backend @('switch', $e, '--target', $t.id)
        } elseif (Ask ($Txt.NoSaved -f $e, $t.label)) {
            $r = Invoke-Backend @('logout', '--target', $t.id); $results += $r
            if ($r.ok) { Start-Login $t }
        }
    }
    Report $results
}

function New-Profile {
    $e = Ask-Email $Txt.NewEmailPrompt
    if (-not $e) { return }
    $results = @()
    foreach ($t in (Checked-Targets)) {
        if ($t.kind -eq 'desktop') {
            if (Ask $Txt.DeskRelogin) { $results += Invoke-DesktopOp @('logout', '--target', 'desktop', '--email', $e) -Start }
        } else {
            $r = Invoke-Backend @('logout', '--target', $t.id); $results += $r
            if ($r.ok) { Start-Login $t }
        }
    }
    Report $results
}

function Remove-Profile([string]$e) {
    if (-not (Ask ($Txt.RemoveAsk -f $e))) { return }
    Report @(Invoke-Backend @('remove', $e))
}

# ---------- window ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = $Txt.Title
$AppIcon = Join-Path $PSScriptRoot 'app.ico'
if (Test-Path $AppIcon) { $form.Icon = New-Object System.Drawing.Icon($AppIcon) }
$form.ClientSize = New-Object System.Drawing.Size(760, 440)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.BackColor = [System.Drawing.Color]::White
$form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false

$ColGreen = [System.Drawing.Color]::FromArgb(22, 163, 74)
$ColRed = [System.Drawing.Color]::FromArgb(220, 38, 38)
# One type scale: Segoe UI 10 for everything, Semibold 11 for section titles.
$ColText = [System.Drawing.Color]::FromArgb(32, 32, 32)
$ColMuted = [System.Drawing.Color]::FromArgb(96, 96, 96)
$FontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$form.ForeColor = $ColText
$ColLine = [System.Drawing.Color]::FromArgb(236, 236, 236)
$ColHover = [System.Drawing.Color]::FromArgb(246, 248, 250)

# Row actions are painted as pill buttons: green "Sign in" (grey "Active" when the e-mail is already
# signed in everywhere) and an outlined "Remove" with red text.
$FontButton = New-Object System.Drawing.Font('Segoe UI', 9)
function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, $r, $r, 180, 90); $p.AddArc($x + $w - $r, $y, $r, $r, 270, 90)
    $p.AddArc($x + $w - $r, $y + $h - $r, $r, $r, 0, 90); $p.AddArc($x, $y + $h - $r, $r, $r, 90, 90)
    $p.CloseFigure(); return $p
}
function Draw-Pill($g, $bounds, [string]$kind, [bool]$hover) {
    $w = 76; $h = 28
    $x = [int]($bounds.X + ($bounds.Width - $w) / 2); $y = [int]($bounds.Y + ($bounds.Height - $h) / 2)
    $path = New-RoundRect $x $y ($w - 1) ($h - 1) 10
    switch ($kind) {
        'login' {
            $fill = if ($hover) { [System.Drawing.Color]::FromArgb(21, 128, 61) } else { $ColGreen }
            $g.FillPath((New-Object System.Drawing.SolidBrush $fill), $path)
            $label = $Txt.SignIn; $fore = [System.Drawing.Color]::White
        }
        'login-done' {
            $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(243, 243, 243))), $path)
            $label = $Txt.ActiveBtn; $fore = $ColMuted
        }
        default {
            if ($hover) { $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(254, 242, 242))), $path) }
            $g.DrawPath((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(214, 214, 214))), $path)
            $label = $Txt.Remove; $fore = $ColRed
        }
    }
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString($label, $FontButton, (New-Object System.Drawing.SolidBrush $fore), (New-Object System.Drawing.RectangleF($x, $y, $w, $h)), $fmt)
}

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false; $grid.AllowUserToResizeColumns = $false; $grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false
$grid.BackgroundColor = [System.Drawing.Color]::White; $grid.BorderStyle = 'None'
# No grid lines and no focus frame: CellPainting draws each row and the line under it.
$grid.CellBorderStyle = 'None'; $grid.GridColor = $ColLine
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersBorderStyle = 'None'; $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'; $grid.ColumnHeadersHeight = 32
$grid.ScrollBars = 'None'
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $ColMuted
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$grid.ColumnHeadersDefaultCellStyle.Font = $form.Font
$grid.ColumnHeadersDefaultCellStyle.WrapMode = 'False'
$grid.DefaultCellStyle.ForeColor = $ColText
$grid.DefaultCellStyle.SelectionForeColor = $ColText
$grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
$grid.RowTemplate.Height = 40
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
# Selection has no meaning here (actions are per row), so it is invisible; hover highlights the row.
$grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::White
# Columns: e-mail, one per target found by the backend (Desktop, Claude Code Windows / WSL ...), actions.
$EmailWidth = 260; $ActionWidth = 88
function Build-Columns($targetList) {
    $grid.Columns.Clear()
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = 'email'; $col.HeaderText = $Txt.Email; $col.SortMode = 'NotSortable'; $col.AutoSizeMode = 'Fill'
    [void]$grid.Columns.Add($col)
    foreach ($t in $targetList) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = 't:' + $t.id; $col.HeaderText = $t.label; $col.SortMode = 'NotSortable'
        $col.Width = [Math]::Max(140, [System.Windows.Forms.TextRenderer]::MeasureText($t.label, $form.Font).Width + 24)
        [void]$grid.Columns.Add($col)
    }
    foreach ($name in 'login', 'remove') {
        $col = New-Object System.Windows.Forms.DataGridViewImageColumn
        $col.Name = $name; $col.HeaderText = ''; $col.Width = $ActionWidth
        $col.DefaultCellStyle.NullValue = $null  # buttons are painted in CellPainting, cells stay empty
        [void]$grid.Columns.Add($col)
    }
}
Build-Columns @()
# A 1 px light frame around the table: a panel in the line colour with the grid inside.
$tableBox = New-Object System.Windows.Forms.Panel
$tableBox.Location = New-Object System.Drawing.Point(16, 52)
$tableBox.Size = New-Object System.Drawing.Size(728, 120)
$tableBox.BackColor = [System.Drawing.Color]::FromArgb(222, 222, 222)
$tableBox.Padding = New-Object System.Windows.Forms.Padding(1)
$tableBox.Controls.Add($grid)

# Until the first status arrives the table shows a loader instead of empty rows.
$loader = New-Object System.Windows.Forms.Panel
$loader.Dock = 'Fill'; $loader.BackColor = [System.Drawing.Color]::White
$loaderText = New-Object System.Windows.Forms.Label
$loaderText.Text = $Txt.Loading; $loaderText.AutoSize = $false; $loaderText.TextAlign = 'MiddleCenter'
$loaderText.ForeColor = $ColMuted; $loaderText.Size = New-Object System.Drawing.Size(600, 24)
$loaderBar = New-Object System.Windows.Forms.ProgressBar
$loaderBar.Style = 'Marquee'; $loaderBar.MarqueeAnimationSpeed = 30; $loaderBar.Size = New-Object System.Drawing.Size(220, 6)
$loader.Controls.AddRange(@($loaderText, $loaderBar))
$loader.Add_Resize({
    $loaderText.Width = $loader.ClientSize.Width
    $top = [int](($loader.ClientSize.Height - 24 - 10 - $loaderBar.Height) / 2)
    $loaderText.Location = New-Object System.Drawing.Point(0, $top)
    $loaderBar.Location = New-Object System.Drawing.Point([int](($loader.ClientSize.Width - $loaderBar.Width) / 2), ($top + 34))
})
$tableBox.Controls.Add($loader)
# Not $loader.Visible: that is false whenever the window is hidden.
$script:Loaded = $false
$loader.BringToFront()
$form.Controls.Add($tableBox)

$lblAccounts = New-Object System.Windows.Forms.Label
$lblAccounts.Text = $Txt.Accounts; $lblAccounts.AutoSize = $true
$lblAccounts.Font = $FontTitle
$lblAccounts.Location = New-Object System.Drawing.Point(14, 18)
$form.Controls.Add($lblAccounts)
# PowerShell hands a Bitmap to the grid wrapped in a PSObject, which image cells cannot format
# (FormatException dialog, red crosses). So the cells stay empty and the icons are painted directly.
$grid.Add_DataError({ param($s, $ev) $ev.ThrowException = $false })
$script:HoverRow = -1; $script:HoverCol = -1
$grid.Add_CellPainting({ param($s, $ev)
    if ($ev.RowIndex -lt 0 -and $ev.ColumnIndex -ge 0) {
        # Header: default paint plus a line under it.
        $ev.Paint($ev.CellBounds, 'All')
        $b = $ev.CellBounds
        $ev.Graphics.DrawLine((New-Object System.Drawing.Pen($ColLine)), $b.Left, $b.Bottom - 1, $b.Right, $b.Bottom - 1)
        $ev.Handled = $true
        return
    }
    if ($ev.RowIndex -lt 0 -or $ev.ColumnIndex -lt 0) { return }
    # Selection has no meaning here: a selected row looks like any other (hover only changes the background).
    $back = if ($ev.RowIndex -eq $script:HoverRow) { $ColHover } else { [System.Drawing.Color]::White }
    $ev.CellStyle.BackColor = $back; $ev.CellStyle.SelectionBackColor = $back
    $ev.CellStyle.SelectionForeColor = $ev.CellStyle.ForeColor
    $name = $grid.Columns[$ev.ColumnIndex].Name
    $b = $ev.CellBounds
    if ($name -in 'login', 'remove') {
        $ev.PaintBackground($b, $false)
        $kind = if ($name -eq 'remove') { 'remove' } elseif ($grid.Rows[$ev.RowIndex].Tag -eq 'done') { 'login-done' } else { 'login' }
        $ev.Graphics.SmoothingMode = 'AntiAlias'; $ev.Graphics.TextRenderingHint = 'ClearTypeGridFit'
        $hover = $ev.RowIndex -eq $script:HoverRow -and $ev.ColumnIndex -eq $script:HoverCol
        Draw-Pill $ev.Graphics $b $kind $hover
        $ev.Graphics.SmoothingMode = 'None'
    } else {
        $ev.Paint($b, [System.Windows.Forms.DataGridViewPaintParts]'Background, ContentForeground')
    }
    # The line between rows; the last row closes on the table frame.
    if ($ev.RowIndex -lt $grid.Rows.Count - 1) {
        $pen = New-Object System.Drawing.Pen($ColLine)
        $ev.Graphics.DrawLine($pen, $b.Left, $b.Bottom - 1, $b.Right, $b.Bottom - 1); $pen.Dispose()
    }
    $ev.Handled = $true
})

$tips = New-Object System.Windows.Forms.ToolTip

# Settings block, separated from the table by a line.
$separator = New-Object System.Windows.Forms.Label
$separator.AutoSize = $false; $separator.BackColor = $ColLine
$separator.Size = New-Object System.Drawing.Size(728, 1)
$form.Controls.Add($separator)

$lblSettings = New-Object System.Windows.Forms.Label
$lblSettings.Text = $Txt.Settings; $lblSettings.AutoSize = $true
$lblSettings.Font = $FontTitle
$form.Controls.Add($lblSettings)

function New-Check([string]$text, [int]$x, [int]$y, [string]$tip) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text; $c.Checked = $true; $c.AutoSize = $true
    $c.Location = New-Object System.Drawing.Point($x, $y)
    if ($tip) { $tips.SetToolTip($c, $tip) }
    $form.Controls.Add($c); return $c
}
# Where "Sign in" (and the tray menu) signs in: one checkbox per target, built with the columns.
$lblSignInTo = New-Object System.Windows.Forms.Label
$lblSignInTo.Text = $Txt.SignInTo; $lblSignInTo.AutoSize = $true; $lblSignInTo.Font = $FontTitle
$form.Controls.Add($lblSignInTo)
$script:Checks = @{}
function Build-Checks($targetList, $profiles) {
    $old = $script:Checks; $script:Checks = @{}
    foreach ($c in $old.Values) { $form.Controls.Remove($c); $c.Dispose() }
    foreach ($t in $targetList) {
        $tip = if ($t.kind -eq 'desktop') { $Txt.DeskTip } else { '' }
        $c = New-Check $t.label 0 0 $tip
        # A target nobody uses yet (signed out, no saved sign-in) starts unchecked.
        $c.Checked = if ($old.ContainsKey($t.id)) { $old[$t.id].Checked }
                     else { [bool]$t.signed_in -or [bool](@($profiles | Where-Object { @($_.saved) -contains $t.id }).Count) }
        # The "Active" state of a row depends on which targets are checked: redraw on change.
        $c.Add_CheckedChanged({ $script:StateRaw = $null; Request-Refresh })
        $script:Checks[$t.id] = $c
    }
}
# Setting kept by the backend: merge Desktop Code sessions of all saved accounts on a Desktop switch.
$chkSync = New-Check $Txt.SyncSessions 0 0 $Txt.SyncTip
$script:Applying = $false
$lblLang = New-Object System.Windows.Forms.Label
$lblLang.AutoSize = $true
$form.Controls.Add($lblLang)
$cmbLang = New-Object System.Windows.Forms.ComboBox
$cmbLang.DropDownStyle = 'DropDownList'; $cmbLang.Width = 170
$form.Controls.Add($cmbLang)
$cmbLang.Add_SelectedIndexChanged({
    if ($script:Applying -or $cmbLang.SelectedIndex -lt 0) { return }
    $choice = $LangCodes[$cmbLang.SelectedIndex]
    if ($choice -eq $script:LangChoice) { return }
    $r = Invoke-Backend @('set', 'language', $choice)
    if (-not $r.ok) { Say $r.error; return }
    Set-Language $choice
})
$chkSync.Add_CheckedChanged({
    if ($script:Applying) { return }
    $value = if ($chkSync.Checked) { 'on' } else { 'off' }
    Report @(Invoke-Backend @('set', 'sync-sessions', $value))
})

# Errors only; the table already shows who is signed in where.
$status = New-Object System.Windows.Forms.Label
$status.AutoSize = $false; $status.Size = New-Object System.Drawing.Size(320, 22); $status.TextAlign = 'MiddleLeft'
$status.ForeColor = $ColRed
$form.Controls.Add($status)

# Top-down layout: the table is as tall as its rows, the window as wide as its columns.
function Layout-Window {
    $targetWidth = 0
    foreach ($col in $grid.Columns) { if ($col.Name -like 't:*') { $targetWidth += $col.Width } }
    $tableWidth = [Math]::Max(728, $EmailWidth + $targetWidth + 2 * $ActionWidth + 2)
    $formWidth = $tableWidth + 32
    $rows = if (-not $script:Loaded) { 3 } else { [Math]::Max(1, $grid.Rows.Count) }
    $tableBox.Size = New-Object System.Drawing.Size($tableWidth, ($grid.ColumnHeadersHeight + $rows * $grid.RowTemplate.Height + 2))
    $btnNew.Location = New-Object System.Drawing.Point(($formWidth - 16 - $btnNew.Width), 13)
    $separator.Width = $tableWidth
    $y = $tableBox.Bottom + 28
    $separator.Location = New-Object System.Drawing.Point(16, ($y - 14))
    # Two blocks side by side: where to sign in (left) and settings (right).
    $right = [int]($formWidth / 2)
    $lblSignInTo.Location = New-Object System.Drawing.Point(14, $y)
    $lblSettings.Location = New-Object System.Drawing.Point(($right - 2), $y)
    $y += 30
    $chkSync.Location = New-Object System.Drawing.Point($right, $y)
    $lblLang.Location = New-Object System.Drawing.Point(($right - 2), ($y + 35))
    $cmbLang.Location = New-Object System.Drawing.Point(($right + $lblLang.Width + 8), ($y + 31))
    $status.Location = New-Object System.Drawing.Point($right, ($y + 64))
    $rowY = $y
    foreach ($t in @($script:State.targets)) {
        if (-not $t) { continue }
        $script:Checks[$t.id].Location = New-Object System.Drawing.Point(16, $rowY); $rowY += 28
    }
    $form.ClientSize = New-Object System.Drawing.Size($formWidth, ([Math]::Max($rowY, $y + 92) + 12))
    $grid.Invalidate()
}

$btnNew = New-Object System.Windows.Forms.Button
$btnNew.Text = '+  ' + $Txt.AddEmail; $btnNew.Size = New-Object System.Drawing.Size(170, 30)
$btnNew.Location = New-Object System.Drawing.Point(574, 13)
$btnNew.FlatStyle = 'Flat'; $btnNew.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
$btnNew.FlatAppearance.MouseOverBackColor = $ColHover; $btnNew.BackColor = [System.Drawing.Color]::White; $btnNew.Cursor = 'Hand'
$form.Controls.Add($btnNew)
$btnNew.Add_Click({ New-Profile })
# Texts of the window in the current language; rows, columns and the menu are rebuilt from the state.
function Apply-Texts {
    $form.Text = $Txt.Title
    $lblAccounts.Text = $Txt.Accounts; $lblSettings.Text = $Txt.Settings; $lblSignInTo.Text = $Txt.SignInTo
    $btnNew.Text = '+  ' + $Txt.AddEmail
    $chkSync.Text = $Txt.SyncSessions; $tips.SetToolTip($chkSync, $Txt.SyncTip)
    $lblLang.Text = $Txt.Language
    if (-not $script:Loaded -and $loaderBar.Visible) { $loaderText.Text = $Txt.Loading }
    $script:Applying = $true
    $cmbLang.Items.Clear()
    [void]$cmbLang.Items.AddRange([object[]]@($Txt.LangAuto, 'English', 'Русский'))
    $cmbLang.SelectedIndex = [Math]::Max(0, [array]::IndexOf($LangCodes, $script:LangChoice))
    $script:Applying = $false
    Layout-Window
}
function Set-Language([string]$choice) {
    $script:LangChoice = $choice
    $script:Txt = $Strings[(Resolve-Language $choice)]
    Apply-Texts
    # Columns, checkboxes, cells, tray menu and tooltip are rebuilt by the next status.
    $script:TargetIds = $null; $script:StateRaw = $null
    if ($script:State) { Build-Menu }
    Request-Refresh
}
Apply-Texts

# Row icons: sign in / remove (Remove-Profile asks for confirmation). Double click on a row signs in too.
$grid.Add_CellClick({ param($s, $ev)
    if ($ev.RowIndex -lt 0) { return }
    $e = [string]$grid.Rows[$ev.RowIndex].Cells['email'].Value
    switch ($grid.Columns[$ev.ColumnIndex].Name) {
        'login' { if ($grid.Rows[$ev.RowIndex].Tag -ne 'done') { Switch-Profile $e } }
        'remove' { Remove-Profile $e }
    }
})
$grid.Add_CellDoubleClick({ param($s, $ev)
    if ($ev.RowIndex -lt 0 -or $grid.Columns[$ev.ColumnIndex].Name -in 'login', 'remove') { return }
    Switch-Profile ([string]$grid.Rows[$ev.RowIndex].Cells['email'].Value)
})
$grid.Add_CellMouseEnter({ param($s, $ev)
    $grid.Cursor = if ($ev.RowIndex -ge 0 -and $grid.Columns[$ev.ColumnIndex].Name -in 'login', 'remove') { 'Hand' } else { 'Default' }
    if ($ev.RowIndex -ne $script:HoverRow -or $ev.ColumnIndex -ne $script:HoverCol) { $script:HoverRow = $ev.RowIndex; $script:HoverCol = $ev.ColumnIndex; $grid.Invalidate() }
})
$grid.Add_MouseLeave({ $script:HoverRow = -1; $script:HoverCol = -1; $grid.Cursor = 'Default'; $grid.Invalidate() })
# Closing the window keeps the app in the tray.
$form.Add_FormClosing({ param($s, $ev) if (-not $script:Quitting) { $ev.Cancel = $true; $form.Hide() } })

function Show-Window {
    $form.Show(); $form.WindowState = 'Normal'
    # Windows does not let a background process take focus; a short TopMost brings the window up.
    $form.TopMost = $true; $form.Activate(); $form.TopMost = $false
    Request-Refresh
}

# ---------- tray ----------
$notify = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu
# Left click opens the window; right click shows the menu (NotifyIcon does that by itself).
# After a menu item is clicked Windows may also send that mouse-up to the icon; ignore it.
$script:MenuClosedAt = [datetime]::MinValue
$notify.Add_MouseUp({ param($s, $ev)
    if ($ev.Button -eq 'Left' -and ([datetime]::Now - $script:MenuClosedAt).TotalMilliseconds -gt 400) { Show-Window }
})

# Tray icon: the same app icon as the shortcuts (Claude logo with a switch badge), drawn by setup.ps1.
$notify.Icon = if (Test-Path $AppIcon) { New-Object System.Drawing.Icon($AppIcon, [System.Windows.Forms.SystemInformation]::SmallIconSize) }
               else { [System.Drawing.SystemIcons]::Application }

$RadioDot = New-Object System.Drawing.Bitmap(16, 16)
$dotGraphics = [System.Drawing.Graphics]::FromImage($RadioDot)
$dotGraphics.SmoothingMode = 'AntiAlias'
$dotGraphics.FillEllipse([System.Drawing.Brushes]::Black, 4, 4, 8, 8)
$dotGraphics.Dispose()

function Build-Menu {
    $menu.Items.Clear()
    $s = $script:State
    if ($s) {
        # Active e-mails get a radio dot. When targets are signed in with different e-mails, each
        # active e-mail also lists the targets it is active in.
        $signed = @($s.targets | Where-Object { $_.signed_in -and $_.email })
        foreach ($e in (Profile-Emails $s)) {
            $where = @($signed | Where-Object { $_.email -eq $e } | ForEach-Object { $_.label })
            $label = if ($where.Count -and $where.Count -lt $signed.Count) { "$e  (" + ($where -join ', ') + ")" } else { $e }
            $item = New-Object System.Windows.Forms.ToolStripMenuItem($label)
            $item.Tag = $e
            if ($where.Count) { $item.Image = $RadioDot; $item.Font = New-Object System.Drawing.Font($item.Font, [System.Drawing.FontStyle]::Bold) }
            $item.Add_Click({ param($sender) Switch-Profile $sender.Tag })
            [void]$menu.Items.Add($item)
        }
        [void]$menu.Items.Add('-')
    }
    [void]$menu.Items.Add($Txt.Open, $null, { Show-Window })
    [void]$menu.Items.Add($Txt.Quit, $null, { Quit-App })
}
# Built now as well, so the menu is never empty (an empty menu does not open).
$menu.Add_Opening({ param($s, $ev) Build-Menu; $ev.Cancel = $false; Request-Refresh })
$menu.Add_Closed({ $script:MenuClosedAt = [datetime]::Now })

function Quit-App {
    $script:Quitting = $true; $timer.Stop(); $notify.Visible = $false; $form.Close()
    [System.Windows.Forms.Application]::Exit()
}

# ---------- state ----------
$script:State = $null; $script:StateRaw = $null

function Profile-Emails($s) {
    $emails = @($s.profiles | ForEach-Object { $_.email })
    foreach ($extra in @(@($s.targets | ForEach-Object { $_.email }) + $s.pending_desktop)) {
        if ($extra -and $emails -notcontains $extra) { $emails += $extra }
    }
    return $emails
}
function Describe-Target($t) {
    if ($t.asleep) { return $Txt.Asleep }
    if (-not $t.signed_in) { return $Txt.NotSignedIn }
    if ($t.email) { return $t.email }
    return $Txt.UnknownEmail
}

# Tray tooltip: one line when every app uses the same e-mail, otherwise short "app: e-mail" lines.
function Tray-Tip($s) {
    $emails = @($s.targets | ForEach-Object { Describe-Target $_ } | Select-Object -Unique)
    if ($emails.Count -eq 1) { return $Txt.Title + "`n" + $emails[0] }
    return (@($s.targets | ForEach-Object {
        $short = $_.label -replace '^Claude Code \((.*)\)$', '$1' -replace '^Claude ', ''
        $short + ': ' + (Describe-Target $_)
    }) -join "`n")
}
# NotifyIcon.Text refuses more than 63 characters, while Windows itself shows up to 127:
# set the private field and refresh the icon.
function Set-TrayText([string]$text) {
    if ($text.Length -gt 127) { $text = $text.Substring(0, 124) + '...' }
    if ($text.Length -le 63) { $notify.Text = $text; return }
    $flags = [System.Reflection.BindingFlags]'NonPublic,Instance'
    [System.Windows.Forms.NotifyIcon].GetField('text', $flags).SetValue($notify, $text)
    if ($notify.Visible) { [void][System.Windows.Forms.NotifyIcon].GetMethod('UpdateIcon', $flags).Invoke($notify, @($true)) }
}

function Apply-State([string]$raw) {
    $s = Parse-Reply $raw
    if (-not $s.ok) {
        $status.Text = $s.error
        # No table yet: show the error in place of the loader.
        if (-not $script:Loaded) { $loaderText.Text = $s.error; $loaderText.ForeColor = $ColRed; $loaderBar.Visible = $false }
        return
    }
    $script:Loaded = $true; $loader.Visible = $false
    $key = ($raw -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if ($key -eq $script:StateRaw) { return }
    $script:State = $s; $script:StateRaw = $key
    # Only targets in use (signed in or saved in a profile); others appear once someone signs in there.
    $s.targets = @($s.targets | Where-Object { $_.used })

    $ids = (@($s.targets | ForEach-Object { $_.id }) -join ',')
    if ($ids -ne $script:TargetIds) {
        $script:TargetIds = $ids
        Build-Columns $s.targets
        Build-Checks $s.targets $s.profiles
    }
    $checked = @(Checked-Targets)
    $grid.Rows.Clear()
    foreach ($e in (Profile-Emails $s)) {
        $p = $s.profiles | Where-Object { $_.email -eq $e } | Select-Object -First 1
        $values = @($e)
        foreach ($t in $s.targets) {
            $values += if ($t.signed_in -and $t.email -eq $e) { $Txt.Active }
                       elseif (@($p.saved) -contains $t.id) { $Txt.Saved }
                       elseif ($t.kind -eq 'desktop' -and $s.pending_desktop -eq $e) { $Txt.Pending }
                       else { '—' }
        }
        $row = $grid.Rows[$grid.Rows.Add([object[]]($values + @($null, $null)))]
        foreach ($t in $s.targets) {
            $cell = $row.Cells['t:' + $t.id]
            $cell.Style.ForeColor = if ($cell.Value -eq $Txt.Active) { $ColGreen } elseif ($cell.Value -eq '—') { [System.Drawing.Color]::FromArgb(170, 170, 170) } else { $ColMuted }
        }
        # "Active": every checked target is already signed in with this e-mail.
        $pending = @($checked | Where-Object { -not ($_.signed_in -and $_.email -eq $e) })
        if ($checked.Count -and -not $pending.Count) { $row.Tag = 'done' }
    }
    $grid.ClearSelection()
    $desktop = $s.targets | Where-Object { $_.kind -eq 'desktop' } | Select-Object -First 1
    $script:Applying = $true
    $chkSync.Checked = [bool]$s.settings.sync_sessions; $chkSync.Enabled = [bool]$desktop
    $script:Applying = $false
    if ($s.settings.language -in $LangCodes -and $s.settings.language -ne $script:LangChoice) { Set-Language $s.settings.language; return }
    $script:Applying = $true
    $script:Applying = $false
    Layout-Window

    $status.Text = ''
    Set-TrayText (Tray-Tip $s)
}

function Request-Refresh { $script:LastPoll = [datetime]::MinValue }

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($showEvent.WaitOne(0)) { Show-Window }
    if ($script:Poll) {
        if (-not $script:Poll.HasExited) { return }
        $out = $script:PollOut.Result
        $script:Poll.Dispose(); $script:Poll = $null
        $script:LastPoll = [datetime]::Now
        Apply-State $out
        return
    }
    $every = if ($form.Visible) { 3 } else { 15 }
    if (([datetime]::Now - $script:LastPoll).TotalSeconds -ge $every) { Start-Poll }
})

$notify.Text = $Txt.Title
Build-Menu
$notify.Visible = $true
$timer.Start()
Start-Poll  # the first status right away, not on the first timer tick
if (-not $Tray) { Show-Window }
[System.Windows.Forms.Application]::Run()
$notify.Dispose()
$mutex.ReleaseMutex()
