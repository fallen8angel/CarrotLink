part of 'live_drive_canvas_screen.dart';

extension _LiveDriveCanvasCameraHtmlComponents on _LiveDriveCanvasScreenState {
  String _buildLiveCameraHtmlImpl(_DriveCameraKind cameraKind) {
    final streamEndpoints = jsonEncode(
      _streamEndpointCandidates.map((u) => u.toString()).toList(),
    );
    final cameraName =
        cameraKind == _DriveCameraKind.wideRoad ? 'wideRoad' : 'road';
    final directWsUrl = 'ws://$_hostIp:7766/ws/camera/$cameraName';
    final modePolicy = _openpilotOverlayMode ? 'sidecar_only' : 'webrtc_only';
    return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no" />
  <style>
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background: #000;
      overflow: hidden;
    }
    #root {
      position: fixed;
      inset: 0;
      width: 100vw;
      height: 100vh;
      background: #000;
      overflow: hidden;
    }
    #c {
      position: fixed;
      left: 0;
      top: 0;
      width: 100vw;
      height: 100vh;
      display: block;
      background: #000;
      z-index: 1;
      backface-visibility: hidden;
      transform: translateZ(0);
      will-change: transform;
    }
    #v {
      position: fixed;
      inset: 0;
      width: 100vw;
      height: 100vh;
      object-fit: cover;
      display: none;
      background: #000;
      z-index: 2;
      backface-visibility: hidden;
      transform: translateZ(0);
      will-change: transform;
    }
    #v::-webkit-media-controls,
    #v::-webkit-media-controls-enclosure,
    #v::-webkit-media-controls-panel,
    #v::-webkit-media-controls-start-playback-button {
      display: none !important;
      -webkit-appearance: none !important;
      opacity: 0 !important;
      visibility: hidden !important;
      pointer-events: none !important;
    }
  </style>
</head>
<body>
  <div id="root">
    <canvas id="c"></canvas>
    <video id="v" autoplay playsinline muted></video>
  </div>
  <script>
    const DIRECT_WS_URL = ${jsonEncode(directWsUrl)};
    const CAMERA_NAME = ${jsonEncode(cameraName)};
    const STREAM_ENDPOINTS = $streamEndpoints;
    const CODEC_CANDIDATES = ['avc1.640028', 'avc1.64001f', 'avc1.4d401f', 'avc1.42e01f', 'avc1.42e01e'];
    const MODE_POLICY = ${jsonEncode(modePolicy)};
    const ALLOW_DIRECT = MODE_POLICY === 'sidecar_only';
    const ALLOW_WEBRTC = MODE_POLICY === 'webrtc_only';
    const ENABLE_SHARPEN = ${_LiveDriveCanvasScreenState._webCameraSharpenEnabled ? 'true' : 'false'};

    const canvas = document.getElementById('c');
    const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
    const video = document.getElementById('v');
    const DEVICE_MEMORY_GB = Number(navigator.deviceMemory || 0);
    const CPU_THREADS = Number(navigator.hardwareConcurrency || 0);

    let ws = null;
    let pc = null;
    let decoder = null;
    let decoderCodec = '';
    let waitingKey = true;
    let gotFrame = false;
    let watchdog = null;
    let reconnectTimer = null;
    let directProbeTimer = null;
    let mode = ALLOW_DIRECT ? 'direct' : 'webrtc';
    let directErrorCount = 0;
    let webCodecsUnsupported = false;
    let lastDirectFrameId = -1;
    let droppedOutdated = 0;
    let droppedQueue = 0;
    let sourceW = 0;
    let sourceH = 0;
    let lastCameraFramePosted = -1;
    let renderDpr = 1.0;
    let webrtcVideoReady = false;
    const pendingFrameIds = [];

    try {
      video.controls = false;
      video.disablePictureInPicture = true;
      video.playsInline = true;
      video.autoplay = true;
      video.muted = true;
      video.setAttribute('playsinline', '');
      video.setAttribute('webkit-playsinline', '');
      video.setAttribute('disablePictureInPicture', '');
      video.setAttribute('controlsList', 'nodownload noplaybackrate noremoteplayback nofullscreen');
    } catch (_) {}

    function computeRenderDpr() {
      const base = Number(window.devicePixelRatio || 1);
      let cap = 1.12;
      if (CPU_THREADS >= 8 || DEVICE_MEMORY_GB >= 6) {
        cap = 1.45;
      } else if (CPU_THREADS >= 6 || DEVICE_MEMORY_GB >= 4) {
        cap = 1.30;
      } else if (CPU_THREADS >= 4 || DEVICE_MEMORY_GB >= 3) {
        cap = 1.20;
      }
      return Math.max(1.0, Math.min(base, cap));
    }

    function applySharpenFilter() {
      if (!ENABLE_SHARPEN) {
        canvas.style.filter = 'none';
        return;
      }
      const applyBoost = renderDpr <= 1.24;
      if (!applyBoost) {
        canvas.style.filter = 'none';
        return;
      }
      canvas.style.filter = 'contrast(1.05) saturate(1.04) brightness(1.01)';
    }

    function resizeCanvas() {
      const cssW = Math.max(1, window.innerWidth || 1);
      const cssH = Math.max(1, window.innerHeight || 1);
      renderDpr = computeRenderDpr();
      const pixelW = Math.max(1, Math.round(cssW * renderDpr));
      const pixelH = Math.max(1, Math.round(cssH * renderDpr));
      if (canvas.width !== pixelW) canvas.width = pixelW;
      if (canvas.height !== pixelH) canvas.height = pixelH;
      canvas.style.width = cssW + 'px';
      canvas.style.height = cssH + 'px';
      try { ctx.imageSmoothingEnabled = true; } catch (_) {}
      try { ctx.imageSmoothingQuality = renderDpr > 1.25 ? 'medium' : 'high'; } catch (_) {}
      applySharpenFilter();
    }

    function updatePresentation() {
      if (mode === 'direct') {
        canvas.style.display = 'block';
        canvas.style.opacity = '1';
        video.style.display = 'none';
        video.style.opacity = '0';
        return;
      }
      const showVideo = webrtcVideoReady;
      canvas.style.display = showVideo ? 'none' : 'block';
      canvas.style.opacity = '1';
      video.style.display = showVideo ? 'block' : 'none';
      video.style.opacity = showVideo ? '1' : '0';
    }

    function setMode(next) {
      mode = next;
      if (next === 'direct') {
        webrtcVideoReady = false;
        try { video.pause(); } catch (_) {}
      }
      updatePresentation();
    }

    function postToFlutter(payload) {
      try {
        if (window.CarrotCamera && typeof window.CarrotCamera.postMessage === 'function') {
          window.CarrotCamera.postMessage(JSON.stringify(payload));
        }
      } catch (_) {}
    }

    function payloadWithCamera(payload) {
      if (!payload || typeof payload !== 'object') return payload;
      return Object.assign({ camera: CAMERA_NAME }, payload);
    }

    function publishSourceSize(width, height) {
      if (!Number.isFinite(width) || !Number.isFinite(height)) return;
      if (width <= 0 || height <= 0) return;
      if (sourceW === width && sourceH === height) return;
      sourceW = width;
      sourceH = height;
      postToFlutter(payloadWithCamera({ type: 'camera_meta', width, height }));
    }

    function publishCameraFrame(frameId) {
      if (!Number.isFinite(frameId) || frameId < 0) return;
      if (frameId <= lastCameraFramePosted) return;
      lastCameraFramePosted = frameId;
      postToFlutter(payloadWithCamera({ type: 'camera_frame', frameId: frameId }));
    }

    function drawFrameCover(frame) {
      const sw = Math.max(1, Number(frame.displayWidth || frame.codedWidth || 0));
      const sh = Math.max(1, Number(frame.displayHeight || frame.codedHeight || 0));
      publishSourceSize(sw, sh);

      const cw = Math.max(1, canvas.width);
      const ch = Math.max(1, canvas.height);
      const scale = Math.max(cw / sw, ch / sh);
      const dw = sw * scale;
      const dh = sh * scale;
      const dx = (cw - dw) * 0.5;
      const dy = (ch - dh) * 0.5;

      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, cw, ch);
      try {
        ctx.drawImage(frame, dx, dy, dw, dh);
      } finally {
        try { frame.close(); } catch (_) {}
      }
    }

    function clearReconnect() {
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
    }

    function clearDirectProbe() {
      if (directProbeTimer) {
        clearTimeout(directProbeTimer);
        directProbeTimer = null;
      }
    }

    function scheduleDirectProbe(ms) {
      if (!ALLOW_DIRECT) return;
      clearDirectProbe();
      if (webCodecsUnsupported) return;
      directProbeTimer = setTimeout(() => {
        directProbeTimer = null;
        if (mode === 'webrtc' && ALLOW_DIRECT) {
          connectDirect().catch(() => {});
        }
      }, ms || 8000);
    }

    function scheduleReconnect(ms) {
      clearReconnect();
      reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        if (mode === 'direct' && ALLOW_DIRECT) {
          connectDirect().catch(() => {});
        } else if (ALLOW_WEBRTC) {
          connectWebRtc().catch(() => {});
        } else if (ALLOW_DIRECT) {
          connectDirect().catch(() => {});
        }
      }, ms || 900);
    }

    function clearWatchdog() {
      if (watchdog) {
        clearTimeout(watchdog);
        watchdog = null;
      }
    }

    function armWatchdog() {
      if (!ALLOW_DIRECT) return;
      clearWatchdog();
      watchdog = setTimeout(() => {
        if (!gotFrame && mode === 'direct' && ALLOW_DIRECT) {
          postToFlutter(payloadWithCamera({ type: 'camera_error', reason: 'no_frames' }));
          if (ALLOW_WEBRTC) {
            fallbackToWebRtc('no_frames');
          } else {
            scheduleReconnect(900);
          }
        }
      }, 4500);
    }

    function cleanupSocket() {
      clearWatchdog();
      try { if (ws) ws.close(); } catch (_) {}
      ws = null;
    }

    function cleanupPc() {
      try { if (pc) pc.close(); } catch (_) {}
      pc = null;
      try { video.srcObject = null; } catch (_) {}
      webrtcVideoReady = false;
      updatePresentation();
    }

    function publishVideoSize() {
      const w = Number(video.videoWidth || 0);
      const h = Number(video.videoHeight || 0);
      if (w > 0 && h > 0) publishSourceSize(w, h);
    }

    function webrtcSessionHealthy() {
      if (!pc) return false;
      const st = String(pc.connectionState || '');
      if (st !== 'connected' && st !== 'connecting') return false;
      return !!video.srcObject;
    }

    function normalizeTimestamp(rawTs) {
      let ts = Number(rawTs || 0);
      if (!Number.isFinite(ts) || ts <= 0) {
        ts = performance.now() * 1000.0;
      } else if (ts > 1000000000000000) {
        ts = ts / 1000.0;
      } else if (ts > 1000000000000) {
        // microseconds scale already
      } else if (ts > 1000000000) {
        ts = ts * 1000.0;
      } else {
        ts = ts * 1000000.0;
      }
      return Math.max(0, Math.floor(ts));
    }

    function closeDecoder() {
      if (!decoder) return;
      try { decoder.close(); } catch (_) {}
      decoder = null;
      decoderCodec = '';
      waitingKey = true;
      lastDirectFrameId = -1;
      pendingFrameIds.length = 0;
    }

    function parseFramePacket(buf) {
      if (!buf || buf.byteLength < 5) return null;
      const view = new DataView(buf);
      const metaLen = view.getUint32(0, false);
      if (metaLen < 2 || metaLen > 65536) return null;
      const offset = 4 + metaLen;
      if (offset >= buf.byteLength) return null;
      try {
        const metaBytes = new Uint8Array(buf, 4, metaLen);
        const metaText = new TextDecoder().decode(metaBytes);
        const meta = JSON.parse(metaText);
        const data = new Uint8Array(buf, offset);
        if (!data || data.length === 0) return null;
        return { meta, data };
      } catch (_) {
        return null;
      }
    }

    function hasStartCode(data) {
      const n = data.length;
      for (let i = 0; i + 3 < n; i++) {
        if (data[i] === 0 && data[i + 1] === 0) {
          if (data[i + 2] === 1) return true;
          if (data[i + 2] === 0 && data[i + 3] === 1) return true;
        }
      }
      return false;
    }

    function concatChunks(parts, total) {
      const out = new Uint8Array(total);
      let o = 0;
      for (const p of parts) {
        out.set(p, o);
        o += p.length;
      }
      return out;
    }

    function avccPayloadToAnnexB(data, lengthSize) {
      let off = 0;
      const parts = [];
      let total = 0;
      const ls = Math.max(1, Math.min(4, lengthSize || 4));
      while (off + ls <= data.length) {
        let nalLen = 0;
        for (let i = 0; i < ls; i++) {
          nalLen = (nalLen << 8) | data[off + i];
        }
        off += ls;
        if (nalLen <= 0 || off + nalLen > data.length) return null;
        const start = new Uint8Array([0, 0, 0, 1]);
        const nal = data.subarray(off, off + nalLen);
        parts.push(start, nal);
        total += start.length + nal.length;
        off += nalLen;
      }
      if (off !== data.length || total <= 0) return null;
      return concatChunks(parts, total);
    }

    function avcConfigToAnnexB(data) {
      if (!data || data.length < 7) return null;
      if (data[0] !== 1) return null;
      const lengthSize = (data[4] & 0x03) + 1;
      let off = 5;
      const numSps = data[off] & 0x1f;
      off += 1;
      const parts = [];
      let total = 0;

      for (let i = 0; i < numSps; i++) {
        if (off + 2 > data.length) return null;
        const len = (data[off] << 8) | data[off + 1];
        off += 2;
        if (len <= 0 || off + len > data.length) return null;
        const start = new Uint8Array([0, 0, 0, 1]);
        const sps = data.subarray(off, off + len);
        parts.push(start, sps);
        total += start.length + sps.length;
        off += len;
      }

      if (off + 1 > data.length) return null;
      const numPps = data[off];
      off += 1;
      for (let i = 0; i < numPps; i++) {
        if (off + 2 > data.length) return null;
        const len = (data[off] << 8) | data[off + 1];
        off += 2;
        if (len <= 0 || off + len > data.length) return null;
        const start = new Uint8Array([0, 0, 0, 1]);
        const pps = data.subarray(off, off + len);
        parts.push(start, pps);
        total += start.length + pps.length;
        off += len;
      }

      let framePart = null;
      if (off < data.length) {
        framePart = avccPayloadToAnnexB(data.subarray(off), lengthSize);
      }
      if (framePart && framePart.length > 0) {
        parts.push(framePart);
        total += framePart.length;
      }
      if (total <= 0) return null;
      return concatChunks(parts, total);
    }

    function toAnnexB(data, isKeyFrame) {
      if (!data || data.length === 0) return null;
      if (hasStartCode(data)) return data;
      if (isKeyFrame && data[0] === 1) {
        const keyConverted = avcConfigToAnnexB(data);
        if (keyConverted && keyConverted.length > 0) return keyConverted;
      }
      const directConverted = avccPayloadToAnnexB(data, 4);
      if (directConverted && directConverted.length > 0) return directConverted;
      return data;
    }

    async function chooseDecoderCodec(codecHint) {
      if (!window.VideoDecoder || !window.VideoDecoder.isConfigSupported) {
        return (typeof codecHint === 'string' && codecHint.length > 0) ? codecHint : 'avc1.640028';
      }
      const candidates = [];
      if (typeof codecHint === 'string' && codecHint.length > 0) candidates.push(codecHint);
      for (const c of CODEC_CANDIDATES) if (!candidates.includes(c)) candidates.push(c);
      for (const codec of candidates) {
        try {
          const result = await VideoDecoder.isConfigSupported({
            codec: codec,
            optimizeForLatency: true,
            hardwareAcceleration: 'prefer-hardware',
          });
          if (result && result.supported) return codec;
        } catch (_) {}
      }
      return null;
    }

    async function ensureDecoder(codecHint) {
      if (!window.VideoDecoder || !window.EncodedVideoChunk) return false;
      if (decoder && decoder.state === 'configured') {
        return true;
      }
      closeDecoder();
      const selected = await chooseDecoderCodec(codecHint);
      if (!selected) return false;
      decoderCodec = selected;
      try {
        decoder = new VideoDecoder({
          output: (frame) => {
            gotFrame = true;
            clearWatchdog();
            const renderedFrameId = pendingFrameIds.length ? pendingFrameIds.shift() : null;
            if (Number.isFinite(renderedFrameId)) {
              publishCameraFrame(renderedFrameId);
            }
            drawFrameCover(frame);
          },
          error: () => {
            directErrorCount++;
            postToFlutter(
              payloadWithCamera({ type: 'camera_error', reason: 'decoder_error' }),
            );
            closeDecoder();
            if (directErrorCount >= 2) {
              fallbackToWebRtc('decoder_error');
            } else {
              scheduleReconnect(900);
            }
          }
        });
        decoder.configure({
          codec: decoderCodec,
          optimizeForLatency: true,
          hardwareAcceleration: 'prefer-hardware',
        });
        waitingKey = true;
        return true;
      } catch (_) {
        closeDecoder();
        return false;
      }
    }

    function fallbackToWebRtc(reason) {
      cleanupSocket();
      closeDecoder();
      if (!ALLOW_WEBRTC) {
        setMode('direct');
        postToFlutter(
          payloadWithCamera({
            type: 'camera_error',
            reason: 'direct_only_reconnect:' + String(reason || 'unknown'),
          }),
        );
        scheduleReconnect(900);
        return;
      }
      setMode('webrtc');
      postToFlutter(
        payloadWithCamera({
          type: 'camera_error',
          reason: 'fallback_webrtc:' + String(reason || 'unknown'),
        }),
      );
      connectWebRtc().catch(() => {});
      scheduleDirectProbe(8000);
    }

    async function connectDirect() {
      if (!ALLOW_DIRECT) {
        if (ALLOW_WEBRTC) {
          connectWebRtc().catch(() => {});
        }
        return;
      }
      cleanupPc();
      cleanupSocket();
      closeDecoder();
      gotFrame = false;
      directErrorCount = 0;
      setMode('direct');

      if (!window.VideoDecoder || !window.EncodedVideoChunk) {
        webCodecsUnsupported = true;
        if (ALLOW_WEBRTC) {
          fallbackToWebRtc('webcodecs_unsupported');
        } else {
          postToFlutter(
            payloadWithCamera({
              type: 'camera_error',
              reason: 'webcodecs_unsupported',
            }),
          );
          scheduleReconnect(1500);
        }
        return;
      }
      webCodecsUnsupported = false;

      armWatchdog();
      try {
        ws = new WebSocket(DIRECT_WS_URL);
        ws.binaryType = 'arraybuffer';
        ws.onopen = () => {
          armWatchdog();
          clearDirectProbe();
        };
        ws.onmessage = async (event) => {
          if (typeof event.data === 'string') return;
          const parsed = parseFramePacket(event.data);
          if (!parsed) return;
          const meta = parsed.meta || {};
          if (!(await ensureDecoder(meta.codec))) {
            if (ALLOW_WEBRTC) {
              fallbackToWebRtc('decoder_unsupported');
            } else {
              postToFlutter(
                payloadWithCamera({
                  type: 'camera_error',
                  reason: 'decoder_unsupported',
                }),
              );
              scheduleReconnect(900);
            }
            return;
          }

          const frameId = Number(meta.frameId ?? -1);
          if (Number.isFinite(frameId) && frameId >= 0) {
            if (lastDirectFrameId >= 0 && frameId <= lastDirectFrameId) {
              droppedOutdated++;
              return;
            }
            lastDirectFrameId = frameId;
          }

          const metaW = Number(meta.width || 0);
          const metaH = Number(meta.height || 0);
          if (metaW > 0 && metaH > 0) {
            publishSourceSize(metaW, metaH);
          }

          const chunkType = meta.keyFrame === true ? 'key' : 'delta';
          if (waitingKey && chunkType !== 'key') return;
          waitingKey = false;

          if (decoder && decoder.decodeQueueSize > 2 && chunkType !== 'key') {
            droppedQueue++;
            return;
          }

          try {
            const ts = normalizeTimestamp(meta.timestampEof || meta.timestampSof || meta.ts);
            const annexb = toAnnexB(parsed.data, chunkType === 'key');
            if (!annexb || annexb.length === 0) return;
            const chunk = new EncodedVideoChunk({
              type: chunkType,
              timestamp: ts,
              data: annexb,
            });
            if (Number.isFinite(frameId) && frameId >= 0) {
              pendingFrameIds.push(frameId);
            }
            decoder.decode(chunk);
            if ((droppedOutdated + droppedQueue) > 0 && ((droppedOutdated + droppedQueue) % 120) === 0) {
              console.log('[DriveCanvas] direct drops outdated=' + droppedOutdated + ' queue=' + droppedQueue);
            }
          } catch (_) {
            if (pendingFrameIds.length) pendingFrameIds.pop();
            waitingKey = true;
          }
        };
        ws.onerror = () => {
          if (ALLOW_WEBRTC) {
            fallbackToWebRtc('socket_error');
          } else {
            postToFlutter(
              payloadWithCamera({
                type: 'camera_error',
                reason: 'socket_error',
              }),
            );
            scheduleReconnect(900);
          }
        };
        ws.onclose = () => {
          if (mode === 'direct') {
            scheduleReconnect(gotFrame ? 700 : 1000);
          }
        };
      } catch (_) {
        if (ALLOW_WEBRTC) {
          fallbackToWebRtc('socket_open_failed');
        } else {
          postToFlutter(
            payloadWithCamera({
              type: 'camera_error',
              reason: 'socket_open_failed',
            }),
          );
          scheduleReconnect(1100);
        }
      }
    }

    async function waitIceComplete(timeoutMs) {
      if (!pc || pc.iceGatheringState === 'complete') return;
      await new Promise((resolve) => {
        const t = setTimeout(resolve, timeoutMs || 8000);
        const onChange = () => {
          if (!pc || pc.iceGatheringState === 'complete') {
            try { pc.removeEventListener('icegatheringstatechange', onChange); } catch (_) {}
            clearTimeout(t);
            resolve();
          }
        };
        pc.addEventListener('icegatheringstatechange', onChange);
      });
    }

    async function connectWebRtc() {
      if (!ALLOW_WEBRTC) {
        if (ALLOW_DIRECT) {
          connectDirect().catch(() => {});
        }
        return;
      }
      cleanupPc();
      setMode('webrtc');
      try {
        pc = new RTCPeerConnection({
          iceServers: [],
          sdpSemantics: 'unified-plan',
          iceCandidatePoolSize: 1
        });
        pc.addTransceiver('video', { direction: 'recvonly' });

        pc.ontrack = async (ev) => {
          const stream = (ev.streams && ev.streams[0]) ? ev.streams[0] : new MediaStream([ev.track]);
          video.srcObject = stream;
          try { await video.play(); } catch (_) {}
          setTimeout(() => {
            publishVideoSize();
          }, 100);
        };

        pc.onconnectionstatechange = () => {
          const st = pc ? pc.connectionState : 'closed';
          if (st === 'failed' || st === 'disconnected' || st === 'closed') {
            cleanupPc();
            scheduleReconnect(1500);
          }
        };

        pc.oniceconnectionstatechange = () => {
          const st = pc ? pc.iceConnectionState : 'closed';
          if (st === 'failed' || st === 'disconnected' || st === 'closed') {
            cleanupPc();
            scheduleReconnect(1500);
          }
        };

        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        await waitIceComplete(8000);

        let ans = null;
        let lastErr = 'no endpoint';
        for (const endpoint of STREAM_ENDPOINTS) {
          try {
            const r = await fetch(endpoint, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                sdp: pc.localDescription.sdp,
                cameras: [CAMERA_NAME],
                bridge_services_in: [],
                bridge_services_out: []
              })
            });
            if (!r.ok) {
              lastErr = endpoint + ' http ' + r.status;
              continue;
            }
            const body = await r.json();
            if (body && body.sdp) {
              ans = body;
              break;
            }
            lastErr = endpoint + ' invalid answer';
          } catch (e) {
            lastErr = endpoint + ' ' + (e && e.message ? e.message : String(e));
          }
        }
        if (!ans || !ans.sdp) throw new Error(lastErr);
        await pc.setRemoteDescription({ type: ans.type || 'answer', sdp: ans.sdp });
      } catch (_) {
        cleanupPc();
        scheduleReconnect(2000);
      }
    }

    resizeCanvas();
    updatePresentation();
    video.addEventListener('loadedmetadata', () => {
      publishVideoSize();
    });
    video.addEventListener('loadeddata', publishVideoSize);
    video.addEventListener('canplay', publishVideoSize);
    video.addEventListener('playing', () => {
      webrtcVideoReady = true;
      updatePresentation();
      publishVideoSize();
    });
    video.addEventListener('emptied', () => {
      if (mode !== 'webrtc') return;
      webrtcVideoReady = false;
      updatePresentation();
    });
    video.addEventListener('resize', () => {
      publishVideoSize();
    });
    window.addEventListener('resize', resizeCanvas);
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) return;
      if (mode === 'direct' && ALLOW_DIRECT) {
        if (!ws || !gotFrame) {
          connectDirect().catch(() => {});
        }
      } else if (ALLOW_WEBRTC) {
        if (webrtcSessionHealthy()) {
          try { video.play(); } catch (_) {}
          updatePresentation();
        } else {
          connectWebRtc().catch(() => {});
        }
      }
    });
    window.addEventListener('beforeunload', () => {
      cleanupSocket();
      closeDecoder();
      cleanupPc();
      clearReconnect();
      clearDirectProbe();
    });
    if (ALLOW_DIRECT) {
      connectDirect().catch(() => scheduleReconnect(1200));
    } else if (ALLOW_WEBRTC) {
      connectWebRtc().catch(() => scheduleReconnect(1200));
    }
  </script>
</body>
</html>
''';
  }

  String _buildIdleCameraHtmlImpl() {
    return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no" />
  <style>
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background: #000;
      overflow: hidden;
    }
  </style>
</head>
<body></body>
</html>
''';
  }
}
