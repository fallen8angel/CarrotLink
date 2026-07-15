# Managed CarrotLink updates

CarrotLink app updates are published from this private repository and proxied by HL Cloud.

## Runtime flow

1. CarrotLink requests the HL Cloud GitHub-compatible release endpoint.
2. HL Cloud reads the latest release from `leehyuk1108/CarrotLink_notser` with a server-side token.
3. The app compares the release tag with its installed `versionName+versionCode` identity.
4. HL Cloud streams the private APK asset without exposing the GitHub token.
5. Android verifies the APK signature and performs the package update.

Stable and development endpoints:

```text
https://hl-cloud.leehyuk1108-comma.workers.dev/api/releases/latest
https://hl-cloud.leehyuk1108-comma.workers.dev/api/releases?per_page=1
```

## Release contract

- APK package: `com.example.carrot_pilot_manager`
- Signing certificate SHA-256: `55a14240fb656db17c66c695a61ae5679982a5ae24e233563a43211c5125fa94`
- Release tag: `v<versionName>+<versionCode>`
- Release asset: one filename ending in `.apk`
- Release body: include `SHA-256: <64 lowercase hex characters>`
- Draft releases are never offered to stable clients.

The exact tag format is required because legacy app comparison falls back to string equality when `versionName` contains the `-fix5` suffix.

## Publish

```sh
tools/publish_managed_update.sh /absolute/path/CarrotLink-fix5-v13.apk notes.txt
```

The script validates package identity, version, signing certificate, HL Cloud endpoints, and SHA-256. It creates a draft, uploads the APK, verifies the asset, then publishes atomically.

HL Cloud checks GitHub on app startup and website status requests. A published release normally appears within 30 seconds. The bridge version must be installed manually once on devices that still use the original GitHub endpoint.

## Cloudflare secrets

- `HL_CLOUD_PASSWORD`
- `SESSION_SECRET`
- `GITHUB_RELEASE_TOKEN`

`GITHUB_RELEASE_TOKEN` should be a fine-grained read-only token limited to this repository. Never commit it.
