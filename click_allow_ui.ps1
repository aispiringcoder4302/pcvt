# Claude Permission Auto-Clicker - UI Edition
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# region -- UI --
$form = New-Object System.Windows.Forms.Form
$form.Text        = "Claude Auto-Clicker"
$form.Size        = New-Object System.Drawing.Size(680, 560)
$form.MinimumSize = New-Object System.Drawing.Size(480, 360)
$form.StartPosition = "CenterScreen"
$form.BackColor   = [System.Drawing.Color]::FromArgb(13, 13, 20)
$form.ForeColor   = [System.Drawing.Color]::White

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock      = "Top"
$topPanel.Height    = 72
$topPanel.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 36)

$lblMode = New-Object System.Windows.Forms.Label
$lblMode.Text      = "Target: Always allow  >  Allow once"
$lblMode.AutoSize  = $true
$lblMode.Location  = New-Object System.Drawing.Point(14, 28)
$lblMode.ForeColor = [System.Drawing.Color]::FromArgb(140, 200, 140)
$lblMode.Font      = New-Object System.Drawing.Font("Segoe UI", 9)

$lblCountdown = New-Object System.Windows.Forms.Label
$lblCountdown.Text      = "Next run in:  3s"
$lblCountdown.AutoSize  = $true
$lblCountdown.Location  = New-Object System.Drawing.Point(280, 22)
$lblCountdown.ForeColor = [System.Drawing.Color]::FromArgb(90, 200, 255)
$lblCountdown.Font      = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)

$btnNow = New-Object System.Windows.Forms.Button
$btnNow.Text      = "Run Now"
$btnNow.Location  = New-Object System.Drawing.Point(460, 18)
$btnNow.Size      = New-Object System.Drawing.Size(88, 34)
$btnNow.FlatStyle = "Flat"
$btnNow.BackColor = [System.Drawing.Color]::FromArgb(45, 115, 210)
$btnNow.ForeColor = [System.Drawing.Color]::White
$btnNow.FlatAppearance.BorderSize = 0
$btnNow.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

$btnToggle = New-Object System.Windows.Forms.Button
$btnToggle.Text      = "Stop"
$btnToggle.Location  = New-Object System.Drawing.Point(558, 18)
$btnToggle.Size      = New-Object System.Drawing.Size(88, 34)
$btnToggle.FlatStyle = "Flat"
$btnToggle.BackColor = [System.Drawing.Color]::FromArgb(175, 45, 45)
$btnToggle.ForeColor = [System.Drawing.Color]::White
$btnToggle.FlatAppearance.BorderSize = 0
$btnToggle.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

$topPanel.Controls.AddRange(@($lblMode, $lblCountdown, $btnNow, $btnToggle))

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock        = "Fill"
$logBox.ReadOnly    = $true
$logBox.BackColor   = [System.Drawing.Color]::FromArgb(8, 8, 14)
$logBox.ForeColor   = [System.Drawing.Color]::FromArgb(195, 205, 215)
$logBox.Font        = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BorderStyle = "None"
$logBox.ScrollBars  = "Vertical"

$strip = New-Object System.Windows.Forms.StatusStrip
$strip.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 36)
$statusLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLbl.Text      = "Running"
$statusLbl.ForeColor = [System.Drawing.Color]::FromArgb(90, 200, 255)
$strip.Items.Add($statusLbl) | Out-Null

$clearLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
$clearLbl.Text      = "Clear log"
$clearLbl.Alignment = "Right"
$clearLbl.ForeColor = [System.Drawing.Color]::Gray
$clearLbl.IsLink    = $true
$clearLbl.Add_Click({ $logBox.Clear() })
$strip.Items.Add($clearLbl) | Out-Null

$form.Controls.AddRange(@($topPanel, $logBox, $strip))
# endregion

# region -- click logic (runs in background job) --
$clickBlock = {
    param([string]$AppLog)

    try { Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W32AC {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public struct POINT { public int X; public int Y; }
}
"@ } catch {}

    [W32AC]::SetProcessDPIAware() | Out-Null
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms

    $AE = [System.Windows.Automation.AutomationElement]
    $TS = [System.Windows.Automation.TreeScope]

    function Log($m) { Write-Output ("{0}  {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $m) }

    Log "==== run  (Always allow > Allow once)"
    $proc = Get-Process -Name claude -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) { Log "ERROR: no Claude window found"; return }

    $hwnd = $proc.MainWindowHandle
    $root = $AE::FromHandle($hwnd)
    Log ("window pid={0}  RAM={1} MB" -f $proc.Id, [int]($proc.WorkingSet64/1MB))

    $btnCond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)

    $allBtns = @()
    $denies  = @()
    for ($t = 0; $t -lt 3; $t++) {
        $allBtns = @($root.FindAll($TS::Descendants, $btnCond))
        $denies  = @($allBtns | Where-Object { $_.Current.Name -like "Deny*" })
        if ($denies.Count) { break }
        Start-Sleep -Milliseconds 200
    }

    if (-not $denies.Count) { Log "no permission prompt found - nothing to do"; return }
    Log "prompts detected: $($denies.Count)"

    $btn = $null
    $usedTarget = $null
    foreach ($prefix in @("Always allow", "Allow once")) {
        $btn = $allBtns | Where-Object { $_.Current.Name -like "$prefix*" } | Select-Object -First 1
        if ($btn) { $usedTarget = $prefix; break }
    }

    if (-not $btn) { Log "ERROR: no Allow button found (tried 'Always allow*' and 'Allow once*')"; return }
    Log "clicking '$($btn.Current.Name)' (matched '$usedTarget')"

    function Still-There($el) { try { $null = $el.Current.Name; $true } catch { $false } }
    function AppLog-Since($since) {
        if (-not (Test-Path $AppLog)) { return @() }
        Get-Content $AppLog -Tail 400 | Where-Object {
            $_.Length -ge 19 -and $_.Substring(0,19) -ge $since -and
            $_ -match 'respondToToolPermission|permission response|ALLOW_ONCE|Emitted tool permission'
        }
    }
    function Check($method, $since, $b) {
        Start-Sleep -Milliseconds 500
        $lines = @(AppLog-Since $since)
        $reg   = (@($lines | Where-Object { $_ -match 'respondToToolPermission|permission response' })).Count -gt 0
        $gone  = -not (Still-There $b)
        Log ("[{0}] registered={1}  gone={2}" -f $method, $reg, $gone)
        return ($reg -or $gone)
    }

    $since = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try { $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Log "[invoke] sent" }
    catch { Log "[invoke] failed: $($_.Exception.Message)" }
    if (Check "invoke" $since $btn) { Log "SUCCESS via invoke"; return }

    $since = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        [W32AC]::SetForegroundWindow($hwnd) | Out-Null
        $btn.SetFocus(); Start-Sleep -Milliseconds 200
        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}"); Log "[enter] sent"
    } catch { Log "[enter] failed: $($_.Exception.Message)" }
    if (Check "enter" $since $btn) { Log "SUCCESS via Enter"; return }

    $since = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        $r = $btn.Current.BoundingRectangle
        $x = [int]($r.X + $r.Width/2); $y = [int]($r.Y + $r.Height/2)
        $old = New-Object W32AC+POINT; [W32AC]::GetCursorPos([ref]$old) | Out-Null
        [W32AC]::SetForegroundWindow($hwnd) | Out-Null
        [W32AC]::SetCursorPos($x,$y) | Out-Null; Start-Sleep -Milliseconds 40
        [W32AC]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 30
        [W32AC]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40; [W32AC]::SetCursorPos($old.X,$old.Y) | Out-Null
        Log "[mouse] clicked at ($x,$y)"
    } catch { Log "[mouse] failed: $($_.Exception.Message)" }
    if (Check "mouse" $since $btn) { Log "SUCCESS via mouse"; return }

    Log "FAILED: all 3 methods tried - app did not respond"
}
# endregion

# region -- state & timers --
$script:countdown = 3
$script:running   = $true
$script:job       = $null
$script:appLog    = Join-Path $env:LOCALAPPDATA "Claude\logs\main.log"

$colorInfo    = [System.Drawing.Color]::FromArgb(195, 205, 215)
$colorSuccess = [System.Drawing.Color]::FromArgb(75, 215, 125)
$colorError   = [System.Drawing.Color]::FromArgb(255, 85, 85)
$colorDim     = [System.Drawing.Color]::FromArgb(100, 105, 115)
$colorBlue    = [System.Drawing.Color]::FromArgb(90, 165, 255)

function Append-Log($text, $color) {
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor  = if ($color) { $color } else { $colorInfo }
    $logBox.AppendText($text + "`n")
    $logBox.SelectionColor  = $colorInfo
    $logBox.ScrollToCaret()
}

function Start-ClickJob {
    if ($script:job -and $script:job.State -eq 'Running') { return }
    $script:job = Start-Job -ScriptBlock $clickBlock -ArgumentList $script:appLog
}

function Poll-Job {
    if (-not $script:job) { return }
    $out = Receive-Job $script:job -ErrorAction SilentlyContinue
    foreach ($line in $out) {
        $c = if     ($line -match 'SUCCESS')                         { $colorSuccess }
             elseif ($line -match 'ERROR|FAILED|failed')             { $colorError   }
             elseif ($line -match 'no permission prompt')            { $colorDim     }
             elseif ($line -match '\[invoke\]|\[enter\]|\[mouse\]') { $colorBlue    }
             else                                                    { $null         }
        Append-Log $line $c
    }
    if ($script:job.State -in 'Completed','Failed','Stopped') {
        Remove-Job $script:job -Force -ErrorAction SilentlyContinue
        $script:job = $null
    }
}

$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    Poll-Job
    if (-not $script:running) { return }
    $script:countdown--
    $lblCountdown.Text = "Next run in:  ${script:countdown}s"
    if ($script:countdown -le 0) {
        $script:countdown = 3
        Append-Log ("--- auto-trigger @ " + (Get-Date -Format "HH:mm:ss") + " ---") $colorBlue
        Start-ClickJob
    }
})

$btnToggle.Add_Click({
    $script:running = -not $script:running
    if ($script:running) {
        $script:countdown    = 3
        $btnToggle.Text      = "Stop"
        $btnToggle.BackColor = [System.Drawing.Color]::FromArgb(175, 45, 45)
        $statusLbl.Text      = "Running"
        $statusLbl.ForeColor = [System.Drawing.Color]::FromArgb(90, 200, 255)
        Append-Log "> resumed" $colorSuccess
    } else {
        $btnToggle.Text      = "Start"
        $btnToggle.BackColor = [System.Drawing.Color]::FromArgb(40, 140, 60)
        $statusLbl.Text      = "Paused"
        $statusLbl.ForeColor = [System.Drawing.Color]::FromArgb(220, 175, 50)
        $lblCountdown.Text   = "Paused"
        Append-Log "|| paused" ([System.Drawing.Color]::FromArgb(220, 175, 50))
    }
})

$btnNow.Add_Click({
    $script:countdown  = 3
    $lblCountdown.Text = "Next run in:  3s"
    Append-Log ("--- manual trigger @ " + (Get-Date -Format "HH:mm:ss") + " ---") $colorBlue
    Start-ClickJob
})

$form.Add_FormClosing({
    $timer.Stop()
    if ($script:job) { Stop-Job $script:job -PassThru | Remove-Job -Force -ErrorAction SilentlyContinue }
})
# endregion

Append-Log ("Claude Auto-Clicker started @ " + (Get-Date -Format "HH:mm:ss")) $colorBlue
Append-Log "Priority: Always allow > Allow once. Fires every 3 s." $colorDim
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
