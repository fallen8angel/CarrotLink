param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [ValidateSet('0','1','2','3','4','5','6')]
    [string]$RunChoice
)

$ErrorActionPreference = 'Continue'

try {
    chcp 65001 | Out-Null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$buildScript = Join-Path $PSScriptRoot 'build_dev_apk.ps1'
if (-not (Test-Path $buildScript)) {
    Write-Host "빌드 스크립트를 찾지 못했습니다: $buildScript"
    Read-Host "Enter를 누르면 종료합니다" | Out-Null
    exit 1
}

function Run-Task {
    param(
        [string]$Label,
        [scriptblock]$Command
    )

    Write-Host ""
    Write-Host "실행: $Label"

    $script:LASTEXITCODE = 0
    & $Command

    $exitCode = if ($LASTEXITCODE -ne $null) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    Write-Host ""
    if ($exitCode -ne 0) {
        Write-Host "작업 실패 (exit code: $exitCode)"
    } else {
        Write-Host "작업 완료"
    }

    if (-not $RunChoice) {
        Read-Host "계속하려면 Enter" | Out-Null
    }

    return $exitCode
}

function Invoke-Choice {
    param([string]$Choice)

    switch ($Choice) {
        '1' {
            [void](Run-Task -Label 'Release 빌드 + 설치' -Command {
                & $buildScript -BuildMode release -Install -PromptDevice -NoPause
            })
            return $true
        }
        '2' {
            [void](Run-Task -Label 'Debug 빌드 + 설치' -Command {
                & $buildScript -BuildMode debug -Install -PromptDevice -NoPause
            })
            return $true
        }
        '3' {
            [void](Run-Task -Label 'Release 빌드만' -Command {
                & $buildScript -BuildMode release -NoPause
            })
            return $true
        }
        '4' {
            [void](Run-Task -Label '기존 Release APK 설치만' -Command {
                & $buildScript -BuildMode release -SkipBuild -Install -PromptDevice -NoPause
            })
            return $true
        }
        '5' {
            [void](Run-Task -Label 'Release APK 경로 열기' -Command {
                & $buildScript -BuildMode release -SkipBuild -OpenOutput -NoPause
            })
            return $true
        }
        '6' {
            Write-Host ""
            adb devices
            Write-Host ""
            if (-not $RunChoice) {
                Read-Host "계속하려면 Enter" | Out-Null
            }
            return $true
        }
        '0' { return $false }
        default {
            Write-Host ""
            Write-Host "올바른 번호를 입력하세요."
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
    Write-Host "========================================="
    Write-Host " CarrotLink APK 메뉴"
    Write-Host "========================================="
    Write-Host "프로젝트: $ProjectRoot"
    Write-Host ""
    Write-Host "1) Release 빌드 + 설치 (권장)"
    Write-Host "2) Debug 빌드 + 설치"
    Write-Host "3) Release 빌드만"
    Write-Host "4) 기존 Release APK 설치만"
    Write-Host "5) APK 경로 열기(탐색기)"
    Write-Host "6) 연결된 adb 기기 목록"
    Write-Host "0) 종료"
    Write-Host ""

    $choice = Read-Host "번호 선택"
    $shouldContinue = Invoke-Choice -Choice $choice
    if (-not $shouldContinue) {
        break
    }
}
