# Clicks a Claude desktop permission button and logs whether the app registered it.
# Tries 3 methods in turn (UIA Invoke -> focus+Enter -> real mouse click), checking main.log after each.
param(
  [string]$Target = "Allow once",   # "Allow once" | "Always allow" | "Deny"
  [int]$Index = 0,                  # which prompt, if several are on screen
  [switch]$ListOnly                 # just list prompts, click nothing
)
$logFile = Join-Path $PSScriptRoot "click_log.txt"
$appLog  = Join-Path $env:LOCALAPPDATA "Claude\logs\main.log"
function Log($m) {
  $line = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $m
  Write-Host $line
  Add-Content -Path $logFile -Value $line -Encoding UTF8
}

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W32 {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public struct POINT { public int X; public int Y; }
}
"@
[W32]::SetProcessDPIAware() | Out-Null   # so UIA rects and SetCursorPos use the same pixels
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

Log "==== run: Target='$Target' Index=$Index ListOnly=$ListOnly"
$proc = Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Log "ERROR: no Claude window found"; exit 1 }
$hwnd = $proc.MainWindowHandle
$root = $AE::FromHandle($hwnd)
Log ("window pid={0}  RAM={1} MB" -f $proc.Id, [int]($proc.WorkingSet64 / 1MB))

function Get-Prompts {
  $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
  for ($t = 0; $t -lt 5; $t++) {   # Chromium builds its accessibility tree lazily
    $denies = @($root.FindAll($TS::Descendants, $cond) | Where-Object { $_.Current.Name -eq "Deny" })
    if ($denies.Count) { break }
    Start-Sleep -Milliseconds 700
  }
  $list = @()
  foreach ($d in $denies) { $list += $walker.GetParent($walker.GetParent($d)) }
  return ,$list
}
function Card-Text($card) {
  $t = (@($card.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
        ForEach-Object { $_.Current.Name } | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique) -join ' | ') -replace '\s+', ' '
  if ($t.Length -gt 400) { $t = $t.Substring(0, 400) + '...' }
  return $t
}
function Find-Button($card, $name) {
  $c = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)
  return $card.FindFirst($TS::Descendants, $c)
}
function AppLog-Since($since) {
  Get-Content $appLog -Tail 400 | Where-Object {
    $_.Length -ge 19 -and $_.Substring(0, 19) -ge $since -and
    $_ -match 'respondToToolPermission|permission response|ALLOW_ONCE|Emitted tool permission|setFocusedSession'
  }
}
function Still-There($el) { try { $null = $el.Current.Name; return $true } catch { return $false } }
function Check($method, $since, $btn) {
  Start-Sleep -Milliseconds 1500
  $lines = @(AppLog-Since $since)
  $reg = @($lines | Where-Object { $_ -match 'respondToToolPermission|permission response' }).Count -gt 0
  $gone = -not (Still-There $btn)
  Log ("[{0}] app registered click: {1}   button gone from UI: {2}" -f $method, $reg, $gone)
  foreach ($l in $lines) { Log ("    main.log: " + $l.Substring(0, [Math]::Min(220, $l.Length))) }
  return ($reg -or $gone)
}

$prompts = Get-Prompts
Log "prompts on screen: $($prompts.Count)"
for ($i = 0; $i -lt $prompts.Count; $i++) { Log ("  [{0}] {1}" -f $i, (Card-Text $prompts[$i])) }
if ($ListOnly -or -not $prompts.Count) { Log "done (nothing clicked)"; exit 0 }
if ($Index -ge $prompts.Count) { Log "ERROR: no prompt [$Index]"; exit 1 }

$card = $prompts[$Index]
$btn = Find-Button $card $Target
if (-not $btn) { Log "ERROR: prompt [$Index] has no '$Target' button"; exit 1 }
Log "clicking '$Target' on prompt [$Index]"

# 1) UIA Invoke (accessibility click)
$since = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
try { $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Log "[invoke] sent" }
catch { Log "[invoke] failed: $($_.Exception.Message)" }
if (Check "invoke" $since $btn) { Log "SUCCESS via invoke"; exit 0 }

# 2) Focus the button + Enter key
$since = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
try {
  [W32]::SetForegroundWindow($hwnd) | Out-Null
  $btn.SetFocus(); Start-Sleep -Milliseconds 200
  [System.Windows.Forms.SendKeys]::SendWait("{ENTER}"); Log "[enter] sent"
} catch { Log "[enter] failed: $($_.Exception.Message)" }
if (Check "enter" $since $btn) { Log "SUCCESS via Enter"; exit 0 }

# 3) Real mouse click at the button's centre
$since = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
try {
  $r = $btn.Current.BoundingRectangle
  $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
  $old = New-Object W32+POINT; [W32]::GetCursorPos([ref]$old) | Out-Null
  [W32]::SetForegroundWindow($hwnd) | Out-Null
  [W32]::SetCursorPos($x, $y) | Out-Null; Start-Sleep -Milliseconds 120
  [W32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60   # left down
  [W32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)                                  # left up
  Start-Sleep -Milliseconds 120; [W32]::SetCursorPos($old.X, $old.Y) | Out-Null
  Log "[mouse] clicked at ($x,$y)"
} catch { Log "[mouse] failed: $($_.Exception.Message)" }
if (Check "mouse" $since $btn) { Log "SUCCESS via mouse"; exit 0 }

Log "FAILED: the button got all 3 clicks but the app never answered. Reload the window (Ctrl+R) or restart Claude."
exit 2
