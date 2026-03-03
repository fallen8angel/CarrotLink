# C3 Carrot 7000 Home HUD Analysis (2026-02-27)

## Scope
- Target: `http://<device_ip>:7000/` Home tab HUD card (image style requested by user)
- Focus: UI structure, data source, render pipeline, Flutter porting points

## Source Files
- Server: `d:/CarrotLink/c3-v10-wip/selfdrive/carrot/carrot_server.py`
- Web markup: `d:/CarrotLink/c3-v10-wip/selfdrive/carrot/web/index.html`
- HUD renderer: `d:/CarrotLink/c3-v10-wip/selfdrive/carrot/web/hud_card.js`
- HUD styles: `d:/CarrotLink/c3-v10-wip/selfdrive/carrot/web/hud_card.css`

## Runtime Facts
- Service process is always-on in manager:
  - `system/manager/process_config.py` -> `PythonProcess("carrot_server", "selfdrive.carrot.carrot_server", always_run)`
- Default port:
  - `carrot_server.py --port 7000` (default 7000)

## HUD DOM Mapping (Home)
Defined in `web/index.html`:
- Top minis: `CPU`, `MEM`, `VOLT/DISK`
  - ids: `hudCpuVal`, `hudMemVal`, `hudDiskLabel`, `hudDiskVal`
- Main:
  - speed: `hudSpeed`
  - temp reason/speed: `hudTempReason`, `hudTempSpeed`
  - set speed: `hudSetSpeed`
  - gear badge: `hudGear`
  - gap number: `hudGapNum`
  - signal/red dots: `hudSignalDot`, `hudRedDot`
- Bottom:
  - GPS indicator: `hudGps`
  - drive mode pill: `hudDriveMode`
  - road limit: `hudRoadLimitVal`
  - bars: `hudBars` + `.hudBar`

## Data Path
1. Browser connects `ws://<host>/ws/carstate`.
2. Server `ws_carstate` publishes payload at ~10Hz.
3. `app.js` maps payload to `DrivingHud.update(payload)`.
4. `hud_card.js` applies values to DOM.

## Server Payload Fields (ws_carstate)
From `carrot_server.py`:
- `vEgo`, `vSetKph`, `gear`, `gpsOk`
- `cpuTempC`, `memPct`
- `diskPct`, `diskLabel` (`VOLT`/`DISK` toggled every ~3.2s)
- `tfGap`, `tfBars`, `driveMode`
- placeholders: `tlight`, `redDot`, `temp`, `speedLimitKph`, `speedLimitOver`, `apm`

## Visual Characteristics
- Square card (`aspect-ratio: 1/1`, max width 320)
- Dark background, neon green highlights
- `speed_bg.png` decorative background in main zone
- Dense absolute-position layout (CSS `position: absolute`)

## Known Behavior Notes
- If telemetry unavailable, placeholders remain (`--`, `U`, `Normal`) by design.
- `temp` section keeps default text if no valid temp payload.
- Current client rendering favors VOLT formatting for `hudDiskVal`.

## Flutter Porting Notes (HomeTab target)
Target insertion point:
- `d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/home_tab.dart`
- Insert under existing status `DesignCard`.

Recommended phase-1 (requested "first, same look only"):
- Build static HUD card widget (no live binding).
- Keep exact layout ratio (1:1), same labels and placeholder values.
- Reuse `speed_bg.png` as Flutter asset.

Phase-2 (optional later):
- Bind live values from device source (`ws://<ip>:7000/ws/carstate` or mapped internal service).

## Risk
- Pixel-perfect parity needs fixed typography and absolute layout tuning by device width.
- Existing app theme may alter contrast; HUD widget should use explicit colors to match web look.
