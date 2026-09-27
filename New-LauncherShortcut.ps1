#Requires -Version 7.4
<#
.SYNOPSIS
    Creates a desktop shortcut using this checkout and the current PowerShell host.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'launcher.local.psd1'),
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Azure Tool Launcher.lnk'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Desktop shortcuts require Windows.' }
$launcher = Join-Path $PSScriptRoot 'Start-AzureToolLauncher.ps1'
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath, $PWD.ProviderPath)
$ShortcutPath = [System.IO.Path]::GetFullPath($ShortcutPath, $PWD.ProviderPath)
foreach ($file in @($launcher, $ConfigPath)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing file: $file" }
}
if ([System.IO.Path]::GetExtension($ShortcutPath) -ne '.lnk') { throw 'ShortcutPath must end in .lnk.' }
if ((Test-Path -LiteralPath $ShortcutPath) -and -not $Force) {
    throw "Shortcut already exists: $ShortcutPath. Use -Force to replace it."
}
if ($PSCmdlet.ShouldProcess($ShortcutPath, 'Create launcher shortcut')) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $null
    try {
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = Join-Path $PSHOME 'pwsh.exe'
        $shortcut.Arguments = "-NoLogo -NoProfile -NoExit -File `"$launcher`" -ConfigPath `"$ConfigPath`""
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.IconLocation = "$(Join-Path $PSHOME 'pwsh.exe'),0"
        $shortcut.Description = 'ALZ AutoPilot, FinOps Multitool TUI (+FTKLocal), Azure ResourceTagger'
        $shortcut.Save()
        Write-Output "Created: $ShortcutPath"
    }
    finally {
        if ($null -ne $shortcut) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}
