param([switch]$Store)
# Timer and control delegates must use the same mode as script startup.
$script:storeMode = [bool]$Store
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class CeliumTaskbar {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
}
'@
[void][CeliumTaskbar]::SetCurrentProcessExplicitAppUserModelID($(if ($script:storeMode) { $env:CELIUM_STORE_AUMID } else { 'cn.celium.desktop' }))

$script:installDir = Join-Path $env:ProgramFiles 'Celium'
$script:cli = Join-Path $script:installDir 'celium.exe'
if ($script:storeMode) {
    $script:installDir = $PSScriptRoot
    $script:cli = Join-Path $PSScriptRoot 'CeliumStore.exe'
    # Give the command direct UTF-8 output files and poll its process handle.
    # Pipe readers under PowerShell 5.1 can remain pending after child exit.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public sealed class CeliumStoreCommand : IDisposable {
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes {
        public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct StartupInfo {
        public int Size; public string Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
        public short Show, ReservedSize; public IntPtr ReservedData, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] private struct StartupInfoEx { public StartupInfo Info; public IntPtr Attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr CreateFileW(string name, uint access, uint share, ref SecurityAttributes security, uint create, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    private IntPtr handle;
    private static string Quote(string value) {
        var result = new StringBuilder("\""); int slashes=0;
        foreach (char ch in value) {
            if (ch=='\\') { slashes++; continue; }
            if (ch=='"') result.Append('\\',slashes*2+1).Append(ch);
            else result.Append('\\',slashes).Append(ch);
            slashes=0;
        }
        return result.Append('\\',slashes*2).Append('"').ToString();
    }
    private static IntPtr Open(string path, uint access, uint disposition) {
        var sa=new SecurityAttributes {Length=Marshal.SizeOf(typeof(SecurityAttributes)), Inherit=true};
        IntPtr file=CreateFileW(path,access,3,ref sa,disposition,0x80,IntPtr.Zero);
        if(file==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return file;
    }
    public CeliumStoreCommand(string exe,string[] args,string outPath,string errPath) {
        IntPtr input=IntPtr.Zero, output=IntPtr.Zero, error=IntPtr.Zero, attrs=IntPtr.Zero, handles=IntPtr.Zero;
        bool initialized=false;
        try {
            input=Open("NUL",0x80000000,3); output=Open(outPath,0x40000000,2); error=Open(errPath,0x40000000,2);
            IntPtr size=IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);
            attrs=Marshal.AllocHGlobal(size);
            if(!InitializeProcThreadAttributeList(attrs,1,0,ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            initialized=true;
            handles=Marshal.AllocHGlobal(IntPtr.Size*3);
            Marshal.WriteIntPtr(handles,0,input); Marshal.WriteIntPtr(handles,IntPtr.Size,output); Marshal.WriteIntPtr(handles,IntPtr.Size*2,error);
            if(!UpdateProcThreadAttribute(attrs,0,new IntPtr(0x20002),handles,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var startup=new StartupInfoEx { Info=new StartupInfo {Size=Marshal.SizeOf(typeof(StartupInfoEx)),Flags=0x100,Input=input,Output=output,Error=error}, Attributes=attrs };
            ProcessInfo info;
            var command=new StringBuilder(Quote(exe)+" "+string.Join(" ",Array.ConvertAll(args,Quote)));
            // The handle allowlist gives only these three streams to the child.
            // Windows writes UTF-8 bytes directly; no pipe or runspace callback.
            if(!CreateProcessW(exe,command,IntPtr.Zero,IntPtr.Zero,true,0x08080000,IntPtr.Zero,null,ref startup,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            handle=info.Process; CloseHandle(info.Thread);
        } finally {
            if(initialized) DeleteProcThreadAttributeList(attrs);
            if(attrs!=IntPtr.Zero) Marshal.FreeHGlobal(attrs);
            if(handles!=IntPtr.Zero) Marshal.FreeHGlobal(handles);
            if(input!=IntPtr.Zero) CloseHandle(input); if(output!=IntPtr.Zero) CloseHandle(output); if(error!=IntPtr.Zero) CloseHandle(error);
        }
    }
    public bool HasExited { get { uint result=WaitForSingleObject(handle,0); if(result==0xFFFFFFFF) throw new Win32Exception(Marshal.GetLastWin32Error()); return result==0; } }
    public int ExitCode { get { uint code; if(!GetExitCodeProcess(handle,out code)) throw new Win32Exception(Marshal.GetLastWin32Error()); return unchecked((int)code); } }
    public void Kill() { if(!HasExited && !TerminateProcess(handle,1)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public void Dispose() { if(handle!=IntPtr.Zero) {CloseHandle(handle);handle=IntPtr.Zero;} }
}
'@
}

function Start-ClientCommand([string[]]$Arguments, [string]$OutputPath, [string]$ErrorPath) {
    if ($script:storeMode) { return [CeliumStoreCommand]::new($script:cli, $Arguments, $OutputPath, $ErrorPath) }
    return Start-Process -FilePath $script:cli -ArgumentList $Arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $OutputPath -RedirectStandardError $ErrorPath
}
$script:statusFile = Join-Path $env:ProgramData 'CeliumStatus\update.json'
$script:manifestUrl = 'https://img.uulucky.com/celium/downloads/windows/stable.json'
$script:task = $null
$script:taskName = ''
$script:taskOut = ''
$script:taskErr = ''
$script:approvalURL = ''
$script:updater = $null
$script:updateStarted = [DateTime]::MinValue
$script:updating = $false
$script:relaunchAfterUpdate = $false
$script:statusTask = $null
$script:statusOut = ''
$script:statusErr = ''
$script:pendingTaskResult = $null
$script:pendingTaskDeadline = [DateTime]::MinValue
$script:manualRefresh = $false
$script:lastOperationError = ''
$script:lastOperationName = ''
$script:currentBackendState = ''
$script:statusStale = $false
$script:statusStarted = [DateTime]::MinValue
$script:diagnosticReport = ''
$script:peerRows = @()
$script:diagnosticTask = $null
$script:checkTask = $null
$script:nextUpdateCheck = [DateTime]::UtcNow
$script:preferencesDir = Join-Path $env:LOCALAPPDATA 'CeliumDesktop'
if ($script:storeMode) {
    $family = ($env:CELIUM_STORE_AUMID -split '!')[0]
    if ([string]::IsNullOrWhiteSpace($family)) { throw '无法读取商店应用标识，请从开始菜单打开 Celium。' }
    $script:preferencesDir = Join-Path $env:LOCALAPPDATA ('Packages\' + $family + '\LocalState')
    $script:statusFile = Join-Path $script:preferencesDir 'unused-store-update.json'
    $script:nextUpdateCheck = [DateTime]::MaxValue
}
$script:favoritesFile = Join-Path $script:preferencesDir 'favorite-devices.json'
$script:favorites = @()
try { if (Test-Path $script:favoritesFile) { $script:favorites = @(Get-Content $script:favoritesFile -Raw | ConvertFrom-Json) } } catch { }

function Read-Release {
    Get-Content -LiteralPath (Join-Path $script:installDir 'release.json') -Raw | ConvertFrom-Json
}

$script:navy = [System.Drawing.Color]::FromArgb(15, 31, 51)
$script:ink = [System.Drawing.Color]::FromArgb(28, 44, 62)
$script:muted = [System.Drawing.Color]::FromArgb(98, 116, 133)
$script:green = [System.Drawing.Color]::FromArgb(23, 156, 109)
$script:page = [System.Drawing.Color]::FromArgb(246, 249, 252)
$script:icon = [System.Drawing.Icon]::new((Join-Path $script:installDir 'Celium.ico'))

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Celium Desktop'
$form.Icon = $script:icon
$form.ShowIcon = $true
$form.ShowInTaskbar = $true
$form.ClientSize = New-Object System.Drawing.Size(820, 680)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = $script:page
$form.Add_Activated({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
})

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(820, 110)
$header.BackColor = $script:navy
$form.Controls.Add($header)

$accent = New-Object System.Windows.Forms.Panel
$accent.Location = New-Object System.Drawing.Point(0, 106)
$accent.Size = New-Object System.Drawing.Size(820, 4)
$accent.BackColor = $script:green
$header.Controls.Add($accent)

$logo = New-Object System.Windows.Forms.PictureBox
$logo.Location = New-Object System.Drawing.Point(26, 25)
$logo.Size = New-Object System.Drawing.Size(58, 58)
$logo.SizeMode = 'StretchImage'
$loadedLogo = [System.Drawing.Image]::FromFile((Join-Path $script:installDir 'Celium.png'))
try {
    $logo.Image = [System.Drawing.Bitmap]::new($loadedLogo)
} finally {
    $loadedLogo.Dispose()
}
$header.Controls.Add($logo)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Celium'
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 21, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(101, 20)
$title.Size = New-Object System.Drawing.Size(300, 43)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '私有组网 · 安全连接你的设备'
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(174, 195, 211)
$subtitle.Location = New-Object System.Drawing.Point(104, 66)
$subtitle.Size = New-Object System.Drawing.Size(370, 24)
$header.Controls.Add($subtitle)

$script:versionLabel = New-Object System.Windows.Forms.Label
$script:versionLabel.Location = New-Object System.Drawing.Point(520, 42)
$script:versionLabel.Size = New-Object System.Drawing.Size(270, 26)
$script:versionLabel.TextAlign = 'MiddleRight'
$script:versionLabel.ForeColor = [System.Drawing.Color]::FromArgb(203, 216, 229)
$script:versionLabel.Text = '版本 ' + [string]((Read-Release).version)
$header.Controls.Add($script:versionLabel)

$card = New-Object System.Windows.Forms.Panel
$card.Location = New-Object System.Drawing.Point(24, 129)
$card.Size = New-Object System.Drawing.Size(772, 112)
$card.BackColor = [System.Drawing.Color]::White
$card.BorderStyle = 'None'
$form.Controls.Add($card)

$statusDot = New-Object System.Windows.Forms.Label
$statusDot.Text = '●'
$statusDot.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15)
$statusDot.ForeColor = $script:muted
$statusDot.Location = New-Object System.Drawing.Point(20, 17)
$statusDot.Size = New-Object System.Drawing.Size(28, 28)
$card.Controls.Add($statusDot)

$connection = New-Object System.Windows.Forms.Label
$connection.Location = New-Object System.Drawing.Point(52, 17)
$connection.Size = New-Object System.Drawing.Size(290, 30)
$connection.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$connection.ForeColor = $script:ink
$connection.Text = '正在读取连接状态…'
$card.Controls.Add($connection)

$nodeLabel = New-Object System.Windows.Forms.Label
$nodeLabel.Location = New-Object System.Drawing.Point(24, 64)
$nodeLabel.Size = New-Object System.Drawing.Size(315, 24)
$nodeLabel.ForeColor = $script:muted
$nodeLabel.Text = '设备  —'
$card.Controls.Add($nodeLabel)

$addressLabel = New-Object System.Windows.Forms.Label
$addressLabel.Location = New-Object System.Drawing.Point(350, 20)
$addressLabel.Size = New-Object System.Drawing.Size(240, 25)
$addressLabel.ForeColor = $script:ink
$addressLabel.Text = '地址  —'
$card.Controls.Add($addressLabel)

$networkLabel = New-Object System.Windows.Forms.Label
$networkLabel.Location = New-Object System.Drawing.Point(350, 64)
$networkLabel.Size = New-Object System.Drawing.Size(260, 24)
$networkLabel.ForeColor = $script:muted
$networkLabel.Text = '网络  —'
$card.Controls.Add($networkLabel)

$refreshInfo = New-Object System.Windows.Forms.Label
$refreshInfo.Location = New-Object System.Drawing.Point(595, 16)
$refreshInfo.Size = New-Object System.Drawing.Size(155, 26)
$refreshInfo.TextAlign = 'MiddleRight'
$refreshInfo.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$refreshInfo.ForeColor = $script:muted
$refreshInfo.Text = '每 5 秒自动刷新'
$card.Controls.Add($refreshInfo)

$approvalButton = New-Object System.Windows.Forms.Button
$approvalButton.Text = '打开授权页面'
$approvalButton.Location = New-Object System.Drawing.Point(615, 61)
$approvalButton.Size = New-Object System.Drawing.Size(135, 32)
$approvalButton.FlatStyle = 'Flat'
$approvalButton.BackColor = $script:green
$approvalButton.ForeColor = [System.Drawing.Color]::White
$approvalButton.FlatAppearance.BorderSize = 0
$approvalButton.Visible = $false
$card.Controls.Add($approvalButton)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(24, 286)
$tabs.Size = New-Object System.Drawing.Size(772, 250)
$tabs.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Controls.Add($tabs)

$peersTab = New-Object System.Windows.Forms.TabPage
$peersTab.Text = '设备 (0)'
$peersTab.BackColor = [System.Drawing.Color]::White
$tabs.TabPages.Add($peersTab)

$peerList = New-Object System.Windows.Forms.ListView
$peerList.Dock = 'Fill'
$peerList.View = 'Details'
$peerList.FullRowSelect = $true
$peerList.HideSelection = $false
$peerList.BorderStyle = 'None'
$peerList.BackColor = [System.Drawing.Color]::White
$peerList.ForeColor = $script:ink
$peerList.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$null = $peerList.Columns.Add('设备', 230)
$null = $peerList.Columns.Add('地址', 160)
$null = $peerList.Columns.Add('连接方式', 140)
$null = $peerList.Columns.Add('状态', 195)
$peersTab.Controls.Add($peerList)
$filterPanel = New-Object System.Windows.Forms.Panel
$filterPanel.Dock = 'Top'
$filterPanel.Height = 37
$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = '搜索'
$searchLabel.Location = New-Object System.Drawing.Point(8, 9)
$searchLabel.Size = New-Object System.Drawing.Size(38, 23)
$filterPanel.Controls.Add($searchLabel)
$peerSearch = New-Object System.Windows.Forms.TextBox
$peerSearch.Location = New-Object System.Drawing.Point(48, 7)
$peerSearch.Size = New-Object System.Drawing.Size(290, 25)
$filterPanel.Controls.Add($peerSearch)
$searchTip = New-Object System.Windows.Forms.ToolTip
$searchTip.SetToolTip($peerSearch, '搜索设备名、IP、MagicDNS 域名或系统')
$onlineFilter = New-Object System.Windows.Forms.CheckBox
$onlineFilter.Text = '仅在线'
$onlineFilter.Location = New-Object System.Drawing.Point(355, 6)
$onlineFilter.Size = New-Object System.Drawing.Size(95, 26)
$filterPanel.Controls.Add($onlineFilter)
$favoriteFilter = New-Object System.Windows.Forms.CheckBox
$favoriteFilter.Text = '收藏'
$favoriteFilter.Location = New-Object System.Drawing.Point(460, 6)
$filterPanel.Controls.Add($favoriteFilter)
$peersTab.Controls.Add($filterPanel)
$peerHint = New-Object System.Windows.Forms.Label
$peerHint.Dock = 'Bottom'
$peerHint.Height = 24
$peerHint.ForeColor = $script:muted
$peerHint.Text = '右键设备：复制 IP / 域名、收藏、测试隧道或应用端口'
$peersTab.Controls.Add($peerHint)

$healthLabel = New-Object System.Windows.Forms.Label
$healthLabel.Location = New-Object System.Drawing.Point(24, 244)
$healthLabel.Size = New-Object System.Drawing.Size(772, 34)
$healthLabel.ForeColor = $script:muted
$healthLabel.Text = '在线表示协调连接；应用访问请测试相应 TCP 端口。'
$form.Controls.Add($healthLabel)
$trafficLabel = New-Object System.Windows.Forms.Label
$trafficLabel.Location = New-Object System.Drawing.Point(24, 90)
$trafficLabel.Size = New-Object System.Drawing.Size(700, 20)
$trafficLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$trafficLabel.ForeColor = $script:muted
$card.Controls.Add($trafficLabel)

$detailsTab = New-Object System.Windows.Forms.TabPage
$detailsTab.Text = '诊断详情'
$detailsTab.BackColor = [System.Drawing.Color]::White
$tabs.TabPages.Add($detailsTab)

$details = New-Object System.Windows.Forms.TextBox
$details.Dock = 'Fill'
$details.Multiline = $true
$details.ReadOnly = $true
$details.WordWrap = $false
$details.ScrollBars = 'Both'
$details.Font = New-Object System.Drawing.Font('Consolas', 9)
$details.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$detailsTab.Controls.Add($details)
$copyDiagnostics = New-Object System.Windows.Forms.Button
$copyDiagnostics.Text = '复制诊断（不含密钥和令牌）'
$copyDiagnostics.Dock = 'Top'
$copyDiagnostics.Height = 32
$copyDiagnostics.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($details.Text); $message.Text = '已复制诊断；其中仍包含设备名和私网地址。' } catch { $message.Text = '剪贴板暂不可用，请重试。' } })
$detailsTab.Controls.Add($copyDiagnostics)

function New-Button([string]$text, [int]$x, [int]$width, [bool]$primary) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $text
    $button.Location = New-Object System.Drawing.Point($x, 554)
    $button.Size = New-Object System.Drawing.Size($width, 38)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(211, 222, 230)
    $button.BackColor = if ($primary) { $script:green } else { [System.Drawing.Color]::White }
    $button.ForeColor = if ($primary) { [System.Drawing.Color]::White } else { $script:ink }
    if ($primary) { $button.FlatAppearance.BorderSize = 0 }
    $form.Controls.Add($button)
    return $button
}

$connectButton = New-Button '连接' 24 96 $true
$disconnectButton = New-Button '断开' 129 96 $false
$refreshButton = New-Button '刷新状态' 234 112 $false
$exitButton = New-Button '出口设置' 355 104 $false
$checkButton = New-Button '检查更新' 565 108 $false
$updateButton = New-Button '立即更新' 682 114 $false
$updateButton.Enabled = $false
if ($script:storeMode) {
    $checkButton.Text = '商店更新'
    $updateButton.Visible = $false
    $privacyLink = New-Object System.Windows.Forms.LinkLabel
    $privacyLink.Text = '隐私政策'
    $privacyLink.Location = New-Object System.Drawing.Point(697, 564)
    $privacyLink.Size = New-Object System.Drawing.Size(99, 28)
    $privacyLink.LinkColor = $script:green
    $privacyLink.ActiveLinkColor = $script:green
    $privacyLink.Add_LinkClicked({ Start-Process 'https://www.celium.cn/privacy/' })
    $form.Controls.Add($privacyLink)
}

$message = New-Object System.Windows.Forms.Label
$message.Location = New-Object System.Drawing.Point(24, 608)
$message.Size = New-Object System.Drawing.Size(772, 40)
$message.ForeColor = $script:muted
$message.Text = '就绪'
$form.Controls.Add($message)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(24, 654)
$progress.Size = New-Object System.Drawing.Size(772, 8)
$progress.Style = 'Marquee'
$progress.MarqueeAnimationSpeed = 28
$progress.Visible = $false
$form.Controls.Add($progress)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $script:icon
$tray.Text = 'Celium Desktop'
$tray.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showItem = $trayMenu.Items.Add('显示 Celium')
$exitItem = $trayMenu.Items.Add('退出')
$tray.ContextMenuStrip = $trayMenu
function Show-CeliumWindow {
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.BringToFront()
    $form.Activate()
}
$tray.Add_DoubleClick({ Show-CeliumWindow })
$showItem.Add_Click({ Show-CeliumWindow })
$exitItem.Add_Click({ $form.Close() })

# An update continues in its elevated process if this window is closed. When
# reopened, show its last phase rather than making the app appear to have quit.
if (Test-Path -LiteralPath $script:statusFile) {
    try {
        $saved = Get-Content -LiteralPath $script:statusFile -Raw | ConvertFrom-Json
        $savedAt = [DateTime]::Parse([string]$saved.at).ToUniversalTime()
        if ([string]$saved.state -eq 'updating' -and $savedAt -gt [DateTime]::UtcNow.AddMinutes(-20)) {
            $script:updating = $true
            $script:updateStarted = $savedAt
            $message.Text = [string]$saved.message
            $progress.Visible = $true
            $connectButton.Enabled = $false
            $disconnectButton.Enabled = $false
            $checkButton.Enabled = $false
        } elseif ([string]$saved.state -in @('complete', 'error') -and
            $savedAt -gt [DateTime]::UtcNow.AddMinutes(-20)) {
            $message.Text = [string]$saved.message
        }
    } catch { }
}

function Get-JsonMember($value, [string]$name) {
    if ($null -eq $value) { return $null }
    $property = $value.PSObject.Properties[$name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Render-Peers {
    $selected = if ($peerList.SelectedItems.Count -gt 0) { [string]$peerList.SelectedItems[0].Tag.ID } else { '' }
    $query = $peerSearch.Text.Trim().ToLowerInvariant()
    $rows = @($script:peerRows | Where-Object {
        $p = $_
        (-not $onlineFilter.Checked -or $p.Online) -and
        (-not $favoriteFilter.Checked -or $script:favorites -contains $p.ID) -and
        (([string]$p.Name + ' ' + [string]$p.DNSName + ' ' + [string]$p.Address + ' ' + [string]$p.OS).ToLowerInvariant().Contains($query))
    } | Sort-Object @{Expression={if ($script:favorites -contains $_.ID) {0} else {1}}}, Name)
    $peerList.BeginUpdate()
    try {
        $peerList.Items.Clear()
        foreach ($p in $rows) {
            $prefix = if ($script:favorites -contains $p.ID) { '★ ' } else { '' }
            $item = New-Object System.Windows.Forms.ListViewItem -ArgumentList @($prefix + [string]$p.Name)
            $null = $item.SubItems.Add([string]$p.Address)
            $null = $item.SubItems.Add([string]$p.Path)
            $null = $item.SubItems.Add([string]$p.State)
            $item.Tag = $p
            $item.ToolTipText = [string]$p.DNSName + ' · ' + [string]$p.OS
            if (-not $p.Online) { $item.ForeColor = $script:muted }
            $null = $peerList.Items.Add($item)
            if ([string]$p.ID -eq $selected) { $item.Selected = $true }
        }
    } finally { $peerList.EndUpdate() }
    $peersTab.Text = '设备 (' + $rows.Count + '/' + $script:peerRows.Count + ')'
    $peerHint.Text = if ($rows.Count -eq 0) { '没有匹配的设备；调整筛选，或让另一台设备加入同一网络。' } else { '右键设备：复制 IP / 域名、收藏、测试隧道或应用端口' }
}
function Selected-Peer {
    if ($peerList.SelectedItems.Count -eq 0) { $message.Text = '请先选择一台设备。'; return $null }
    return $peerList.SelectedItems[0].Tag
}
function Copy-PeerValue([string]$field) {
    $p = Selected-Peer
    if ($null -eq $p) { return }
    $value = [string](Get-JsonMember $p $field)
    if (-not $value -or $value -eq '—') { $message.Text = '此设备暂时没有该地址。'; return }
    try { [System.Windows.Forms.Clipboard]::SetText($value); $message.Text = '已复制：' + $value } catch { $message.Text = '剪贴板暂不可用，请重试。' }
}
function Test-Peer([int]$port) {
    $p = Selected-Peer
    if ($null -eq $p -or $null -ne $script:diagnosticTask -or $null -ne $script:task -or $script:updating) { return }
    if ($script:currentBackendState -ne 'Running') { $message.Text = '请先连接 Celium。'; return }
    $script:diagnosticOut = Join-Path $env:TEMP ('celium-test-' + [guid]::NewGuid().ToString('N') + '.json')
    $script:diagnosticErr = $script:diagnosticOut + '.err'
    $script:diagnosticStarted = [DateTime]::UtcNow
    try {
        # Address is supplied by the daemon, never interpreted as PowerShell.
        $script:diagnosticTask = Start-ClientCommand @('diagnose', [string]$p.Address, ('--port=' + $port), '--json') $script:diagnosticOut $script:diagnosticErr
        $message.Text = '正在测试 ' + $p.Name + '；隧道与应用端口分别判断。'
        $progress.Visible = $true
    } catch { $message.Text = '测试未启动：' + $_.Exception.Message }
}
$peerSearch.Add_TextChanged({ Render-Peers })
$onlineFilter.Add_CheckedChanged({ Render-Peers })
$favoriteFilter.Add_CheckedChanged({ Render-Peers })
$peerList.ShowItemToolTips = $true
$peerActions = New-Object System.Windows.Forms.ContextMenuStrip
$copyIP = $peerActions.Items.Add('复制 IP 地址'); $copyIP.Add_Click({ Copy-PeerValue 'Address' })
$copyDNS = $peerActions.Items.Add('复制 MagicDNS 域名'); $copyDNS.Add_Click({ Copy-PeerValue 'DNSName' })
$favoriteAction = $peerActions.Items.Add('收藏 / 取消收藏')
$favoriteAction.Add_Click({
    $p = Selected-Peer
    if ($null -eq $p) { return }
    if ($script:favorites -contains $p.ID) { $script:favorites = @($script:favorites | Where-Object { $_ -ne $p.ID }) } else { $script:favorites += [string]$p.ID }
    try { $null = New-Item -ItemType Directory -Path $script:preferencesDir -Force; ConvertTo-Json -InputObject @($script:favorites) | Set-Content $script:favoritesFile -Encoding UTF8 } catch { $message.Text = '收藏暂时无法保存。' }
    Render-Peers
})
$testTunnel = $peerActions.Items.Add('测试隧道连接'); $testTunnel.Add_Click({ Test-Peer 0 })
$testSSH = $peerActions.Items.Add('测试 SSH · TCP 22'); $testSSH.Add_Click({ Test-Peer 22 })
$testHTTPS = $peerActions.Items.Add('测试 HTTPS · TCP 443'); $testHTTPS.Add_Click({ Test-Peer 443 })
$testRDP = $peerActions.Items.Add('测试远程桌面 · TCP 3389'); $testRDP.Add_Click({ Test-Peer 3389 })
$peerList.ContextMenuStrip = $peerActions
$peerList.Add_MouseDown({ param($sender, $event) if ($event.Button -eq 'Right') { $hit = $peerList.HitTest($event.Location); if ($null -ne $hit.Item) { $peerList.SelectedItems.Clear(); $hit.Item.Selected = $true } } })
$peerList.Add_DoubleClick({ Copy-PeerValue 'Address' })

function Apply-NodeStatus($status, [string]$plain) {
        $state = [string](Get-JsonMember $status 'BackendState')
        $script:currentBackendState = $state
        if ($null -eq $script:task -and $null -eq $script:pendingTaskResult -and
            (($script:lastOperationName -eq 'up' -and $state -eq 'Running') -or
             ($script:lastOperationName -eq 'down' -and $state -eq 'Stopped'))) {
            $message.Text = if ($script:lastOperationName -eq 'down') { '已断开' } else { '已连接' }
            $script:lastOperationName = ''
            $script:lastOperationError = ''
            $approvalButton.Visible = $false
        }
        $details.Text = if ($script:diagnosticReport) { $script:diagnosticReport } else { $plain.Trim() }
        if ($script:lastOperationError) {
            $details.Text = $script:lastOperationError + [Environment]::NewLine + [Environment]::NewLine + $details.Text
        }
        $reportedVersion = [string](Get-JsonMember $status 'Version')
        if ($reportedVersion) { $script:versionLabel.Text = '版本 ' + $reportedVersion }
        $nodeLabel.Text = '设备  ' + [string](Get-JsonMember $status 'Node')
        $addressLabel.Text = '地址  ' + [string](Get-JsonMember $status 'Address')
        $networkLabel.Text = '网络  ' + [string](Get-JsonMember $status 'Network')
        $trafficLabel.Text = [string](Get-JsonMember $status 'Traffic')
        $script:lastView = $status
        $health = @(Get-JsonMember $status 'Health')
        $healthLabel.Text = if ($health.Count -gt 0) { '需要处理：' + ($health -join '；') } else { [string](Get-JsonMember $status 'Hint') }
        $connection.Text = [string](Get-JsonMember $status 'Label')
        $connection.ForeColor = if (Get-JsonMember $status 'Connected') { $script:green } else { [System.Drawing.Color]::FromArgb(178, 113, 25) }
        $statusDot.ForeColor = $connection.ForeColor
        $script:peerRows = @(Get-JsonMember $status 'Peers')
        Render-Peers
        $refreshInfo.Text = '自动刷新 ' + [DateTime]::Now.ToString('HH:mm:ss')
}

function Show-StatusFailure([string]$reason) {
    $script:currentBackendState = ''
    $connection.Text = '服务未就绪'
    $connection.ForeColor = [System.Drawing.Color]::FromArgb(184, 64, 64)
    $statusDot.ForeColor = $connection.ForeColor
    $nodeLabel.Text = '设备  —'
    $addressLabel.Text = '地址  —'
    $networkLabel.Text = '网络  —'
    $script:peerRows = @()
    $peerList.Items.Clear()
    $peersTab.Text = '设备 (0)'
    $details.Text = $reason
    $refreshInfo.Text = '自动刷新失败'
    if ($script:manualRefresh) { $message.Text = '状态刷新失败，请查看诊断详情。' }
}

function Start-StatusRead {
    $script:statusStarted = [DateTime]::UtcNow
    $script:statusOut = Join-Path $env:TEMP ('celium-status-' + [guid]::NewGuid().ToString('N') + '.out')
    $script:statusErr = Join-Path $env:TEMP ('celium-status-' + [guid]::NewGuid().ToString('N') + '.err')
    $script:statusTask = Start-ClientCommand @('status', '--view') $script:statusOut $script:statusErr
}

function Start-StatusRefresh([bool]$manual = $false) {
    if ($null -ne $script:task -or $null -ne $script:statusTask -or $script:updating) { return }
    $script:manualRefresh = $manual
    $script:statusStale = $false
    $script:nextRefresh = [DateTime]::UtcNow.AddSeconds(5)
    try {
        Start-StatusRead
    } catch {
        Show-StatusFailure $_.Exception.Message
        $script:manualRefresh = $false
        Finish-CeliumTask
    }
}

function Finish-CeliumTask {
    if ($null -eq $script:pendingTaskResult) { return }
    $result = $script:pendingTaskResult
    if ($result.Name -eq 'exit-node') {
        $script:pendingTaskResult = $null
        $progress.Visible = $false
        $connectButton.Enabled = $true
        $disconnectButton.Enabled = $true
        $script:lastOperationName = ''
        $message.Text = if ($result.ExitCode -eq 0) { '出口设置已更新' } else { '出口设置失败：' + $result.Output }
        return
    }
    $expectedState = if ($result.Name -eq 'down') { 'Stopped' } else { 'Running' }
    $succeeded = $script:currentBackendState -eq $expectedState
    if (-not $succeeded -and [DateTime]::UtcNow -lt $script:pendingTaskDeadline) {
        $message.Text = if ($result.Name -eq 'down') { '正在确认断开状态…' } else { '正在确认连接状态…' }
        $script:nextRefresh = [DateTime]::UtcNow.AddSeconds(1)
        return
    }
    $script:pendingTaskResult = $null
    $progress.Visible = $false
    $connectButton.Enabled = $true
    $disconnectButton.Enabled = $true
    if ($succeeded) {
        $script:lastOperationError = ''
        $script:lastOperationName = ''
        $message.Text = if ($result.Name -eq 'down') { '已断开' } else { '已连接' }
        $approvalButton.Visible = $false
    } elseif (-not $script:currentBackendState -and $result.ExitCode -eq 0) {
        $message.Text = if ($result.Name -eq 'down') {
            '断开命令已执行，正在自动确认状态。'
        } else {
            '连接命令已执行，正在自动确认状态。'
        }
    } else {
        $script:lastOperationError = [string]$result.Output
        if ($script:lastOperationError) {
            $details.Text = $script:lastOperationError + [Environment]::NewLine + [Environment]::NewLine + $details.Text
        }
        $message.Text = if ($result.Name -eq 'down') { '断开失败，请查看诊断详情。' } else { '连接未完成，请查看诊断详情。' }
        $tabs.SelectedTab = $detailsTab
    }
}

function Poll-StatusRefresh {
    if ($null -eq $script:statusTask) { return }
    if (-not $script:statusTask.HasExited) {
        if ([DateTime]::UtcNow - $script:statusStarted -le [TimeSpan]::FromSeconds(10)) { return }
        try { $script:statusTask.Kill() } catch { }
        $script:statusTask.Dispose()
        $script:statusTask = $null
        Remove-Item -LiteralPath $script:statusOut, $script:statusErr -Force -ErrorAction SilentlyContinue
        if ($script:statusStale -or $null -ne $script:task -or $script:updating) {
            $script:statusStale = $false
            $script:manualRefresh = $false
            if ($null -ne $script:pendingTaskResult) { Start-StatusRefresh $false }
            return
        }
        Show-StatusFailure '读取 Celium 状态超时（10 秒）；将自动重试。'
        $script:manualRefresh = $false
        Finish-CeliumTask
        $script:nextRefresh = [DateTime]::UtcNow.AddSeconds(5)
        return
    }

    $exitCode = $script:statusTask.ExitCode
    $stdout = ''
    $stderr = ''
    $readError = ''
    try {
        if (Test-Path -LiteralPath $script:statusOut) {
            $stdout = [string](Get-Content -LiteralPath $script:statusOut -Raw -Encoding UTF8)
        }
        if (Test-Path -LiteralPath $script:statusErr) {
            $stderr = [string](Get-Content -LiteralPath $script:statusErr -Raw -Encoding UTF8)
        }
    } catch {
        $readError = $_.Exception.Message
    } finally {
        $script:statusTask.Dispose()
        $script:statusTask = $null
        Remove-Item -LiteralPath $script:statusOut, $script:statusErr -Force -ErrorAction SilentlyContinue
    }
    if ($script:statusStale -or $null -ne $script:task -or $script:updating) {
        $script:manualRefresh = $false
        $script:statusStale = $false
        if ($null -ne $script:pendingTaskResult) { Start-StatusRefresh $false }
        return
    }
    if ($readError) {
        Show-StatusFailure ('读取状态文件失败：' + $readError)
        $script:manualRefresh = $false
        Finish-CeliumTask
        return
    }

    try {
        # A valid status snapshot is authoritative even when Windows reports a
        # nonzero process exit code after writing it. One read also avoids the
        # race between separate JSON and plain status commands.
        if (-not $stdout.Trim()) { throw ('状态输出为空。' + $stderr) }
        $status = $stdout | ConvertFrom-Json
        if ((Get-JsonMember $status 'Schema') -ne 1 -or -not (Get-JsonMember $status 'BackendState')) { throw '状态 JSON 缺少 BackendState。' }
        $wasReconciling = [bool]$script:lastOperationName
        Apply-NodeStatus $status $stdout
        if ($script:manualRefresh -and -not $wasReconciling -and $null -eq $script:pendingTaskResult) {
            $message.Text = '状态已刷新'
        }
    } catch {
        $reason = $_.Exception.Message
        if ($exitCode -ne 0 -and $stderr.Trim()) { $reason += [Environment]::NewLine + $stderr.Trim() }
        Show-StatusFailure $reason
    } finally {
        $script:manualRefresh = $false
        Finish-CeliumTask
    }
}

function Start-CeliumTask([string]$name, [string[]]$extra = @()) {
    if ($null -ne $script:task -or $null -ne $script:pendingTaskResult -or $script:updating) { return }
    $script:taskName = $name
    $script:lastOperationName = $name
    $script:statusStale = $null -ne $script:statusTask
    $script:lastOperationError = ''
    $script:taskOut = Join-Path $env:TEMP ('celium-' + [guid]::NewGuid().ToString('N') + '.out')
    $script:taskErr = Join-Path $env:TEMP ('celium-' + [guid]::NewGuid().ToString('N') + '.err')
    $details.Text = ''
    $script:diagnosticReport = ''
    $message.Text = if ($name -eq 'up') { '正在连接…' } else { '正在断开…' }
    if ($name -eq 'exit-node') { $message.Text = '正在应用出口设置…' }
    $progress.Visible = $true
    $connectButton.Enabled = $false
    $disconnectButton.Enabled = $false
    try {
        $script:task = Start-ClientCommand (@($name) + $extra) $script:taskOut $script:taskErr
    } catch {
        $message.Text = '操作失败：' + $_.Exception.Message
        $progress.Visible = $false
        $connectButton.Enabled = $true
        $disconnectButton.Enabled = $true
    }
}

$connectButton.Add_Click({ Start-CeliumTask 'up' })
$disconnectButton.Add_Click({ Start-CeliumTask 'down' })
$refreshButton.Add_Click({ Start-StatusRefresh $true })
$exitButton.Add_Click({
    if ($null -eq $script:lastView -or $null -ne $script:task -or $script:updating) { return }
    $panel = New-Object System.Windows.Forms.Form
    $panel.Text = 'Celium · 上网出口'; $panel.StartPosition = 'CenterParent'
    $panel.ClientSize = New-Object System.Drawing.Size(490, 310)
    $panel.FormBorderStyle = 'FixedDialog'; $panel.MaximizeBox = $false; $panel.MinimizeBox = $false
    $panel.BackColor = [System.Drawing.Color]::FromArgb(246,249,252)
    $panel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = '普通上网使用原来的网络。选择已批准的出口后，上网流量经该设备转发。出口不可用时可切回普通上网。'
    $caption.Location = New-Object System.Drawing.Point(22,20); $caption.Size = New-Object System.Drawing.Size(444,65); $panel.Controls.Add($caption)
    $choices = New-Object System.Windows.Forms.ComboBox
    $choices.DropDownStyle = 'DropDownList'; $choices.DisplayMember = 'Label'
    $choices.Location = New-Object System.Drawing.Point(22,94); $choices.Size = New-Object System.Drawing.Size(444,32)
    [void]$choices.Items.Add([pscustomobject]@{ Label='普通上网'; ID='none'; Online=$true })
    $selected = [string](Get-JsonMember $script:lastView 'ExitNodeID')
    $choices.SelectedIndex = 0
    foreach ($exit in @(Get-JsonMember $script:lastView 'ExitNodes')) {
        if ($null -eq $exit) { continue }
        $id = [string](Get-JsonMember $exit 'ID')
        if ($id -notmatch '^[A-Za-z0-9_-]{1,128}$') { continue }
        $online = [bool](Get-JsonMember $exit 'Online')
        $label = [string](Get-JsonMember $exit 'Name') + ' · ' + [string](Get-JsonMember $exit 'Address')
        if (-not $online) { $label += ' · 离线' }
        $index = $choices.Items.Add([pscustomobject]@{Label=$label;ID=$id;Online=$online})
        if ($id -eq $selected) { $choices.SelectedIndex = $index }
    }
    if ($selected -ne "" -and $choices.SelectedIndex -eq 0) {
        $choices.SelectedIndex = $choices.Items.Add([pscustomobject]@{Label="当前出口已不可用 · 可切回普通上网";ID=$selected;Online=$false})
    }
    $panel.Controls.Add($choices)
    $offer = New-Object System.Windows.Forms.CheckBox
    $offer.Text = '提供本机作为出口（需要管理员批准）'
    $offer.Checked = [bool](Get-JsonMember $script:lastView 'AdvertiseExitNode')
    if ($script:storeMode) { $offer.Checked = $false; $offer.Enabled = $false; $offer.Text = '商店版可使用出口；提供出口请使用 EXE 版' }
    $offer.Location = New-Object System.Drawing.Point(22,147); $offer.Size = New-Object System.Drawing.Size(444,30); $panel.Controls.Add($offer)
    $help = New-Object System.Windows.Forms.Label
    $help.Text = if (Get-JsonMember $script:lastView 'ExitNodeApproved') { '管理员已批准。保持 Windows 在线且不要休眠。' } else { '先在出口设备开启提供出口，再由管理员在设备详情中批准。' }
    $help.Location = New-Object System.Drawing.Point(22,187); $help.Size = New-Object System.Drawing.Size(444,50); $panel.Controls.Add($help)
    $apply = New-Object System.Windows.Forms.Button
    $apply.Text = '应用'; $apply.Location = New-Object System.Drawing.Point(342,252); $apply.Size = New-Object System.Drawing.Size(124,36)
    $apply.BackColor = $script:green; $apply.ForeColor = [System.Drawing.Color]::White; $panel.Controls.Add($apply)
    $script:exitChoiceBox = $choices; $script:exitOfferBox = $offer; $script:exitHelp = $help; $script:exitPanel = $panel
    $apply.Add_Click({
        $choice = $script:exitChoiceBox.SelectedItem
        if ($null -eq $choice) { return }
        if (-not $choice.Online) { $script:exitHelp.Text = '该出口设备离线，请选择在线出口或普通上网。'; return }
        if ($script:exitOfferBox.Checked -and $choice.ID -ne 'none') { $script:exitHelp.Text = '提供本机作为出口前，请先选择普通上网。'; return }
        Start-CeliumTask 'exit-node' @(('--advertise=' + $script:exitOfferBox.Checked.ToString().ToLowerInvariant()), [string]$choice.ID)
        $script:exitPanel.Close()
    })
    [void]$panel.ShowDialog($form); $panel.Dispose()
})
$approvalButton.Add_Click({
    if ($script:approvalURL -match '^https://') { Start-Process $script:approvalURL }
})

function Start-UpdateCheck([bool]$manual) {
    if ($script:storeMode) {
        if ($manual) {
            Start-Process 'ms-windows-store://downloadsandupdates'
            $message.Text = '已打开 Microsoft Store，更新由商店管理。'
        }
        return
    }
    if ($null -ne $script:checkTask -or $script:updating) { return }
    $script:nextUpdateCheck = [DateTime]::UtcNow.AddHours(1)
    $script:checkManual = $manual
    $script:checkStarted = [DateTime]::UtcNow
    $script:checkOut = Join-Path $env:TEMP ('celium-check-' + [guid]::NewGuid().ToString('N') + '.json')
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = Join-Path $script:installDir 'Check-CeliumUpdate.ps1'
    try {
        $script:checkTask = Start-Process -FilePath $powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -OutputFile "' + $script:checkOut + '"') -WindowStyle Hidden -PassThru
        if ($manual) { $message.Text = '正在后台检查更新；你可以继续使用客户端。' }
    } catch { if ($manual) { $message.Text = '检查更新未启动：' + $_.Exception.Message } }
}
$checkButton.Add_Click({ Start-UpdateCheck $true })

$updateButton.Add_Click({
    if ($script:storeMode) { Start-UpdateCheck $true; return }
    if ($script:updating) { return }
    $script:updating = $true
    $script:updateStarted = [DateTime]::UtcNow
    $message.Text = '正在更新：等待管理员授权…'
    $progress.Visible = $true
    $updateButton.Enabled = $false
    $checkButton.Enabled = $false
    $connectButton.Enabled = $false
    $disconnectButton.Enabled = $false
    $form.Refresh()
    try {
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $scriptPath = Join-Path $script:installDir 'Update-Celium.ps1'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -StatusFile "' + $script:statusFile + '"'
        $script:updater = Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $arguments `
            -WindowStyle Hidden -PassThru
    } catch {
        $script:updating = $false
        $progress.Visible = $false
        $message.Text = '更新未开始：' + $_.Exception.Message
        $checkButton.Enabled = $true
        $updateButton.Enabled = $true
        $connectButton.Enabled = $true
        $disconnectButton.Enabled = $true
    }
})

function Poll-CeliumTasks {
    if ($null -ne $script:checkTask) {
        if ($script:checkTask.HasExited -or [DateTime]::UtcNow -gt $script:checkStarted.AddSeconds(25)) {
            try {
                if (-not $script:checkTask.HasExited) { $script:checkTask.Kill(); throw '检查更新超时。' }
                $latest = Get-Content $script:checkOut -Raw -Encoding UTF8 | ConvertFrom-Json
                if (Get-JsonMember $latest 'error') { throw ([string]$latest.error) }
                $current = Read-Release
                if ([int]$latest.schema -ne 1 -or $null -eq $latest.packages.PSObject.Properties[[string]$current.arch]) { throw '更新清单不支持此设备。' }
                $available = [int64]$latest.build -gt [int64]$current.build
                $updateButton.Enabled = $available -and -not $script:updating
                if ($available -and $null -eq $script:task -and $null -eq $script:diagnosticTask) { $message.Text = '发现新版本 ' + [string]$latest.version + '，点击“立即更新”。' }
                elseif ($script:checkManual) { $message.Text = '当前已是最新版本。' }
            } catch { if ($script:checkManual) { $message.Text = '检查更新失败：' + $_.Exception.Message } }
            finally { $script:checkTask.Dispose(); $script:checkTask = $null; Remove-Item $script:checkOut -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($null -ne $script:diagnosticTask) {
        if ($script:diagnosticTask.HasExited -or [DateTime]::UtcNow -gt $script:diagnosticStarted.AddSeconds(20)) {
            try {
                if (-not $script:diagnosticTask.HasExited) { $script:diagnosticTask.Kill(); throw '测试超时，请检查网络。' }
                $raw = [string](Get-Content $script:diagnosticOut -Raw -Encoding UTF8)
                $report = $raw | ConvertFrom-Json
                $message.Text = [string]$report.Test.Message
                $details.Text = $raw
                $script:diagnosticReport = $raw
            } catch { $message.Text = '测试未完成：' + $_.Exception.Message }
            finally {
                $script:diagnosticTask.Dispose(); $script:diagnosticTask = $null
                $progress.Visible = $false
                Remove-Item $script:diagnosticOut, $script:diagnosticErr -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($null -ne $script:task) {
        $taskEncoding = if ($script:storeMode) { 'UTF8' } else { 'Default' }
        $stdout = if (Test-Path -LiteralPath $script:taskOut) { Get-Content -LiteralPath $script:taskOut -Raw -Encoding $taskEncoding } else { '' }
        $stderr = if (Test-Path -LiteralPath $script:taskErr) { Get-Content -LiteralPath $script:taskErr -Raw -Encoding $taskEncoding } else { '' }
        $details.Text = ($stdout + [Environment]::NewLine + $stderr).Trim()
        if ($details.Text -match 'https://[^\s]+/a/[A-Za-z0-9_-]+') {
            $script:approvalURL = $matches[0]
            $approvalButton.Visible = $true
            $message.Text = '请打开授权页面并批准此设备；客户端会继续连接。'
        }
        if ($script:task.HasExited) {
            $exitCode = $script:task.ExitCode
            $taskOutput = $details.Text
            $script:task.Dispose()
            $script:task = $null
            $script:pendingTaskResult = [pscustomobject]@{
                Name = $script:taskName
                ExitCode = $exitCode
                Output = $taskOutput
            }
            $script:pendingTaskDeadline = [DateTime]::UtcNow.AddSeconds(12)
            if ($null -eq $script:statusTask) { Start-StatusRefresh $false }
            Remove-Item -LiteralPath $script:taskOut, $script:taskErr -Force -ErrorAction SilentlyContinue
        }
    }
    if ($script:updating) {
        $state = $null
        try {
            if (Test-Path -LiteralPath $script:statusFile) {
                $candidate = Get-Content -LiteralPath $script:statusFile -Raw | ConvertFrom-Json
                if ([DateTime]::Parse([string]$candidate.at).ToUniversalTime() -ge $script:updateStarted.AddSeconds(-2)) {
                    $state = $candidate
                    $message.Text = [string]$state.message
                }
            }
        } catch { }
        if ($null -ne $state -and [string]$state.state -in @('complete', 'error')) {
            $script:updating = $false
            $progress.Visible = $false
            $checkButton.Enabled = $true
            $connectButton.Enabled = $true
            $disconnectButton.Enabled = $true
            $script:versionLabel.Text = '版本 ' + [string]((Read-Release).version)
            Start-StatusRefresh $false
            if ([string]$state.state -eq 'complete' -and [string]$state.message -like '更新完成：*') {
                $script:relaunchAfterUpdate = $true
                $form.Close()
                return
            }
        } elseif ($null -ne $script:updater -and $script:updater.HasExited) {
            $script:updating = $false
            $progress.Visible = $false
            $checkButton.Enabled = $true
            $connectButton.Enabled = $true
            $disconnectButton.Enabled = $true
            $message.Text = '更新进程提前结束，请重新检查更新；已显示的进度不会被当作完成。'
        } elseif ([DateTime]::UtcNow - $script:updateStarted -gt [TimeSpan]::FromMinutes(20)) {
            $script:updating = $false
            $progress.Visible = $false
            $checkButton.Enabled = $true
            $connectButton.Enabled = $true
            $disconnectButton.Enabled = $true
            $message.Text = '更新长时间没有完成，请检查 Celium 服务或重新尝试。'
        }
    }
}

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 200
$script:nextRefresh = [DateTime]::UtcNow.AddSeconds(5)
$pollTimer.Add_Tick({
    try {
        Poll-CeliumTasks
        Poll-StatusRefresh
        if (-not $script:storeMode -and [DateTime]::UtcNow -ge $script:nextUpdateCheck) { Start-UpdateCheck $false }
        if ([DateTime]::UtcNow -ge $script:nextRefresh) { Start-StatusRefresh $false }
    } catch {
        $message.Text = '客户端操作失败：' + $_.Exception.Message
        $progress.Visible = $false
        $script:nextRefresh = [DateTime]::UtcNow.AddSeconds(5)
    }
})
$form.Add_Shown({
    Start-StatusRefresh $false
    $pollTimer.Start()
})
$form.Add_FormClosing({ $pollTimer.Stop() })

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    $pollTimer.Stop()
    $pollTimer.Dispose()
    if ($null -ne $script:task) { $script:task.Dispose() }
    if ($null -ne $script:statusTask) { $script:statusTask.Dispose() }
    Remove-Item -LiteralPath $script:statusOut, $script:statusErr -Force -ErrorAction SilentlyContinue
    if ($null -ne $script:updater) { $script:updater.Dispose() }
    if ($null -ne $script:diagnosticTask) { try { $script:diagnosticTask.Kill() } catch { }; $script:diagnosticTask.Dispose() }
    if ($null -ne $script:checkTask) { try { $script:checkTask.Kill() } catch { }; $script:checkTask.Dispose() }
    $peerActions.Dispose()
    $searchTip.Dispose()
    $tray.Visible = $false
    $tray.Dispose()
    $trayMenu.Dispose()
    $logo.Image.Dispose()
    $form.Dispose()
    $script:icon.Dispose()
    if ($script:relaunchAfterUpdate) {
        Start-Process -FilePath (Join-Path $script:installDir 'CeliumDesktop.exe')
    }
}
