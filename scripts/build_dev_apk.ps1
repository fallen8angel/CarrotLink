param(
    [ValidateSet('release', 'debug', 'profile')]
    [string]$BuildMode = 'release',
    [switch]$Install,
    [switch]$OpenOutput,
    [switch]$SkipBuild,
    [switch]$NoPause,
    [switch]$PromptDevice,
    [string]$FlutterPath = 'flutter',
    [string]$AdbPath = 'adb',
    [string]$Serial,
    [switch]$UseFirstDevice,
    [switch]$Clean,
    [switch]$PubGet,
    [string]$Target = 'lib/main.dart',
    [string]$Flavor,
    [string[]]$DartDefine,
    [string[]]$ExtraBuildArg,
    [switch]$SplitPerAbi,
    [switch]$UninstallFirst,
    [string]$PackageName = 'com.example.carrot_pilot_manager',
    [string]$LaunchActivity = '.MainActivity',
    [switch]$LaunchAfterInstall,
    [switch]$GrantPermissions,
    [string]$ConnectAddress,
    [int]$WaitForDeviceSeconds = 0,
    [int]$InstallRetry = 1,
    [switch]$AllowVersionDowngrade,
    [string]$ApkPath,
    [switch]$ListDevicesOnly
)

$ErrorActionPreference = 'Stop'
$pauseOnExit = -not $NoPause
$startedAt = Get-Date

try {
    chcp 65001 | Out-Null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}
catch {}

function Resolve-CommandPath {
    param(
        [string]$Preferred,
        [string[]]$FallbackCandidates
    )

    if ($Preferred) {
        $preferredCmd = Get-Command $Preferred -ErrorAction SilentlyContinue
        if ($preferredCmd) {
            return $Preferred
        }

        if (Test-Path $Preferred) {
            return $Preferred
        }
    }

    foreach ($candidate in $FallbackCandidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Invoke-External {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$StepLabel
    )

    Write-Host $StepLabel
    if ($Arguments -and $Arguments.Count -gt 0) {
        Write-Host " -> $Executable $($Arguments -join ' ')"
    }
    else {
        Write-Host " -> $Executable"
    }

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$StepLabel failed (exit=$LASTEXITCODE)"
    }
}

function Get-OnlineAdbDevices {
    param([string]$AdbExecutable)

    $lines = & $AdbExecutable devices -l
    $devices = @()

    foreach ($line in $lines) {
        if ($line -match '^\s*(\S+)\s+device\b') {
            $serial = $Matches[1]
            $model = ''
            if ($line -match 'model:(\S+)') {
                $model = $Matches[1]
            }

            $devices += [PSCustomObject]@{
                Serial = $serial
                Model  = $model
                Raw    = $line
            }
        }
    }

    return $devices
}

function Show-AdbDevices {
    param(
        [string]$AdbExecutable,
        [object[]]$OnlineDevices
    )

    Write-Host ''
    Write-Host '[ADB] devices -l'
    $all = & $AdbExecutable devices -l
    foreach ($line in $all) {
        Write-Host "  $line"
    }

    Write-Host ''
    if ($OnlineDevices.Count -eq 0) {
        Write-Host '[ADB] Online devices: none'
    }
    else {
        Write-Host "[ADB] Online devices: $($OnlineDevices.Count)"
        for ($i = 0; $i -lt $OnlineDevices.Count; $i++) {
            $d = $OnlineDevices[$i]
            $modelText = if ($d.Model) { " ($($d.Model))" } else { '' }
            Write-Host "  [$($i + 1)] $($d.Serial)$modelText"
        }
    }
}

function Resolve-BuiltApkPath {
    param(
        [string]$ProjectRoot,
        [string]$Mode,
        [string]$OptionalFlavor,
        [string]$ManualApkPath
    )

    if ($ManualApkPath) {
        if (-not (Test-Path $ManualApkPath)) {
            throw "Cannot find manual APK path: $ManualApkPath"
        }
        return (Resolve-Path $ManualApkPath).Path
    }

    $apkOutputDir = Join-Path $ProjectRoot 'build\app\outputs\flutter-apk'
    $candidates = @()

    if ($OptionalFlavor) {
        $candidates += "app-$($OptionalFlavor.ToLower())-$Mode.apk"
        $candidates += "app-$OptionalFlavor-$Mode.apk"
    }
    $candidates += "app-$Mode.apk"

    foreach ($name in $candidates) {
        $candidatePath = Join-Path $apkOutputDir $name
        if (Test-Path $candidatePath) {
            return (Resolve-Path $candidatePath).Path
        }
    }

    $fallback = Get-ChildItem -Path $apkOutputDir -Filter '*.apk' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "-$Mode\.apk$" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($fallback) {
        return $fallback.FullName
    }

    throw "Cannot find APK. Output dir: $apkOutputDir"
}

function Resolve-ActivityComponent {
    param(
        [string]$Pkg,
        [string]$Activity
    )

    if (-not $Activity) {
        return "$Pkg/.MainActivity"
    }

    if ($Activity.Contains('/')) {
        return $Activity
    }

    if ($Activity.StartsWith('.')) {
        return "$Pkg/$Activity"
    }

    return "$Pkg/$Activity"
}

try {
    if ($InstallRetry -lt 1) {
        throw "InstallRetry must be >= 1. Input: $InstallRetry"
    }
    if ($WaitForDeviceSeconds -lt 0) {
        throw "WaitForDeviceSeconds must be >= 0. Input: $WaitForDeviceSeconds"
    }

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $projectRoot = (Resolve-Path (Join-Path $scriptDir '..')).Path

    $resolvedFlutter = Resolve-CommandPath -Preferred $FlutterPath -FallbackCandidates @(
        'C:\flutter\bin\flutter.bat',
        'C:\src\flutter\bin\flutter.bat'
    )
    $resolvedAdb = Resolve-CommandPath -Preferred $AdbPath -FallbackCandidates @(
        "$env:ANDROID_HOME\platform-tools\adb.exe",
        "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    )

    Write-Host ''
    Write-Host '==== CarrotLink APK build/install ===='
    Write-Host "Project: $projectRoot"
    Write-Host "Mode: $BuildMode"
    Write-Host "SkipBuild: $SkipBuild / Install: $Install"
    Write-Host "Clean: $Clean / PubGet: $PubGet / SplitPerAbi: $SplitPerAbi"
    Write-Host "Target: $Target / Flavor: $Flavor"
    Write-Host "PromptDevice: $PromptDevice / UseFirstDevice: $UseFirstDevice / Serial: $Serial"
    Write-Host "ConnectAddress: $ConnectAddress / WaitForDeviceSeconds: $WaitForDeviceSeconds"
    Write-Host ''

    if ($ListDevicesOnly) {
        if (-not $resolvedAdb) {
            throw 'adb not found. Set AdbPath or Android SDK PATH.'
        }
        & $resolvedAdb start-server | Out-Null
        $devicesOnly = Get-OnlineAdbDevices -AdbExecutable $resolvedAdb
        Show-AdbDevices -AdbExecutable $resolvedAdb -OnlineDevices $devicesOnly
        return
    }

    if ((-not $SkipBuild) -or $Clean -or $PubGet) {
        if (-not $resolvedFlutter) {
            throw 'flutter not found. Set FlutterPath or PATH.'
        }

        Push-Location $projectRoot
        try {
            if ($Clean) {
                Invoke-External -Executable $resolvedFlutter -Arguments @('clean') -StepLabel '[Prep] flutter clean'
            }

            if ($PubGet) {
                Invoke-External -Executable $resolvedFlutter -Arguments @('pub', 'get') -StepLabel '[Prep] flutter pub get'
            }

            if (-not $SkipBuild) {
                $buildArgs = @('build', 'apk', "--$BuildMode")
                if ($Target) {
                    $buildArgs += @('-t', $Target)
                }
                if ($Flavor) {
                    $buildArgs += @('--flavor', $Flavor)
                }
                if ($SplitPerAbi) {
                    $buildArgs += '--split-per-abi'
                }
                if ($DartDefine) {
                    foreach ($define in $DartDefine) {
                        if ($define) {
                            $buildArgs += "--dart-define=$define"
                        }
                    }
                }
                if ($ExtraBuildArg) {
                    foreach ($extra in $ExtraBuildArg) {
                        if ($extra) {
                            $buildArgs += $extra
                        }
                    }
                }

                Invoke-External -Executable $resolvedFlutter -Arguments $buildArgs -StepLabel '[Build] flutter build apk'
            }
            else {
                Write-Host '[Build] SkipBuild=true, using existing APK'
            }
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Host '[Build] build stage skipped'
    }

    $apkFullPath = Resolve-BuiltApkPath -ProjectRoot $projectRoot -Mode $BuildMode -OptionalFlavor $Flavor -ManualApkPath $ApkPath
    Write-Host ''
    Write-Host '[APK] target file'
    Write-Host " -> $apkFullPath"
    Write-Host ''

    if ($OpenOutput) {
        Write-Host '[Extra] Open APK path in Explorer'
        Start-Process explorer.exe "/select,`"$apkFullPath`""
    }

    if ($Install) {
        if (-not $resolvedAdb) {
            throw 'adb not found. Set AdbPath or Android SDK PATH.'
        }

        & $resolvedAdb start-server | Out-Null

        if ($ConnectAddress) {
            Write-Host "[ADB] adb connect $ConnectAddress"
            $connectOutput = & $resolvedAdb connect $ConnectAddress 2>&1
            if ($connectOutput) {
                $connectOutput | ForEach-Object { Write-Host $_ }
            }
        }

        if ($WaitForDeviceSeconds -gt 0) {
            $waitElapsed = 0
            while ($waitElapsed -lt $WaitForDeviceSeconds) {
                $online = Get-OnlineAdbDevices -AdbExecutable $resolvedAdb
                if ($online.Count -gt 0) {
                    break
                }
                Start-Sleep -Seconds 1
                $waitElapsed++
            }
        }

        $onlineDevices = Get-OnlineAdbDevices -AdbExecutable $resolvedAdb
        Show-AdbDevices -AdbExecutable $resolvedAdb -OnlineDevices $onlineDevices

        if ($onlineDevices.Count -eq 0) {
            throw 'No online adb devices found.'
        }

        $onlineSerials = $onlineDevices | ForEach-Object { $_.Serial }

        if (-not $Serial -and $onlineSerials.Count -gt 1 -and -not $PromptDevice -and -not $UseFirstDevice) {
            throw "Multiple devices found. Use -Serial, -PromptDevice, or -UseFirstDevice. Devices: $($onlineSerials -join ', ')"
        }

        if (-not $Serial -and $onlineSerials.Count -gt 1 -and $PromptDevice) {
            Write-Host ''
            Write-Host 'Select install target device:'
            for ($i = 0; $i -lt $onlineSerials.Count; $i++) {
                Write-Host "[$($i + 1)] $($onlineSerials[$i])"
            }

            $selectionText = Read-Host 'Enter number'
            $selection = 0
            if (-not [int]::TryParse($selectionText, [ref]$selection)) {
                throw "Input must be numeric: $selectionText"
            }
            if ($selection -lt 1 -or $selection -gt $onlineSerials.Count) {
                throw "Input out of range: $selection"
            }
            $Serial = $onlineSerials[$selection - 1]
        }

        if (-not $Serial -and $onlineSerials.Count -gt 1 -and $UseFirstDevice) {
            $Serial = $onlineSerials[0]
            Write-Host "[ADB] Multiple devices found, auto-select first: $Serial"
        }

        if (-not $Serial) {
            $Serial = $onlineSerials[0]
        }

        if (-not ($onlineSerials -contains $Serial)) {
            throw "Selected serial is not online: $Serial"
        }

        if ($UninstallFirst) {
            Write-Host "[Install] uninstall first: $PackageName"
            $uninstallOutput = & $resolvedAdb -s $Serial uninstall $PackageName 2>&1
            if ($uninstallOutput) {
                $uninstallOutput | ForEach-Object { Write-Host $_ }
            }
        }

        $installArgs = @('-s', $Serial, 'install', '-r')
        if ($BuildMode -eq 'debug' -or $BuildMode -eq 'profile') {
            $installArgs += '-t'
        }
        if ($BuildMode -ne 'release' -or $AllowVersionDowngrade) {
            $installArgs += '-d'
        }
        $installArgs += $apkFullPath

        $installed = $false
        for ($attempt = 1; $attempt -le $InstallRetry; $attempt++) {
            Write-Host "[Install] attempt $attempt/$InstallRetry"
            $installOutput = & $resolvedAdb @installArgs 2>&1
            if ($installOutput) {
                $installOutput | ForEach-Object { Write-Host $_ }
            }

            if ($LASTEXITCODE -eq 0 -and ($installOutput -join "`n" -match 'Success')) {
                $installed = $true
                break
            }

            if ($attempt -lt $InstallRetry) {
                Start-Sleep -Seconds 2
            }
        }

        if (-not $installed) {
            throw "adb install failed after $InstallRetry attempt(s)"
        }

        Write-Host "[Install] done: $Serial"

        if ($GrantPermissions) {
            $grantList = @(
                'android.permission.POST_NOTIFICATIONS',
                'android.permission.READ_MEDIA_VIDEO',
                'android.permission.READ_MEDIA_IMAGES',
                'android.permission.READ_EXTERNAL_STORAGE',
                'android.permission.WRITE_EXTERNAL_STORAGE'
            )

            foreach ($permission in $grantList) {
                $grantOutput = & $resolvedAdb -s $Serial shell pm grant $PackageName $permission 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[Grant] ok: $permission"
                }
                else {
                    $reason = if ($grantOutput) { ($grantOutput -join ' ') } else { 'unsupported or already granted' }
                    Write-Host "[Grant] skipped: $permission ($reason)"
                }
            }
        }

        if ($LaunchAfterInstall) {
            $component = Resolve-ActivityComponent -Pkg $PackageName -Activity $LaunchActivity
            Write-Host "[Launch] am start -n $component"
            $launchOutput = & $resolvedAdb -s $Serial shell am start -n $component 2>&1
            if ($launchOutput) {
                $launchOutput | ForEach-Object { Write-Host $_ }
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Launch failed: $component"
            }
        }
    }
    else {
        Write-Host '[Install] skipped (-Install not set)'
    }

    $elapsedSec = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
    Write-Host ''
    Write-Host "Done in ${elapsedSec}s"
}
catch {
    Write-Host ''
    Write-Host '[ERROR] script failed'
    Write-Host $_.Exception.Message
    exit 1
}
finally {
    if ($pauseOnExit) {
        Write-Host ''
        Read-Host 'Done. Press Enter to close' | Out-Null
    }
}
