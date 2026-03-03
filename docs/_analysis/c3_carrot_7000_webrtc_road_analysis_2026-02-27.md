# C3 Carrot 7000 WebRTC Road Camera Analysis (2026-02-27)

## Scope
- Target: Home page WebRTC road camera flow in carrot 7000 dashboard
- Focus: negotiation flow, proxy path, reconnect behavior, integration constraints

## Source Files
- Client logic:
  - `d:/CarrotLink/c3-v10-wip/selfdrive/carrot/web/app.js`
  - `d:/CarrotLink/c3-v10-wip/selfdrive/carrot/web/webrtc_test.html`
- Server proxy:
  - `d:/CarrotLink/c3-v10-wip/selfdrive/carrot/carrot_server.py`

## Architecture
Client browser does not talk directly to webrtcd.

Path:
1. Browser creates RTCPeerConnection offer in `app.js`.
2. Browser POSTs offer JSON to `/stream`.
3. `carrot_server.py` forwards body to `http://127.0.0.1:5001/stream`.
4. Answer from webrtcd is proxied back to browser.
5. Browser sets remote description and waits for video track.

## Key Endpoints
- UI host: `http://<device_ip>:7000/`
- Proxy endpoint (same origin): `POST /stream`
- Upstream webrtcd endpoint: `http://127.0.0.1:5001/stream`
- Car telemetry WS (for HUD sync): `ws://<host>/ws/carstate`
- Server state WS: `ws://<host>/ws/state`

## Client Behavior (app.js)
- `rtcInitAuto()`:
  - waits for server readiness via `/api/settings`
  - starts connect attempt
  - reconnect on visibility resume
- `rtcConnectOnce()`:
  - creates `RTCPeerConnection`
  - adds recvonly video transceiver
  - creates offer, gathers ICE, POST `/stream` with:
    - `sdp`
    - `cameras: ["road"]`
  - receives answer and sets remote description
  - arms track timeout fallback
- reconnect:
  - on `failed/disconnected/closed`, disconnect and retry

## Server Proxy Behavior (carrot_server.py)
- `/stream` handler reads request body and content-type.
- forwards to local webrtcd via aiohttp ClientSession.
- returns upstream status/body/content-type as-is.
- on proxy failure: returns `502` JSON `{ok:false,error:...}`.

## Operational Notes
- WebRTC card in Home stays hidden until track arrives.
- HUD auto-docks to video overlay in fullscreen/landscape mode.
- If no track arrives in timeout window, client retries automatically.

## Flutter Integration Implications
If Flutter app wants same road camera UX later:
- Option A: keep using webview to reuse this exact stack.
- Option B: native Flutter WebRTC client implementation (higher cost).
- Option C: call existing 7000 web UI in embedded webview only for camera section.

For current user request ("HUD first"), WebRTC can remain unchanged and documented.
