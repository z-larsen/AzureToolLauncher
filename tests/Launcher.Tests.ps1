BeforeAll {
    $launcher = Join-Path $PSScriptRoot '..\Start-AzureToolLauncher.ps1'
    . $launcher

    function New-TestToolFile {
        param([string]$Path, [string]$Content = '# Test fixture')
        $null = New-Item -ItemType Directory -Path (Split-Path $Path) -Force
        Set-Content -LiteralPath $Path -Value $Content
        return $Path
    }

    $root = Join-Path $TestDrive "Tools with spaces [demo] O'Brien"
    $config = @{
        ALZScript = New-TestToolFile (Join-Path $root 'ALZ\Start-ALZDelivery.ps1')
        FinOpsToolkitRoot = Join-Path $root 'finops-toolkit'
        ResourceTaggerScript = New-TestToolFile (Join-Path $root 'Tagger\Start-ResourceTagger.ps1')
        FTKLocalScript = New-TestToolFile (Join-Path $root 'FTKLocal\Start-DemoEnvironment.ps1')
    }
    $starter = New-TestToolFile (Join-Path $config.FinOpsToolkitRoot 'src\powershell\Public\Start-FinOpsMultitool.ps1') @'
function Start-FinOpsMultitool {
    $env:LAUNCHER_TEST_TUI = 'invoked'
    $env:LAUNCHER_TEST_HUB = if ($env:FINOPS_HUB_KUSTO_URI) { 'inherited' } else { 'cleared' }
}
'@
    $null = New-TestToolFile (Join-Path $config.FinOpsToolkitRoot 'src\powershell\Private\FinOpsMultitool\Invoke-FinOpsMultitool.ps1')
    $null = New-TestToolFile (Join-Path $config.FinOpsToolkitRoot 'src\powershell\Private\FinOpsMultitool\FinOpsMultitool.psm1')
    $null = New-TestToolFile (Join-Path $root 'FTKLocal\Start-LocalHubTUI.ps1')
    $null = New-TestToolFile (Join-Path $root 'FTKLocal\Setup-LocalFinOpsHub.ps1')
}

Describe 'Portable configuration' {
    It 'resolves a relative config filename from the PowerShell working directory' {
        $path = New-TestToolFile (Join-Path $TestDrive 'relative-settings\launcher.local.psd1') "@{ ALZScript = '..\ALZ\Start-ALZDelivery.ps1' }"
        Push-Location -LiteralPath (Split-Path $path)
        try {
            (Read-LauncherConfiguration -Path '.\launcher.local.psd1').ALZScript |
                Should -Be (Join-Path $TestDrive 'ALZ\Start-ALZDelivery.ps1')
        }
        finally { Pop-Location }
    }

    It 'resolves relative paths against the config folder, not the current directory' {
        $path = New-TestToolFile (Join-Path $TestDrive 'settings\launcher.local.psd1') @'
@{
    ALZScript = '..\ALZ\Start-ALZDelivery.ps1'
    FinOpsToolkitRoot = '..\finops-toolkit'
    ResourceTaggerScript = '..\Tagger\Start-ResourceTagger.ps1'
    FTKLocalScript = ''
}
'@
        $result = Read-LauncherConfiguration -Path $path
        $result.ALZScript | Should -Be (Join-Path $TestDrive 'ALZ\Start-ALZDelivery.ps1')
        $result.FTKLocalScript | Should -Be ''
    }

    It 'preserves absolute paths containing spaces, apostrophes and brackets' {
        $path = New-TestToolFile (Join-Path $TestDrive 'absolute.psd1') (
            "@{ ALZScript = '$($config.ALZScript.Replace("'", "''"))' }"
        )
        (Read-LauncherConfiguration -Path $path).ALZScript | Should -Be $config.ALZScript
    }

    It 'explains how to create a missing local configuration' {
        { Read-LauncherConfiguration -Path (Join-Path $TestDrive 'missing.psd1') } |
            Should -Throw '*launcher.example.psd1*'
    }

    It 'rejects misspelled keys instead of silently ignoring them' {
        $path = New-TestToolFile (Join-Path $TestDrive 'typo.psd1') "@{ FinOpsRoot = 'x' }"
        { Read-LauncherConfiguration -Path $path } | Should -Throw '*Unknown configuration key*'
    }

    It 'rejects non-string path values' {
        $path = New-TestToolFile (Join-Path $TestDrive 'invalid.psd1') '@{ ALZScript = 42 }'
        { Read-LauncherConfiguration -Path $path } | Should -Throw '*must be a string*'
    }
}

Describe 'Tool resolution and execution' {
    It 'selects the public TUI function file, not the old WPF application' {
        $target = Get-LauncherTarget -Tool FinOps -Configuration $config
        $target.Script | Should -Be $starter
        $target.Script | Should -Not -Match 'AzureFinOpsScanner'
    }

    It 'retains the ALZ and ResourceTagger entry points' {
        (Get-LauncherTarget -Tool ALZ -Configuration $config).Script | Should -Be $config.ALZScript
        (Get-LauncherTarget -Tool ResourceTagger -Configuration $config).Script | Should -Be $config.ResourceTaggerScript
    }

    It 'recognizes a complete standalone public preview download' {
        $standalone = $config.Clone()
        $standalone.FinOpsToolkitRoot = Join-Path $TestDrive 'standalone preview'
        $public = New-TestToolFile (Join-Path $standalone.FinOpsToolkitRoot 'Public\Start-FinOpsMultitool.ps1')
        $null = New-TestToolFile (Join-Path $standalone.FinOpsToolkitRoot 'Private\FinOpsMultitool\Invoke-FinOpsMultitool.ps1')
        $null = New-TestToolFile (Join-Path $standalone.FinOpsToolkitRoot 'Private\FinOpsMultitool\FinOpsMultitool.psm1')
        (Get-LauncherTarget -Tool FinOps -Configuration $standalone).Script | Should -Be $public
        { Get-LauncherTarget -Tool FTKLocal -Configuration $standalone } |
            Should -Throw '*FTKLocal requires*toolkit source layout*'
    }

    It 'rejects a standalone download missing its private implementation' {
        $standalone = $config.Clone()
        $standalone.FinOpsToolkitRoot = Join-Path $TestDrive 'incomplete standalone'
        $null = New-TestToolFile (Join-Path $standalone.FinOpsToolkitRoot 'Public\Start-FinOpsMultitool.ps1')
        { Get-LauncherTarget -Tool FinOps -Configuration $standalone } |
            Should -Throw '*Invoke-FinOpsMultitool.ps1*'
    }

    It 'prefers source layout over standalone layout when both are present' {
        $null = New-TestToolFile (Join-Path $config.FinOpsToolkitRoot 'Public\Start-FinOpsMultitool.ps1')
        (Get-LauncherTarget -Tool FinOps -Configuration $config).Script | Should -Be $starter
    }

    It 'treats FTKLocal as optional but fails clearly when selected unconfigured' {
        $withoutDemo = $config.Clone()
        $withoutDemo.FTKLocalScript = ''
        { Get-LauncherTarget -Tool FTKLocal -Configuration $withoutDemo } | Should -Throw '*FTKLocalScript*'
        { Get-LauncherTarget -Tool FinOps -Configuration $withoutDemo } | Should -Not -Throw
    }

    It 'rejects an incomplete FinOps source checkout' {
        $incomplete = $config.Clone()
        $incomplete.FinOpsToolkitRoot = Join-Path $TestDrive 'incomplete'
        $null = New-TestToolFile (Join-Path $incomplete.FinOpsToolkitRoot 'src\powershell\Public\Start-FinOpsMultitool.ps1')
        { Get-LauncherTarget -Tool FinOps -Configuration $incomplete } | Should -Throw '*Invoke-FinOpsMultitool.ps1*'
    }

    It 'does not treat a directory as an executable script' {
        $invalid = $config.Clone()
        $invalid.ALZScript = $root
        { Get-LauncherTarget -Tool ALZ -Configuration $invalid } | Should -Throw '*Missing file*'
    }

    It 'actually calls the TUI function and clears inherited local hub overrides only during the run' {
        $oldUri = $env:FINOPS_HUB_KUSTO_URI
        $oldDb = $env:FINOPS_HUB_KUSTO_DB
        $location = Get-Location
        try {
            $env:FINOPS_HUB_KUSTO_URI = 'http://localhost:8082'
            $env:FINOPS_HUB_KUSTO_DB = 'Hub'
            Invoke-LauncherTool -Tool FinOps -Target (Get-LauncherTarget -Tool FinOps -Configuration $config)
            $env:LAUNCHER_TEST_TUI | Should -Be 'invoked'
            $env:LAUNCHER_TEST_HUB | Should -Be 'cleared'
            $env:FINOPS_HUB_KUSTO_URI | Should -Be 'http://localhost:8082'
            $env:FINOPS_HUB_KUSTO_DB | Should -Be 'Hub'
            (Get-Location).Path | Should -Be $location.Path
        }
        finally {
            $env:FINOPS_HUB_KUSTO_URI = $oldUri
            $env:FINOPS_HUB_KUSTO_DB = $oldDb
            $env:LAUNCHER_TEST_TUI = $null
            $env:LAUNCHER_TEST_HUB = $null
        }
    }

    It 'passes the configured toolkit root to FTKLocal instead of using its personal default' {
        $demo = New-TestToolFile (Join-Path $TestDrive 'demo\Start-DemoEnvironment.ps1') @'
param([string]$RepoRoot)
$env:LAUNCHER_TEST_REPO = $RepoRoot
'@
        try {
            Invoke-LauncherTool -Tool FTKLocal -Target @{
                Script = $demo
                ToolkitRoot = $config.FinOpsToolkitRoot
            }
            $env:LAUNCHER_TEST_REPO | Should -Be $config.FinOpsToolkitRoot
        }
        finally { $env:LAUNCHER_TEST_REPO = $null }
    }

    It 'propagates child tool errors and restores the working directory' {
        $bad = New-TestToolFile (Join-Path $TestDrive 'bad\Start-ALZDelivery.ps1') "throw 'Tool failed'"
        $location = Get-Location
        { Invoke-LauncherTool -Tool ALZ -Target @{ Script = $bad } } | Should -Throw '*Tool failed*'
        (Get-Location).Path | Should -Be $location.Path
    }
}

Describe 'Process launch and menu' {
    BeforeEach {
        Mock Start-Process { [pscustomobject]@{ Id = 12345 } }
        Mock Write-Host {}
        Mock Read-LauncherChoice { 'Q' }
    }

    It 'quotes the launcher and config paths and starts a clean STA PowerShell window' {
        Start-LauncherWindow -Tool FinOps -Configuration $config -ConfigPath 'C:\My tools\launcher.local.psd1' -LauncherPath 'C:\My tools\Start-AzureToolLauncher.ps1'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq (Join-Path $PSHOME 'pwsh.exe') -and
            $ArgumentList -contains '-NoProfile' -and
            $ArgumentList -contains '-STA' -and
            $ArgumentList -contains '-NoExit' -and
            $ArgumentList -contains '"C:\My tools\Start-AzureToolLauncher.ps1"' -and
            $ArgumentList -contains '"C:\My tools\launcher.local.psd1"' -and
            $ArgumentList -contains 'FinOps'
        }
    }

    It 'does not spawn a process for a missing tool' {
        $invalid = $config.Clone()
        $invalid.ALZScript = Join-Path $TestDrive 'absent.ps1'
        { Start-LauncherWindow -Tool ALZ -Configuration $invalid -ConfigPath 'x' -LauncherPath $launcher } |
            Should -Throw '*Missing file*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'does not spawn a process under WhatIf' {
        Start-LauncherWindow -Tool FinOps -Configuration $config -ConfigPath 'x' -LauncherPath $launcher -WhatIf
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'surfaces process creation failure' {
        Mock Start-Process { throw 'Process creation failed' }
        { Start-LauncherWindow -Tool FinOps -Configuration $config -ConfigPath 'x' -LauncherPath $launcher } |
            Should -Throw '*Process creation failed*'
    }

    It 'routes each menu choice and returns from the FinOps submenu' {
        $script:choices = [System.Collections.Generic.Queue[string]]::new()
        foreach ($choice in @('invalid', '1', '2', 'bad', '1', '2', '2', '2', 'B', '3', 'Q')) {
            $script:choices.Enqueue($choice)
        }
        Mock Read-LauncherChoice { $script:choices.Dequeue() }
        Mock Start-LauncherWindow {}
        Show-LauncherMenu -Configuration $config -ConfigPath 'x' -LauncherPath $launcher
        foreach ($expected in @('ALZ', 'FinOps', 'FTKLocal', 'ResourceTagger')) {
            Should -Invoke Start-LauncherWindow -Times 1 -Exactly -ParameterFilter { $Tool -eq $expected }
        }
        $script:choices.Count | Should -Be 0
    }

    It 'returns to the menu after a launch error' {
        $script:choices = [System.Collections.Generic.Queue[string]]::new()
        foreach ($choice in @('1', '', 'Q')) { $script:choices.Enqueue($choice) }
        Mock Read-LauncherChoice { $script:choices.Dequeue() }
        Mock Start-LauncherWindow { throw 'Unavailable' }
        { Show-LauncherMenu -Configuration $config -ConfigPath 'x' -LauncherPath $launcher } | Should -Not -Throw
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Unavailable*' } -Times 1
    }
}

Describe 'Real child-process smoke tests (stub tools only)' {
    BeforeAll {
        $integrationRoot = Join-Path $TestDrive "Portable install [test] O'Brien"
        $integrationConfig = New-TestToolFile (Join-Path $integrationRoot 'launcher.local.psd1') @'
@{
    ALZScript = 'ALZ\Start-ALZDelivery.ps1'
    FinOpsToolkitRoot = 'finops-toolkit'
    ResourceTaggerScript = 'Tagger\Start-ResourceTagger.ps1'
    FTKLocalScript = 'FTKLocal\Start-DemoEnvironment.ps1'
}
'@
        $stub = @'
param([string]$RepoRoot)
@{
    File = $PSCommandPath
    RepoRoot = $RepoRoot
    WorkingDirectory = (Get-Location).Path
    Apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState().ToString()
} | ConvertTo-Json -Compress
'@
        foreach ($path in @('ALZ\Start-ALZDelivery.ps1', 'Tagger\Start-ResourceTagger.ps1', 'FTKLocal\Start-DemoEnvironment.ps1')) {
            $null = New-TestToolFile (Join-Path $integrationRoot $path) $stub
        }
        $null = New-TestToolFile (Join-Path $integrationRoot 'finops-toolkit\src\powershell\Public\Start-FinOpsMultitool.ps1') @'
function Start-FinOpsMultitool {
    @{
        Function = 'Start-FinOpsMultitool'
        HubOverride = $env:FINOPS_HUB_KUSTO_URI
        WorkingDirectory = (Get-Location).Path
        Apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState().ToString()
    } | ConvertTo-Json -Compress
}
'@
        foreach ($path in @(
            'finops-toolkit\src\powershell\Private\FinOpsMultitool\Invoke-FinOpsMultitool.ps1',
            'finops-toolkit\src\powershell\Private\FinOpsMultitool\FinOpsMultitool.psm1',
            'FTKLocal\Start-LocalHubTUI.ps1', 'FTKLocal\Setup-LocalFinOpsHub.ps1'
        )) { $null = New-TestToolFile (Join-Path $integrationRoot $path) }
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
    }

    It 'executes the <Name> route correctly across a real pwsh boundary' -ForEach @(
        @{ Name = 'ALZ'; RelativePath = 'ALZ\Start-ALZDelivery.ps1' }
        @{ Name = 'ResourceTagger'; RelativePath = 'Tagger\Start-ResourceTagger.ps1' }
        @{ Name = 'FTKLocal'; RelativePath = 'FTKLocal\Start-DemoEnvironment.ps1' }
        @{ Name = 'FinOps'; RelativePath = 'finops-toolkit\src\powershell\Public\Start-FinOpsMultitool.ps1' }
    ) {
        $output = & $pwsh -NoLogo -NoProfile -STA -File $launcher -ConfigPath $integrationConfig -Tool $Name
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json
        $result.Apartment | Should -Be 'STA'
        $result.WorkingDirectory | Should -Be (Split-Path (Join-Path $integrationRoot $RelativePath))
        if ($Name -eq 'FinOps') {
            $result.Function | Should -Be 'Start-FinOpsMultitool'
            $result.HubOverride | Should -BeNullOrEmpty
        }
        else {
            $result.File | Should -Be (Join-Path $integrationRoot $RelativePath)
        }
        if ($Name -eq 'FTKLocal') {
            $result.RepoRoot | Should -Be (Join-Path $integrationRoot 'finops-toolkit')
        }
    }

    It 'validates paths without running any stub' {
        $output = & $pwsh -NoProfile -File $launcher -ConfigPath $integrationConfig -Check
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'Ready'
        ($output -join "`n") | Should -Not -Match 'WorkingDirectory'
    }

    It 'executes the standalone preview TUI across a real pwsh boundary' {
        $standaloneConfig = New-TestToolFile (Join-Path $integrationRoot 'standalone.local.psd1') @'
@{ FinOpsToolkitRoot = 'standalone preview'; FTKLocalScript = '' }
'@
        $moduleRoot = Join-Path $integrationRoot 'standalone preview'
        $null = New-TestToolFile (Join-Path $moduleRoot 'Public\Start-FinOpsMultitool.ps1') @'
function Start-FinOpsMultitool {
    @{ Function = 'Standalone TUI'; WorkingDirectory = (Get-Location).Path } | ConvertTo-Json -Compress
}
'@
        foreach ($path in @('Private\FinOpsMultitool\Invoke-FinOpsMultitool.ps1', 'Private\FinOpsMultitool\FinOpsMultitool.psm1')) {
            $null = New-TestToolFile (Join-Path $moduleRoot $path)
        }
        $output = & $pwsh -NoLogo -NoProfile -STA -File $launcher -ConfigPath $standaloneConfig -Tool FinOps
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json
        $result.Function | Should -Be 'Standalone TUI'
        $result.WorkingDirectory | Should -Be (Join-Path $moduleRoot 'Public')
    }

    It 'exits nonzero when a configuration is missing' {
        $output = & $pwsh -NoProfile -File $launcher -ConfigPath (Join-Path $TestDrive 'not-there.psd1') -Check 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Match 'Configuration not found'
    }

    It 'handles redirected menu input, lowercase choices, invalid selections and Back' {
        $output = "invalid`n2`nb`nq" | & $pwsh -NoProfile -File $launcher -ConfigPath $integrationConfig
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'Not a valid choice'
        ($output -join "`n") | Should -Match 'FinOps Multitool TUI'
    }

    It 'fails instead of looping forever at redirected end-of-input' {
        $output = '' | & $pwsh -NoProfile -File $launcher -ConfigPath $integrationConfig 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Match 'input closed'
    }
}

Describe 'Portable desktop shortcut' {
    BeforeAll {
        $shortcutScript = Join-Path $PSScriptRoot '..\New-LauncherShortcut.ps1'
        $shortcutConfig = New-TestToolFile (Join-Path $TestDrive 'shortcut config.psd1') '@{}'
    }

    It 'creates a shortcut with quoted paths and a tool-independent icon' {
        $path = Join-Path $TestDrive 'Azure Tool Launcher.lnk'
        $null = & $shortcutScript -ShortcutPath $path -ConfigPath $shortcutConfig
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $null
        try {
            $shortcut = $shell.CreateShortcut($path)
            $shortcut.TargetPath | Should -Be (Join-Path $PSHOME 'pwsh.exe')
            $shortcut.Arguments | Should -BeLike '*-NoProfile*'
            $shortcut.Arguments | Should -BeLike "*-ConfigPath `"$shortcutConfig`"*"
            $shortcut.IconLocation | Should -Be "$(Join-Path $PSHOME 'pwsh.exe'),0"
        }
        finally {
            if ($null -ne $shortcut) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }
            $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
        { & $shortcutScript -ShortcutPath $path -ConfigPath $shortcutConfig } | Should -Throw '*already exists*'
        { & $shortcutScript -ShortcutPath $path -ConfigPath $shortcutConfig -Force } | Should -Not -Throw
    }

    It 'honors WhatIf without writing a shortcut' {
        $path = Join-Path $TestDrive 'Not created.lnk'
        & $shortcutScript -ShortcutPath $path -ConfigPath $shortcutConfig -WhatIf
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}
