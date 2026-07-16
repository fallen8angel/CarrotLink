const APK = Object.freeze({
  fileName: "CarrotLink-fix5-v13.apk",
  fileSize: 199471185,
  sha256: "a571d4baf4f75aa3006210d043a21ed1092cf64b47c7274ea010953ea69a63d7",
  version: "2.0106.9-fix5",
  versionCode: 2010609,
  releaseBuild: "v13",
  releaseDate: "2026-07-16",
  sourceCommit: "10074f9",
  partKeys: Array.from({ length: 10 }, (_, index) => `apk:v13:part:${String(index).padStart(2, "0")}`),
});

const RELEASE_SOURCE = Object.freeze({
  owner: "leehyuk1108",
  repo: "CarrotLink_notser",
  apiVersion: "2022-11-28",
});

const COOKIE_NAME = "hl_cloud_share";
const SESSION_SECONDS = 30 * 60;
const FAILURE_WINDOW_SECONDS = 10 * 60;
const MAX_FAILURES = 5;
const failedAttempts = new Map();
const encoder = new TextEncoder();

const SECURITY_HEADERS = Object.freeze({
  "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "X-Robots-Tag": "noindex, nofollow",
});

function secureCompare(left, right) {
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  const length = Math.max(a.length, b.length);
  let mismatch = a.length ^ b.length;
  for (let index = 0; index < length; index += 1) {
    mismatch |= (a[index] || 0) ^ (b[index] || 0);
  }
  return mismatch === 0;
}

function hex(bytes) {
  return [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sign(secret, value) {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return hex(await crypto.subtle.sign("HMAC", key, encoder.encode(value)));
}

function getCookie(request, name) {
  const prefix = `${name}=`;
  for (const item of (request.headers.get("Cookie") || "").split(";")) {
    const value = item.trim();
    if (value.startsWith(prefix)) return value.slice(prefix.length);
  }
  return "";
}

async function makeSessionToken(secret) {
  const expires = Math.floor(Date.now() / 1000) + SESSION_SECONDS;
  const nonce = crypto.randomUUID().replaceAll("-", "");
  const body = `${expires}.${nonce}`;
  return `${body}.${await sign(secret, body)}`;
}

async function hasSession(request, secret) {
  const token = getCookie(request, COOKIE_NAME);
  const parts = token.split(".");
  if (parts.length !== 3) return false;

  const [expiresText, nonce, signature] = parts;
  const expires = Number(expiresText);
  if (!Number.isInteger(expires) || expires <= Math.floor(Date.now() / 1000) || !nonce) return false;

  const expected = await sign(secret, `${expiresText}.${nonce}`);
  return secureCompare(signature, expected);
}

function sessionCookie(token, maxAge) {
  return `${COOKIE_NAME}=${token}; Path=/; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Strict`;
}

function json(payload, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      ...extraHeaders,
    },
  });
}

function gitHubHeaders(env, binary = false) {
  return {
    Accept: binary ? "application/octet-stream" : "application/vnd.github+json",
    Authorization: `Bearer ${env.GITHUB_RELEASE_TOKEN}`,
    "User-Agent": "HL-Cloud-Updater",
    "X-GitHub-Api-Version": RELEASE_SOURCE.apiVersion,
  };
}

function releaseApiUrl(path) {
  return `https://api.github.com/repos/${RELEASE_SOURCE.owner}/${RELEASE_SOURCE.repo}${path}`;
}

async function fetchLatestRelease(env) {
  if (!env.GITHUB_RELEASE_TOKEN) return null;
  const response = await fetch(releaseApiUrl("/releases/latest"), {
    headers: gitHubHeaders(env),
  });
  if (!response.ok) return null;
  return response.json();
}

function findApkAsset(release, requestedName = "") {
  if (!Array.isArray(release?.assets)) return null;
  return release.assets.find((asset) => {
    const name = typeof asset?.name === "string" ? asset.name : "";
    return name.endsWith(".apk") && (!requestedName || name === requestedName);
  }) || null;
}

function releaseDescriptor(release) {
  const asset = findApkAsset(release);
  if (!asset) return null;

  const tag = String(release.tag_name || "").replace(/^v/, "");
  const separator = tag.lastIndexOf("+");
  const version = separator > 0 ? tag.slice(0, separator) : tag;
  const versionCode = separator > 0 ? Number(tag.slice(separator + 1)) : 0;
  const buildMatch = asset.name.match(/(?:^|[-_.])v(\d+)(?:[-_.]|$)/i);
  const hashMatch = String(release.body || "").match(/SHA-256:\s*([a-f0-9]{64})/i);

  if (!version || !Number.isInteger(versionCode) || versionCode <= 0) return null;
  return {
    fileName: asset.name,
    fileSize: Number(asset.size) || 0,
    version,
    versionCode,
    releaseBuild: buildMatch ? `v${buildMatch[1]}` : version,
    releaseDate: String(release.published_at || "").slice(0, 10) || APK.releaseDate,
    sourceCommit: APK.sourceCommit,
    sha256: hashMatch ? hashMatch[1].toLowerCase() : "",
  };
}

function normalizeRelease(release, origin) {
  const assets = Array.isArray(release?.assets)
    ? release.assets
        .filter((asset) => typeof asset?.name === "string" && asset.name.endsWith(".apk"))
        .map((asset) => ({
          id: asset.id,
          name: asset.name,
          size: asset.size,
          content_type: asset.content_type || "application/vnd.android.package-archive",
          browser_download_url: `${origin}/api/releases/assets/${asset.id}/${encodeURIComponent(asset.name)}`,
        }))
    : [];

  return {
    id: release.id,
    tag_name: release.tag_name,
    name: release.name,
    body: release.body || "",
    draft: Boolean(release.draft),
    prerelease: Boolean(release.prerelease),
    target_commitish: release.target_commitish,
    published_at: release.published_at,
    assets,
  };
}

async function handleReleaseMetadata(request, env, latestOnly) {
  if (!env.GITHUB_RELEASE_TOKEN) {
    return json({ error: "업데이트 서버 설정이 완료되지 않았습니다." }, 503);
  }

  const path = latestOnly ? "/releases/latest" : "/releases?per_page=1";
  const upstream = await fetch(releaseApiUrl(path), {
    headers: gitHubHeaders(env),
  });
  if (!upstream.ok) {
    return json({ error: `업데이트 조회 실패: HTTP ${upstream.status}` }, upstream.status);
  }

  const payload = await upstream.json();
  const origin = new URL(request.url).origin;
  const normalized = latestOnly
    ? normalizeRelease(payload, origin)
    : (Array.isArray(payload) ? payload.slice(0, 1).map((release) => normalizeRelease(release, origin)) : []);
  return json(normalized, 200, { "Cache-Control": "public, max-age=30" });
}

async function proxyReleaseAsset(request, env, assetId, fileName) {
  if (!env.GITHUB_RELEASE_TOKEN) {
    return json({ error: "업데이트 서버 설정이 완료되지 않았습니다." }, 503);
  }

  const upstream = await fetch(releaseApiUrl(`/releases/assets/${assetId}`), {
    headers: gitHubHeaders(env, true),
    redirect: "follow",
  });
  if (!upstream.ok) {
    return json({ error: `업데이트 다운로드 실패: HTTP ${upstream.status}` }, upstream.status);
  }

  const headers = new Headers();
  headers.set("Cache-Control", "private, no-store");
  headers.set("Content-Disposition", upstream.headers.get("Content-Disposition") || `attachment; filename="${fileName}"`);
  headers.set("Content-Type", upstream.headers.get("Content-Type") || "application/vnd.android.package-archive");
  const contentLength = upstream.headers.get("Content-Length");
  if (contentLength) headers.set("Content-Length", contentLength);

  return new Response(request.method === "HEAD" ? null : upstream.body, {
    status: 200,
    headers,
  });
}

async function handleReleaseAsset(request, env, url) {
  if (!env.GITHUB_RELEASE_TOKEN) {
    return json({ error: "업데이트 서버 설정이 완료되지 않았습니다." }, 503);
  }

  const match = url.pathname.match(/^\/api\/releases\/assets\/(\d+)(?:\/([^/]+))?$/);
  if (!match) return json({ error: "찾을 수 없습니다." }, 404);

  const metadata = await fetch(releaseApiUrl(`/releases/assets/${match[1]}`), {
    headers: gitHubHeaders(env),
  });
  if (!metadata.ok) return json({ error: "찾을 수 없습니다." }, 404);
  const asset = await metadata.json();
  const fileName = String(asset.name || "");
  const requestedName = match[2] ? decodeURIComponent(match[2]) : fileName;
  if (!fileName.endsWith(".apk") || requestedName !== fileName) {
    return json({ error: "찾을 수 없습니다." }, 404);
  }

  return proxyReleaseAsset(request, env, match[1], fileName);
}

function addSecurityHeaders(response) {
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) headers.set(name, value);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function sameOrigin(request) {
  const origin = request.headers.get("Origin");
  if (origin && origin !== new URL(request.url).origin) return false;
  const fetchSite = request.headers.get("Sec-Fetch-Site");
  return !fetchSite || fetchSite === "same-origin" || fetchSite === "none";
}

function clientIp(request) {
  return request.headers.get("CF-Connecting-IP") || "unknown";
}

function retryAfterSeconds(ip) {
  const now = Date.now() / 1000;
  const recent = (failedAttempts.get(ip) || []).filter((stamp) => stamp > now - FAILURE_WINDOW_SECONDS);
  if (recent.length) failedAttempts.set(ip, recent);
  else failedAttempts.delete(ip);
  if (recent.length < MAX_FAILURES) return 0;
  return Math.max(1, Math.ceil(FAILURE_WINDOW_SECONDS - (now - recent[0])));
}

function recordFailure(ip) {
  if (failedAttempts.size > 2048) failedAttempts.clear();
  const recent = failedAttempts.get(ip) || [];
  recent.push(Date.now() / 1000);
  failedAttempts.set(ip, recent);
}

async function handleUnlock(request, env) {
  if (!sameOrigin(request)) return json({ error: "허용되지 않은 요청입니다." }, 403);

  const ip = clientIp(request);
  const retryAfter = retryAfterSeconds(ip);
  if (retryAfter) {
    return json({ error: "잠시 후 다시 시도해 주세요." }, 429, { "Retry-After": String(retryAfter) });
  }

  let password;
  try {
    const contentLength = Number(request.headers.get("Content-Length") || 0);
    if (contentLength > 4096) throw new Error("large body");
    ({ password } = await request.json());
  } catch {
    return json({ error: "잘못된 요청입니다." }, 400);
  }

  if (typeof password !== "string" || !secureCompare(password, env.HL_CLOUD_PASSWORD)) {
    recordFailure(ip);
    return json({ error: "비밀번호가 올바르지 않습니다." }, 401);
  }

  failedAttempts.delete(ip);
  const token = await makeSessionToken(env.SESSION_SECRET);
  return json(
    { ok: true },
    200,
    { "Set-Cookie": sessionCookie(token, SESSION_SECONDS) },
  );
}

async function handleStatus(request, env) {
  let descriptor = APK;
  try {
    descriptor = releaseDescriptor(await fetchLatestRelease(env)) || APK;
  } catch {}

  return json({
    unlocked: await hasSession(request, env.SESSION_SECRET),
    fileName: descriptor.fileName,
    fileSize: descriptor.fileSize,
    version: descriptor.version,
    versionCode: descriptor.versionCode,
    releaseBuild: descriptor.releaseBuild,
    releaseDate: descriptor.releaseDate,
    sourceCommit: descriptor.sourceCommit,
    sha256: descriptor.sha256,
    sessionSeconds: SESSION_SECONDS,
  });
}

function apkHeaders(descriptor = APK) {
  return {
    "Accept-Ranges": "none",
    "Cache-Control": "private, no-store",
    "Content-Disposition": `attachment; filename="${descriptor.fileName}"`,
    "Content-Length": String(descriptor.fileSize),
    "Content-Type": "application/vnd.android.package-archive",
  };
}

async function handleDownload(request, env, requestedName) {
  if (!(await hasSession(request, env.SESSION_SECRET))) {
    return json({ error: "다운로드하려면 비밀번호를 입력해 주세요." }, 403);
  }

  try {
    const release = await fetchLatestRelease(env);
    const asset = findApkAsset(release, requestedName);
    if (asset) {
      return proxyReleaseAsset(request, env, asset.id, asset.name);
    }
  } catch {}

  if (requestedName !== APK.fileName) {
    return json({ error: "찾을 수 없습니다." }, 404);
  }
  if (request.method === "HEAD") return new Response(null, { headers: apkHeaders() });

  let partIndex = 0;
  const body = new ReadableStream({
    async pull(controller) {
      try {
        if (partIndex >= APK.partKeys.length) {
          controller.close();
          return;
        }

        const part = await env.APK_KV.get(APK.partKeys[partIndex], { type: "arrayBuffer" });
        if (!part) throw new Error("APK part missing");
        partIndex += 1;
        controller.enqueue(new Uint8Array(part));
        if (partIndex >= APK.partKeys.length) controller.close();
      } catch (error) {
        controller.error(error);
      }
    },
  });

  return new Response(body, { headers: apkHeaders() });
}

async function route(request, env) {
  const url = new URL(request.url);

  if (url.pathname === "/api/releases/latest" && (request.method === "GET" || request.method === "HEAD")) {
    return handleReleaseMetadata(request, env, true);
  }
  if (url.pathname === "/api/releases" && (request.method === "GET" || request.method === "HEAD")) {
    return handleReleaseMetadata(request, env, false);
  }
  if (url.pathname.startsWith("/api/releases/assets/") && (request.method === "GET" || request.method === "HEAD")) {
    return handleReleaseAsset(request, env, url);
  }
  if (url.pathname === "/api/status" && (request.method === "GET" || request.method === "HEAD")) {
    return handleStatus(request, env);
  }
  if (url.pathname === "/api/unlock" && request.method === "POST") {
    return handleUnlock(request, env);
  }
  if (url.pathname === "/api/lock" && request.method === "POST") {
    if (!sameOrigin(request)) return json({ error: "허용되지 않은 요청입니다." }, 403);
    return json({ ok: true }, 200, { "Set-Cookie": sessionCookie("", 0) });
  }
  if (url.pathname.startsWith("/download/") && (request.method === "GET" || request.method === "HEAD")) {
    const requestedName = decodeURIComponent(url.pathname.slice("/download/".length));
    return handleDownload(request, env, requestedName);
  }
  if (url.pathname === "/favicon.ico" && (request.method === "GET" || request.method === "HEAD")) {
    return new Response(null, { status: 204, headers: { "Cache-Control": "public, max-age=86400" } });
  }
  if (url.pathname.startsWith("/api/") || url.pathname.startsWith("/download/")) {
    return json({ error: "찾을 수 없습니다." }, 404);
  }
  if (request.method !== "GET" && request.method !== "HEAD") {
    return json({ error: "허용되지 않은 요청입니다." }, 405, { Allow: "GET, HEAD" });
  }

  return env.ASSETS.fetch(request);
}

export default {
  async fetch(request, env) {
    if (!env.HL_CLOUD_PASSWORD || !env.SESSION_SECRET) {
      return addSecurityHeaders(json({ error: "서버 설정이 완료되지 않았습니다." }, 503));
    }
    return addSecurityHeaders(await route(request, env));
  },
};
