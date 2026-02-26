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
    [string]$Serial
)

$ErrorActionPreference = 'Stop'
$pauseOnExit = -not $NoPause

try {
    chcp 65001 | Out-Null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

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

try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $projectRoot = (Resolve-Path (Join-Path $scriptDir '..')).Path

    $apkName = "app-$BuildMode.apk"
    $apkPath = Join-Path $projectRoot "build\app\outputs\flutter-apk\$apkName"

    $resolvedFlutter = Resolve-CommandPath -Preferred $FlutterPath -FallbackCandidates @(
        'C:\flutter\bin\flutter.bat',
        'C:\src\flutter\bin\flutter.bat'
    )
    $resolvedAdb = Resolve-CommandPath -Preferred $AdbPath -FallbackCandidates @(
        "$env:ANDROID_HOME\platform-tools\adb.exe",
        "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    )

    Write-Host ""
    Write-Host "==== CarrotLink APK 빌드 스크립트 ===="
    Write-Host "프로젝트 경로: $projectRoot"
    Write-Host "빌드 모드: $BuildMode"
    Write-Host "빌드 생략: $SkipBuild"
    Write-Host "설치 옵션: $Install"
    Write-Host ""

    if (-not $SkipBuild) {
        if (-not $resolvedFlutter) {
            throw "flutter 실행 파일을 찾지 못했습니다. FlutterPath를 지정하거나 PATH를 설정하세요."
        }

        Write-Host "[1/3] Flutter APK 빌드를 시작합니다..."
        Push-Location $projectRoot
        try {
            & $resolvedFlutter build apk "--$BuildMode"
        }
        finally {
            Pop-Location
        }
        Write-Host "[1/3] 빌드 완료"
    } else {
        Write-Host "[1/3] 빌드를 생략하고 기존 APK를 사용합니다."
    }

    if (-not (Test-Path $apkPath)) {
        throw "APK 파일을 찾을 수 없습니다: $apkPath"
    }

    $apkFullPath = (Resolve-Path $apkPath).Path
    Write-Host ""
    Write-Host "[2/3] APK 절대 경로"
    Write-Host " -> $apkFullPath"
    Write-Host ""

    if ($OpenOutput) {
        Write-Host "[추가] 탐색기에서 APK 위치를 엽니다."
        Start-Process explorer.exe "/select,`"$apkFullPath`""
    }

    if ($Install) {
        if (-not $resolvedAdb) {
            throw "adb 실행 파일을 찾지 못했습니다. AdbPath를 지정하거나 Android SDK PATH를 설정하세요."
        }

        Write-Host "[3/3] adb 설치(-r, 삭제 없이 업데이트)를 진행합니다..."
        $deviceLines = & $resolvedAdb devices
        $onlineDevices = @()

        foreach ($line in $deviceLines) {
            if ($line -match '^(\S+)\s+device$') {
                $onlineDevices += $Matches[1]
            }
        }

        if ($onlineDevices.Count -eq 0) {
            throw '온라인 adb 기기를 찾지 못했습니다.'
        }

        if (-not $Serial -and $onlineDevices.Count -gt 1 -and -not $PromptDevice) {
            throw "여러 기기가 연결되어 있습니다. -Serial 또는 -PromptDevice 옵션으로 지정하세요. 기기: $($onlineDevices -join ', ')"
        }

        if (-not $Serial -and $onlineDevices.Count -gt 1 -and $PromptDevice) {
            Write-Host ""
            Write-Host "여러 기기가 연결되어 있습니다. 설치할 기기를 선택하세요."
            for ($i = 0; $i -lt $onlineDevices.Count; $i++) {
                Write-Host "[$($i + 1)] $($onlineDevices[$i])"
            }

            $selectionText = Read-Host "번호 입력"
            $selection = 0
            if (-not [int]::TryParse($selectionText, [ref]$selection)) {
                throw "숫자를 입력해야 합니다: $selectionText"
            }
            if ($selection -lt 1 -or $selection -gt $onlineDevices.Count) {
                throw "선택한 번호가 범위를 벗어났습니다: $selection"
            }
            $Serial = $onlineDevices[$selection - 1]
        }

        if ($Serial -and -not ($onlineDevices -contains $Serial)) {
            throw "지정한 시리얼 '$Serial' 기기가 온라인 상태가 아닙니다. 온라인 기기: $($onlineDevices -join ', ')"
        }

        $targetSerial = if ($Serial) { $Serial } else { $onlineDevices[0] }
        Write-Host "대상 기기: $targetSerial"

        & $resolvedAdb -s $targetSerial install -r $apkFullPath
        Write-Host "[3/3] 설치 완료"
    } else {
        Write-Host "[3/3] 설치는 생략되었습니다. (-Install 옵션 없음)"
    }

    Write-Host ""
    Write-Host "완료: 스크립트 실행이 정상 종료되었습니다."
}
finally {
    if ($pauseOnExit) {
        Write-Host ""
        Read-Host "완료. Enter를 누르면 창이 닫힙니다" | Out-Null
    }
}
