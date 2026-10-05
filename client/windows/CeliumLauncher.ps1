param([switch]$Store)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'CeliumClient.ps1') -Store:$Store
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        ('Celium 客户端启动失败：' + [Environment]::NewLine + [string]$_),
        'Celium 启动失败',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
