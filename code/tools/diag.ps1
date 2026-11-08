$ErrorActionPreference = "Continue"
$out = "C:\Users\fengxin\WorkBuddy\vivos7\diag-report.txt"
$lines = New-Object System.Collections.Generic.List[string]
function W($t) { $lines.Add($t); Write-Host $t }

W "===== DIAG REPORT $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====="
W ""

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
$isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
W "[1] Admin: $isAdmin  User: $($id.Name)"
if (-not $isAdmin) { W "!! NOT ELEVATED. Right-click -> Run as Administrator." }
W ""

# ---------- A. Crash dump analysis ----------
W "===== A. BUGCHECK / DUMP ANALYSIS ====="
$kd = "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\kd.exe"
if (-not (Test-Path $kd)) { $kd = "C:\Program Files\Windows Kits\10\Debuggers\x64\kd.exe" }
if (Test-Path $kd) {
    W "kd.exe found: $kd"
    if (Test-Path "C:\Windows\MEMORY.DMP") {
        $kdout = "C:\Users\fengxin\WorkBuddy\vivos7\kd-analyze.txt"
        W "Analyzing C:\Windows\MEMORY.DMP (this takes 1-3 min, downloading symbols)..."
        & $kd -z "C:\Windows\MEMORY.DMP" -c ".symfix; .reload; !analyze -v; lmvm nt; q" -logo $kdout 2>&1 | Out-Null
        if (Test-Path $kdout) {
            W "--- kd output (key sections) ---"
            $raw = Get-Content $kdout -Raw
            # keep lines of interest
            $keep = ($raw -split "`r?`n") | Where-Object {
                $_ -match 'BUGCHECK_CODE|BUGCHECK_P\d|FAILURE_BUCKET|FAILURE_EXCEPTION|IMAGE_NAME|MODULE_NAME|PROCESS_NAME|SYMBOL_NAME|\.sys|LIST_ENTRY|STACK_TEXT|STACK_COMMAND|Probably caused by|DUMP_TYPE|Invalid|argv' 
            }
            $keep | Select-Object -First 90 | ForEach-Object { W $_ }
            W ""
            W "Full kd log: $kdout"
        } else { W "kd produced no log." }
    } else { W "MEMORY.DMP not found." }
} else { W "kd.exe NOT found - skip dump parse." }
W ""

# ---------- B. Firmware boot entries (F12 issue) ----------
W "===== B. UEFI FIRMWARE BOOT ENTRIES (F12 menu source) ====="
$bcd = join-path $env:TEMP "fw.txt"
& bcdedit /enum firmware 2>&1 | Out-File $bcd -Encoding utf8
$bt = Get-Content $bcd -Raw
if ($bt -match 'denied|拒绝') { W "bcdedit DENIED (need admin)." }
else {
    $cur = ""
    foreach ($ln in ($bt -split "`r?`n")) {
        if ($ln -match '^identifier') { $cur = $ln.Trim(); W "--- $cur" }
        elseif ($ln -match 'description|path|device') { W "    $($ln.Trim())" }
    }
}
W ""
$sb = "query failed"
try { $sb = (Confirm-SecureBootUEFI).ToString() } catch { $sb = "query failed (no admin or legacy BIOS)" }
W ("SecureBoot: " + $sb)
W ""

# ---------- C. EFI partitions ----------
W "===== C. DISKS / EFI PARTITIONS ====="
Get-Disk | ForEach-Object {
    W ("Disk {0}  {1}  {2}  {3}GB  {4}" -f $_.Number, $_.FriendlyName, $_.PartitionStyle, [math]::Round($_.Size/1GB,1), $_.HealthStatus)
    Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue | ForEach-Object {
        $t = if ($_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') { 'ESP' }
             elseif ($_.GptType -eq '{0fc63daf-8483-4772-8e79-3d69d8477de4}') { 'LinuxFS' }
             elseif ($_.GptType -eq '{0657fd6d-a4ab-43c4-84e5-0933c84b4f4f}') { 'LinuxSwap' }
             elseif ($_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}') { 'BasicData' }
             else { $_.GptType }
        W ("    P{0}  {1}  {2}MB  {3}" -f $_.PartitionNumber, $_.DriveLetter, [math]::Round($_.Size/1MB,0), $t)
    }
}
W ""

# ---------- D. Network stack (hotspot crash) ----------
W "===== D. HOTSPOT / WLAN / FILTER DRIVERS ====="
Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
    W ("NIC: {0} | {1} | {2} | {3}" -f $_.Name, $_.InterfaceDescription, $_.Status, $_.LinkSpeed)
}
W ""
W "--- WFP / NDIS filter drivers (crash suspects) ---"
Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.State -eq 'Running' -and $_.Name -match 'wfp|ndis|hr|sysdiag|360|tencent|vmnet|sunlogin|oray|todesk' } |
    ForEach-Object { W ("  {0,-16} {1}" -f $_.Name, $_.PathName) }
W ""
W "--- Intel WLAN driver ---"
Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceName -match 'Wireless|WLAN|3165' } |
    ForEach-Object { W ("  {0} | ver {1} | date {2}" -f $_.DeviceName, $_.DriverVersion, $_.DriverDate) }
W ""
W "HostedNetwork:"
(& netsh wlan show drivers 2>&1) | Select-String 'Hosted network|Radio types' | ForEach-Object { W "  $_" }
W ""
W "Services:"
Get-Service icssvc,SharedAccess,WlanSvc -ErrorAction SilentlyContinue | ForEach-Object { W ("  {0} {1} {2}" -f $_.Name,$_.Status,$_.StartType) }
W ""

# ---------- E. Crash history ----------
W "===== E. RECENT BUGCHECK HISTORY (30d) ====="
Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001; StartTime=(Get-Date).AddDays(-30)} -ErrorAction SilentlyContinue |
    ForEach-Object { W ("{0} | {1}" -f $_.TimeCreated, (($_.Message -split "`n")[0])) }
W ""
W "===== END ====="

$lines | Out-File $out -Encoding utf8
Write-Host ""
Write-Host "Report saved: $out"