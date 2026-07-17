#!/usr/bin/env bash
set -euo pipefail

readonly REPO="leehyuk1108/CarrotLink_notser"
readonly TARGET_BRANCH="dev"
readonly EXPECTED_PACKAGE="com.example.carrot_pilot_manager"
readonly EXPECTED_CERT_SHA256="55a14240fb656db17c66c695a61ae5679982a5ae24e233563a43211c5125fa94"
readonly STABLE_ENDPOINT="https://hl-cloud.leehyuk1108-comma.workers.dev/api/releases/latest"
readonly DEV_ENDPOINT="https://hl-cloud.leehyuk1108-comma.workers.dev/api/releases?per_page=1"

usage() {
  echo "Usage: $0 /absolute/path/CarrotLink.apk [release-notes.txt]" >&2
  exit 2
}

find_android_tool() {
  local name="$1"
  local sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  find "$sdk_root/build-tools" -type f -name "$name" 2>/dev/null | sort | tail -n 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage
readonly APK="$1"
readonly NOTES_FILE="${2:-}"
[[ -f "$APK" ]] || { echo "APK not found: $APK" >&2; exit 1; }
[[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || { echo "Notes not found: $NOTES_FILE" >&2; exit 1; }

for tool in curl jq unzip strings shasum git; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done

readonly AAPT="${AAPT:-$(find_android_tool aapt)}"
readonly APKSIGNER="${APKSIGNER:-$(find_android_tool apksigner)}"
[[ -x "$AAPT" ]] || { echo "aapt not found" >&2; exit 1; }
[[ -x "$APKSIGNER" ]] || { echo "apksigner not found" >&2; exit 1; }

readonly TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

readonly PACKAGE_LINE="$("$AAPT" dump badging "$APK" | head -n 1)"
readonly PACKAGE_NAME="$(printf '%s\n' "$PACKAGE_LINE" | sed -n "s/.*package: name='\\([^']*\\)'.*/\\1/p")"
readonly VERSION_CODE="$(printf '%s\n' "$PACKAGE_LINE" | sed -n "s/.*versionCode='\\([^']*\\)'.*/\\1/p")"
readonly VERSION_NAME="$(printf '%s\n' "$PACKAGE_LINE" | sed -n "s/.*versionName='\\([^']*\\)'.*/\\1/p")"
[[ "$PACKAGE_NAME" == "$EXPECTED_PACKAGE" ]] || { echo "Unexpected package: $PACKAGE_NAME" >&2; exit 1; }
[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || { echo "Invalid versionCode: $VERSION_CODE" >&2; exit 1; }
[[ -n "$VERSION_NAME" && "$VERSION_NAME" != *+* ]] || { echo "Invalid versionName: $VERSION_NAME" >&2; exit 1; }

readonly CERT_SHA256="$("$APKSIGNER" verify --print-certs "$APK" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n 1)"
[[ "$CERT_SHA256" == "$EXPECTED_CERT_SHA256" ]] || { echo "Signing certificate mismatch: $CERT_SHA256" >&2; exit 1; }

unzip -p "$APK" lib/arm64-v8a/libapp.so | strings -a > "$TMP_DIR/libapp.strings"
LC_ALL=C grep -aFq "$STABLE_ENDPOINT" "$TMP_DIR/libapp.strings" || { echo "Stable update endpoint missing" >&2; exit 1; }
LC_ALL=C grep -aFq "$DEV_ENDPOINT" "$TMP_DIR/libapp.strings" || { echo "Dev update endpoint missing" >&2; exit 1; }

readonly FILE_NAME="$(basename "$APK")"
readonly FILE_SIZE="$(stat -f '%z' "$APK" 2>/dev/null || stat -c '%s' "$APK")"
readonly SHA256="$(shasum -a 256 "$APK" | awk '{print $1}')"
readonly TAG="v${VERSION_NAME}+${VERSION_CODE}"
readonly RELEASE_BUILD="$(printf '%s\n' "$FILE_NAME" | sed -n 's/.*-v\([0-9][0-9]*\)\.apk$/v\1/p')"
readonly RELEASE_NAME="CarrotLink fix5 ${RELEASE_BUILD:-$VERSION_NAME}"

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  TOKEN="$GITHUB_TOKEN"
else
  CREDENTIAL="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill)"
  TOKEN="$(printf '%s\n' "$CREDENTIAL" | sed -n 's/^password=//p')"
fi
[[ -n "$TOKEN" ]] || { echo "GitHub token not found" >&2; exit 1; }

readonly API="https://api.github.com/repos/$REPO"
readonly AUTH_HEADER="Authorization: Bearer $TOKEN"
readonly ACCEPT_HEADER="Accept: application/vnd.github+json"
readonly VERSION_HEADER="X-GitHub-Api-Version: 2022-11-28"
readonly ENCODED_TAG="$(jq -nr --arg value "$TAG" '$value | @uri')"

existing_status="$(curl -sS -o "$TMP_DIR/existing.json" -w '%{http_code}' -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -H "$VERSION_HEADER" "$API/releases/tags/$ENCODED_TAG")"
[[ "$existing_status" == "404" ]] || { echo "Release already exists or lookup failed: HTTP $existing_status" >&2; exit 1; }

if [[ -n "$NOTES_FILE" ]]; then
  NOTES="$(< "$NOTES_FILE")"
else
  NOTES="Managed CarrotLink update."
fi
BODY="${NOTES}

SHA-256: ${SHA256}"
PAYLOAD="$(jq -n --arg tag "$TAG" --arg name "$RELEASE_NAME" --arg body "$BODY" --arg target "$TARGET_BRANCH" '{tag_name:$tag,target_commitish:$target,name:$name,body:$body,draft:true,prerelease:false}')"

create_status="$(curl -sS -o "$TMP_DIR/release.json" -w '%{http_code}' -X POST -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -H "$VERSION_HEADER" "$API/releases" -d "$PAYLOAD")"
[[ "$create_status" == "201" ]] || { jq -r '.message // .' "$TMP_DIR/release.json" >&2; exit 1; }
readonly RELEASE_ID="$(jq -r '.id' "$TMP_DIR/release.json")"
readonly ASSET_NAME="$(jq -nr --arg value "$FILE_NAME" '$value | @uri')"

echo "Uploading $FILE_NAME ($FILE_SIZE bytes) to draft release $TAG"
upload_status="$(curl -sS -o "$TMP_DIR/asset.json" -w '%{http_code}' -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/vnd.android.package-archive' --data-binary "@$APK" "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$ASSET_NAME")"
[[ "$upload_status" == "201" ]] || { jq -r '.message // .' "$TMP_DIR/asset.json" >&2; exit 1; }
[[ "$(jq -r '.size' "$TMP_DIR/asset.json")" == "$FILE_SIZE" ]] || { echo "Uploaded asset size mismatch" >&2; exit 1; }

publish_status="$(curl -sS -o "$TMP_DIR/published.json" -w '%{http_code}' -X PATCH -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -H "$VERSION_HEADER" "$API/releases/$RELEASE_ID" -d '{"draft":false}')"
[[ "$publish_status" == "200" ]] || { jq -r '.message // .' "$TMP_DIR/published.json" >&2; exit 1; }

echo "Published: $(jq -r '.html_url' "$TMP_DIR/published.json")"
echo "SHA-256: $SHA256"
