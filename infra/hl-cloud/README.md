# HL Cloud

Cloudflare Worker + Workers KV 기반 비공개 배포 페이지입니다.

- 공개 주소: <https://hl-cloud.leehyuk1108-comma.workers.dev>
- 화면: Cloudflare Worker Static Assets
- 인증: Cloudflare Worker Secret + 서명 쿠키
- APK: Workers KV의 20 MiB 조각 10개를 다운로드 시 순차 결합
- 인앱 업데이트: private GitHub Release를 Worker가 메타데이터·APK 스트림으로 중계
- 웹 최신 파일: Release 게시 즉시 `/api/status`와 비밀번호 다운로드에 자동 반영
- 로컬 서버 및 `cloudflared` 터널: 사용하지 않음

## 배포

```sh
npx --yes wrangler@latest deploy
```

필수 Secret:

- `HL_CLOUD_PASSWORD`
- `SESSION_SECRET`
- `GITHUB_RELEASE_TOKEN`

현재 APK:

- `CarrotLink-fix5-v12.apk`
- `199512320` bytes
- SHA-256 `4b22f0755384467907761bad66b12559b9221f658d55ee6099b26a8872e65f23`
