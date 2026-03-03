param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$RunChoice
)

$ErrorActionPreference = 'Continue'

try {
    chcp 65001 | Out-Null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}
catch {}

$buildScript = Join-Path $PSScriptRoot 'build_dev_apk.ps1'
if (-not (Test-Path $buildScript)) {
    Write-Host "Cannot find build script: $buildScript"
    Read-Host 'Press Enter to exit' | Out-Null
    exit 1
}

function Run-Task {
    param(
        [string]$Label,
        [scriptblock]$Command
    )

    Write-Host ''
    Write-Host "Run: $Label"

    $script:LASTEXITCODE = 0
    & $Command

    $exitCode = if ($LASTEXITCODE -ne $null) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    Write-Host ''
    if ($exitCode -eq 0) {
        Write-Host 'Task completed'
    }
    else {
        Write-Host "Task failed (exit=$exitCode)"
    }

    if (-not $RunChoice) {
        Read-Host 'Press Enter to continue' | Out-Null
    }

    return $exitCode
}

function Read-Default {
    param(
        [string]$Prompt,
        [string]$DefaultValue
    )

    if ($DefaultValue) {
        $raw = Read-Host "$Prompt (default: $DefaultValue)"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultValue
        }
        return $raw.Trim()
    }

    return (Read-Host $Prompt).Trim()
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultValue = $true
    )

    $hint = if ($DefaultValue) { 'Y/n' } else { 'y/N' }
    $raw = Read-Host "$Prompt [$hint]"
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $DefaultValue
    }

    switch ($raw.Trim().ToLowerInvariant()) {
        'y' { return $true }
        'yes' { return $true }
        'n' { return $false }
        'no' { return $false }
        default { return $DefaultValue }
    }
}

function Invoke-CustomFlow {
    Write-Host ''
    Write-Host 'Advanced run options'

    $mode = Read-Default -Prompt 'Build mode (release/debug/profile)' -DefaultValue 'release'
    if ($mode -notin @('release', 'debug', 'profile')) {
        throw "Unsupported build mode: $mode"
    }

    $skipBuild = Read-YesNo -Prompt 'Skip build and use existing APK' -DefaultValue $false
    $install = Read-YesNo -Prompt 'Install after build' -DefaultValue $true
    $clean = Read-YesNo -Prompt 'Run flutter clean first' -DefaultValue $false
    $pubGet = Read-YesNo -Prompt 'Run flutter pub get first' -DefaultValue $false
    $promptDevice = Read-YesNo -Prompt 'Prompt when multiple devices are connected' -DefaultValue $true
    $useFirstDevice = $false
    if (-not $promptDevice) {
        $useFirstDevice = Read-YesNo -Prompt 'Auto-select first device if multiple devices exist' -DefaultValue $true
    }
    $serial = Read-Default -Prompt 'Fixed device serial (blank to skip)' -DefaultValue ''
    $connectAddress = Read-Default -Prompt 'Wireless adb address (e.g. 172.30.1.21:5555, blank to skip)' -DefaultValue ''
    $waitForDevice = Read-Default -Prompt 'Wait for device (seconds)' -DefaultValue '15'
    $installRetry = Read-Default -Prompt 'Install retry count' -DefaultValue '2'
    $launchAfterInstall = Read-YesNo -Prompt 'Launch app after install' -DefaultValue $true
    $uninstallFirst = Read-YesNo -Prompt 'Uninstall app first' -DefaultValue $false
    $openOutput = Read-YesNo -Prompt 'Open APK path in Explorer' -DefaultValue $false
    $target = Read-Default -Prompt 'Build target file' -DefaultValue 'lib/main.dart'
    $flavor = Read-Default -Prompt 'Flavor (blank to skip)' -DefaultValue ''
    $splitPerAbi = Read-YesNo -Prompt 'Enable --split-per-abi' -DefaultValue $false

    $args = @('-BuildMode', $mode, '-NoPause')
    if ($skipBuild) { $args += '-SkipBuild' }
    if ($install) { $args += '-Install' }
    if ($clean) { $args += '-Clean' }
    if ($pubGet) { $args += '-PubGet' }
    if ($promptDevice) { $args += '-PromptDevice' }
    if ($useFirstDevice) { $args += '-UseFirstDevice' }
    if ($launchAfterInstall) { $args += '-LaunchAfterInstall' }
    if ($uninstallFirst) { $args += '-UninstallFirst' }
    if ($openOutput) { $args += '-OpenOutput' }
    if ($splitPerAbi) { $args += '-SplitPerAbi' }
    if ($target) { $args += @('-Target', $target) }
    if ($flavor) { $args += @('-Flavor', $flavor) }
    if ($serial) { $args += @('-Serial', $serial) }
    if ($connectAddress) { $args += @('-ConnectAddress', $connectAddress) }
    if ($waitForDevice) { $args += @('-WaitForDeviceSeconds', $waitForDevice) }
    if ($installRetry) { $args += @('-InstallRetry', $installRetry) }

    Write-Host ''
    Write-Host "Command args: $($args -join ' ')"
    & $buildScript @args
}

function Invoke-Choice {
    param([string]$Choice)

    switch ($Choice) {
        '1' {
            [void](Run-Task -Label 'Release build + install' -Command {
                    & $buildScript -BuildMode release -Install -PromptDevice -WaitForDeviceSeconds 20 -InstallRetry 2 -NoPause
                })
            return $true
        }
        '2' {
            [void](Run-Task -Label 'Debug build + install' -Command {
                    & $buildScript -BuildMode debug -Install -PromptDevice -WaitForDeviceSeconds 20 -InstallRetry 2 -NoPause
                })
            return $true
        }
        '3' {
            [void](Run-Task -Label 'Profile build + install' -Command {
                    & $buildScript -BuildMode profile -Install -PromptDevice -WaitForDeviceSeconds 20 -InstallRetry 2 -NoPause
                })
            return $true
        }
        '4' {
            [void](Run-Task -Label 'Release build only' -Command {
                    & $buildScript -BuildMode release -NoPause
                })
            return $true
        }
        '5' {
            [void](Run-Task -Label 'Install existing Release APK only' -Command {
                    & $buildScript -BuildMode release -SkipBuild -Install -PromptDevice -WaitForDeviceSeconds 20 -InstallRetry 2 -NoPause
                })
            return $true
        }
        '6' {
            [void](Run-Task -Label 'Install existing Debug APK only' -Command {
                    & $buildScript -BuildMode debug -SkipBuild -Install -PromptDevice -WaitForDeviceSeconds 20 -InstallRetry 2 -NoPause
                })
            return $true
        }
        '7' {
            [void](Run-Task -Label 'Clean + PubGet + Release build + install' -Command {
                    & $buildScript -BuildMode release -Clean -PubGet -Install -PromptDevice -WaitForDeviceSeconds 20 -InstallRetry 2 -NoPause
                })
            return $true
        }
        '8' {
            [void](Run-Task -Label 'Wireless adb connect + install existing Release' -Command {
                    $addr = Read-Default -Prompt 'adb connect address (e.g. 172.30.1.21:5555)' -DefaultValue ''
                    if (-not $addr) {
                        throw 'Address cannot be empty.'
                    }
                    & $buildScript -BuildMode release -SkipBuild -Install -PromptDevice -ConnectAddress $addr -WaitForDeviceSeconds 30 -InstallRetry 2 -NoPause
                })
            return $true
        }
        '9' {
            [void](Run-Task -Label 'Show adb device list' -Command {
                    & $buildScript -ListDevicesOnly -NoPause
                })
            return $true
        }
        '10' {
            [void](Run-Task -Label 'Open APK output path in Explorer' -Command {
                    & $buildScript -BuildMode release -SkipBuild -OpenOutput -NoPause
                })
            return $true
        }
        '11' {
            [void](Run-Task -Label 'Advanced run (custom options)' -Command {
                    Invoke-CustomFlow
                })
            return $true
        }
        '0' {
            return $false
        }
        default {
            Write-Host ''
            Write-Host 'Invalid choice. Enter a valid number.'
            Start-Sleep -Seconds 1
            return $true
        }
    }
}

if ($RunChoice) {
    [void](Invoke-Choice -Choice $RunChoice)
    exit $LASTEXITCODE
}

while ($true) {
    Clear-Host
    Write-Host '========================================='
    Write-Host ' CarrotLink APK Menu'
    Write-Host '========================================='
    Write-Host "Project: $ProjectRoot"
    Write-Host ''
    Write-Host '1) Release build + install (recommended)'
    Write-Host '2) Debug build + install'
    Write-Host '3) Profile build + install'
    Write-Host '4) Release build only'
    Write-Host '5) Install existing Release APK only'
    Write-Host '6) Install existing Debug APK only'
    Write-Host '7) Clean + PubGet + Release build + install'
    Write-Host '8) Wireless adb connect + install'
    Write-Host '9) Show connected adb devices'
    Write-Host '10) Open APK output path (Explorer)'
    Write-Host '11) Advanced run (detailed options)'
    Write-Host '0) Exit'
    Write-Host ''

    $choice = Read-Host 'Select number'
    $shouldContinue = Invoke-Choice -Choice $choice
    if (-not $shouldContinue) {
        break
    }
}
