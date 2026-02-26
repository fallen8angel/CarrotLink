# Git/관리 탭 SSH 명령어 매핑 (c3 기준)

대상 앱: `CarrotLink-dev`  
대상 탭: `Git`, `관리`  
기준 코드: `lib/services/device_action_service.dart`

## 공통 동작

Git/관리 탭의 버튼은 모두 기존 SSH 연결(포트 22) 위에서 명령을 실행한다.  
이 탭들에서 SSH 키를 생성하거나 설치하는 명령은 실행하지 않는다.

Git 관련 액션은 실행 전 아래 repo 탐지를 공통으로 수행한다.

```bash
REPO=""
for d in /data/openpilot /home/comma/openpilot; do
  if [ -d "$d/.git" ]; then
    REPO="$d"
    break
  fi
done
if [ -z "$REPO" ]; then
  echo OPENPILOT_REPO_NOT_FOUND
  exit 2
fi
```

## Git 탭 버튼

### 1) 브랜치 선택
- 표시용(간단): `git fetch --all --prune`, `git branch`, `git checkout <branch>`
- 실제 실행: 브랜치 목록 조회 + 선택 브랜치 checkout

목록 조회:

```bash
git -C "$REPO" fetch --all --prune >/dev/null 2>&1 || true
CURRENT_BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
DEFAULT_BRANCH="$(git -C "$REPO" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -n1)"
REPO_URL="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || true)"
git -C "$REPO" for-each-ref --sort=-committerdate --format="%(refname:short)|%(committerdate:relative)|%(objectname)" refs/remotes/origin || true
git -C "$REPO" for-each-ref --format="%(refname:short)|%(objectname)" refs/heads || true
```

선택 브랜치 적용:

```bash
BRANCH="<선택한브랜치>"
git -C "$REPO" fetch --all --prune
if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$REPO" checkout "$BRANCH"
else
  git -C "$REPO" checkout -B "$BRANCH" "origin/$BRANCH"
fi
```

### 2) Git Pull
- 표시용(간단): `git pull`
- 실제 실행:

```bash
git -C "$REPO" pull
```

### 3) Git Reset
- 표시용(간단): `git reset --hard HEAD`
- 실제 실행:

```bash
git -C "$REPO" reset --hard HEAD
```

### 4) Git Sync
- 표시용(간단): `git fetch --all --prune && git reset --hard origin/<현재브랜치>`
- 실제 실행:

```bash
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
git -C "$REPO" fetch --all --prune
if git -C "$REPO" rev-parse --verify --quiet "origin/$BRANCH" >/dev/null 2>&1; then
  git -C "$REPO" reset --hard "origin/$BRANCH"
else
  echo "origin/$BRANCH not found, fetch-only done"
fi
```

### 5) Reboot
- 표시용(간단): `sudo reboot`
- 실제 실행:

```bash
sudo reboot
```

## 관리 탭 버튼

### 1) 소프트 재시작 (Soft Restart)
- 표시용(간단): `tmux comma 세션 재시작`
- 실제 실행:

```bash
tmux kill-session -t comma 2>/dev/null || true
rm -f /tmp/safe_staging_overlay.lock 2>/dev/null || true
sleep 1
tmux new-session -d -s comma "bash -lc \"$REPO/launch_openpilot.sh\""
```

### 2) 기기 재부팅 (Reboot)
- 표시용(간단): `sudo reboot`
- 실제 실행:

```bash
sudo reboot
```

### 3) 오픈파일럿 재빌드 (Rebuild)
- 표시용(간단): `scons -c`, 캐시 삭제, 재부팅
- 실제 실행:

```bash
cd "$REPO"
scons -c
rm -f .sconsign.dblite
rm -rf /tmp/scons_cache
rm -rf prebuilt
sudo reboot
```

### 4) 학습 데이터 초기화 (Live Params)
- 표시용(간단): `rm -f /data/params/d/LiveParameters`
- 실제 실행:

```bash
rm -f /data/params/d/LiveParameters
```

### 5) 캘리브레이션 초기화 (Calibration)
- 표시용(간단): `rm -f /data/params/d/CalibrationParams`
- 실제 실행:

```bash
rm -f /data/params/d/CalibrationParams
```

### 6) 녹화 영상 삭제 (Delete Videos)
- 표시용(간단): `videos 폴더 내 항목 삭제`
- 실제 실행:

```bash
TARGET="/data/media/0/videos"
if [ ! -d "$TARGET" ]; then
  echo "videos path not found (skip)"
  exit 0
fi
COUNT=$(find "$TARGET" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
find "$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
echo "deleted entries: $COUNT"
```

### 7) 주행 로그 삭제 (Delete Logs)
- 표시용(간단): `realdata 폴더 내 항목 삭제`
- 실제 실행:

```bash
TARGET="/data/media/0/realdata"
if [ ! -d "$TARGET" ]; then
  echo "realdata path not found (skip)"
  exit 0
fi
COUNT=$(find "$TARGET" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
find "$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
echo "deleted entries: $COUNT"
```

## 참고

- Git 탭 로그는 사용자 가독성을 위해 내부 스크립트 전문(`REPO=...`, `for d in ...`)과 `exit=...` 같은 내부 상태 로그를 노출하지 않도록 조정되어 있다.
- 성공/실패 판단은 SSH 명령의 exit code 기반으로 처리된다.
