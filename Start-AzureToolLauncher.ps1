#Requires -Version 7.4
<#
.SYNOPSIS
    Console launcher for ALZ AutoPilot, FinOps Multitool TUI and Azure ResourceTagger.
.DESCRIPTION
    Uses existing local tool installations. Each tool gets its own PowerShell
    window. FTKLocal is optional; tools retain their own authentication and checks.
.PARAMETER ConfigPath
    Local PSD1 configuration. Relative tool paths resolve against this file.
.PARAMETER Tool
    Open the menu (default), or execute one tool in the current process.
.PARAMETER Check
    Validate configured entry points without launching tools or contacting Azure.
.EXAMPLE
    .\Start-AzureToolLauncher.ps1 -Check
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive colored console menu; status is intentionally host output.')]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'launcher.local.psd1'),
    [ValidateSet('Menu', 'ALZ', 'FinOps', 'FTKLocal', 'ResourceTagger')]
    [string]$Tool = 'Menu',
    [switch]$Check
)

function Read-LauncherConfiguration {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration not found: $Path. Copy launcher.example.psd1 to launcher.local.psd1 and set your tool paths."
    }
    $settings = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    $directory = Split-Path ([System.IO.Path]::GetFullPath($Path, $PWD.ProviderPath))
    $keys = @('ALZScript', 'FinOpsToolkitRoot', 'ResourceTaggerScript', 'FTKLocalScript')
    foreach ($key in $settings.Keys) {
        if ($key -notin $keys) { throw "Unknown configuration key '$key' in $Path." }
        if ($settings[$key] -isnot [string]) { throw "Configuration value '$key' must be a string." }
    }
    $result = @{}
    foreach ($key in $keys) {
        $value = $settings[$key]
        $result[$key] = if ([string]::IsNullOrWhiteSpace($value)) {
            ''
        }
        else {
            [System.IO.Path]::GetFullPath($value, $directory)
        }
    }
    return $result
}

function Get-LauncherTarget {
    param(
        [Parameter(Mandatory)][ValidateSet('ALZ', 'FinOps', 'FTKLocal', 'ResourceTagger')][string]$Tool,
        [Parameter(Mandatory)][hashtable]$Configuration
    )

    $key = switch ($Tool) {
        ALZ { 'ALZScript' }
        FinOps { 'FinOpsToolkitRoot' }
        FTKLocal { 'FTKLocalScript' }
        ResourceTagger { 'ResourceTaggerScript' }
    }
    if ([string]::IsNullOrWhiteSpace($Configuration[$key])) {
        throw "Set '$key' in your local configuration before launching $Tool."
    }
    $target = @{ Script = $Configuration[$key] }
    $required = @()
    if ($Tool -in @('FinOps', 'FTKLocal')) {
        $repo = $Configuration.FinOpsToolkitRoot
        if ([string]::IsNullOrWhiteSpace($repo)) { throw 'Set FinOpsToolkitRoot to a standalone TUI download or FinOps toolkit source checkout.' }
        $moduleRoot = Join-Path $repo 'src\powershell'
        $sourceStarter = Join-Path $moduleRoot 'Public\Start-FinOpsMultitool.ps1'
        if (-not (Test-Path -LiteralPath $sourceStarter -PathType Leaf)) {
            if ($Tool -eq 'FTKLocal') {
                throw 'FTKLocal requires FinOpsToolkitRoot to use the toolkit source layout (src\powershell). The standalone TUI download supports the live option only; leave FTKLocalScript empty if not used.'
            }
            $moduleRoot = $repo
        }
        $starter = Join-Path $moduleRoot 'Public\Start-FinOpsMultitool.ps1'
        $required += $starter
        $required += Join-Path $moduleRoot 'Private\FinOpsMultitool\Invoke-FinOpsMultitool.ps1'
        $required += Join-Path $moduleRoot 'Private\FinOpsMultitool\FinOpsMultitool.psm1'
        $target.ToolkitRoot = $repo
        if ($Tool -eq 'FinOps') { $target.Script = $starter }
    }
    if ($Tool -eq 'FTKLocal') {
        $demoRoot = Split-Path $target.Script
        $required += Join-Path $demoRoot 'Start-LocalHubTUI.ps1'
        $required += Join-Path $demoRoot 'Setup-LocalFinOpsHub.ps1'
    }
    $required += $target.Script
    foreach ($file in $required) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Missing file for ${Tool}: $file. Check your configuration and tool installation."
        }
    }
    return $target
}

function Invoke-LauncherTool {
    param(
        [Parameter(Mandatory)][ValidateSet('ALZ', 'FinOps', 'FTKLocal', 'ResourceTagger')][string]$Tool,
        [Parameter(Mandatory)][hashtable]$Target
    )

    Push-Location -LiteralPath (Split-Path $Target.Script) -ErrorAction Stop
    try {
        switch ($Tool) {
            FinOps {
                $oldUri = $env:FINOPS_HUB_KUSTO_URI
                $oldDatabase = $env:FINOPS_HUB_KUSTO_DB
                try {
                    # A live session must not inherit a previous local-demo endpoint.
                    $env:FINOPS_HUB_KUSTO_URI = $null
                    $env:FINOPS_HUB_KUSTO_DB = $null
                    . $Target.Script
                    Start-FinOpsMultitool
                }
                finally {
                    $env:FINOPS_HUB_KUSTO_URI = $oldUri
                    $env:FINOPS_HUB_KUSTO_DB = $oldDatabase
                }
            }
            FTKLocal { & $Target.Script -RepoRoot $Target.ToolkitRoot }
            default { & $Target.Script }
        }
    }
    finally { Pop-Location }
}

function Start-LauncherWindow {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('ALZ', 'FinOps', 'FTKLocal', 'ResourceTagger')][string]$Tool,
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$LauncherPath
    )

    $target = Get-LauncherTarget -Tool $Tool -Configuration $Configuration
    # Re-enter via -File so configured paths are data, never interpolated PowerShell code.
    $arguments = @(
        '-NoLogo', '-NoProfile', '-STA', '-NoExit',
        '-File', "`"$LauncherPath`"", '-ConfigPath', "`"$ConfigPath`"", '-Tool', $Tool
    )
    if ($PSCmdlet.ShouldProcess($target.Script, 'Launch in a separate PowerShell window')) {
        $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $arguments `
            -WorkingDirectory (Split-Path $target.Script) -PassThru -ErrorAction Stop
        Write-Host "  Opened $Tool in a separate window (PID $($process.Id)). Check that window for startup errors." -ForegroundColor Green
    }
}

function Read-LauncherChoice {
    param([string]$Prompt)
    if ([Console]::IsInputRedirected) {
        $value = [Console]::ReadLine()
        if ($null -eq $value) { throw 'Launcher input closed before Quit was selected.' }
    }
    else { $value = Read-Host $Prompt }
    return ([string]$value).Trim().ToUpperInvariant()
}

function Show-LauncherMenu {
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$LauncherPath
    )
    while ($true) {
        Write-Host "`n  ================================================================" -ForegroundColor Cyan
        Write-Host '   AZURE TOOL LAUNCHER' -ForegroundColor Cyan
        Write-Host '  ================================================================' -ForegroundColor Cyan
        Write-Host '  [1] ALZ AutoPilot        - guided ALZ Accelerator delivery'
        Write-Host '  [2] FinOps Multitool TUI - terminal UI (+ optional FTKLocal demo)'
        Write-Host '  [3] Azure ResourceTagger - scan and bulk-apply resource tags'
        Write-Host '  [Q] Quit'
        $selection = switch (Read-LauncherChoice '  Select a tool') {
            '1' { 'ALZ' }
            '2' {
                while ($true) {
                    Write-Host "`n  --- FinOps Multitool TUI ---" -ForegroundColor Cyan
                    Write-Host '  [1] Live / connected environment - choose data source in the TUI'
                    Write-Host '  [2] Local demo (FTKLocal)'
                    Write-Host '      Hub data is synthetic; other scans can query your REAL Azure tenant.' -ForegroundColor Yellow
                    Write-Host '      First run may download images/data and create a local container.'
                    Write-Host '  [B] Back'
                    $choice = Read-LauncherChoice '  Select an option'
                    if ($choice -eq '1') { 'FinOps'; break }
                    if ($choice -eq '2') { 'FTKLocal'; break }
                    if ($choice -eq 'B') { break }
                    Write-Host '  Not a valid choice.' -ForegroundColor Yellow
                }
            }
            '3' { 'ResourceTagger' }
            'Q' { return }
            default { Write-Host '  Not a valid choice.' -ForegroundColor Yellow }
        }
        if ($selection) {
            try {
                Start-LauncherWindow -Tool $selection -Configuration $Configuration -ConfigPath $ConfigPath -LauncherPath $LauncherPath
            }
            catch {
                Write-Host "  Launch failed: $($_.Exception.Message)" -ForegroundColor Red
                $null = Read-LauncherChoice '  Press Enter to return to the menu'
            }
        }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This launcher requires Windows (Azure ResourceTagger uses WPF).' }
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath, $PWD.ProviderPath)
$configuration = Read-LauncherConfiguration -Path $ConfigPath
if ($Check) {
    $failed = $false
    foreach ($name in @('ALZ', 'FinOps', 'ResourceTagger', 'FTKLocal')) {
        if ($name -eq 'FTKLocal' -and -not $configuration.FTKLocalScript) {
            [pscustomobject]@{ Tool = $name; Status = 'Optional / not configured'; Detail = '' }
            continue
        }
        try {
            $target = Get-LauncherTarget -Tool $name -Configuration $configuration
            [pscustomobject]@{ Tool = $name; Status = 'Ready'; Detail = $target.Script }
        }
        catch {
            $failed = $true
            [pscustomobject]@{ Tool = $name; Status = 'Unavailable'; Detail = $_.Exception.Message }
        }
    }
    if ($failed) { throw 'One or more configured tools are unavailable. Correct the reported paths.' }
}
elseif ($Tool -eq 'Menu') {
    Show-LauncherMenu -Configuration $configuration -ConfigPath $ConfigPath -LauncherPath $PSCommandPath
}
else {
    Invoke-LauncherTool -Tool $Tool -Target (Get-LauncherTarget -Tool $Tool -Configuration $configuration)
}
