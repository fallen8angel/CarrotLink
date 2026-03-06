part of 'live_drive_canvas_screen.dart';

class _DriveOverlayPainter extends CustomPainter {
  final _DriveOverlaySnapshot snapshot;
  final bool isConnected;
  final Size sourceSize;
  final _DriveCameraKind cameraKind;
  final bool coverViewport;
  final bool showDebugGuides;
  final bool showPathFill;
  final bool showLaneLines;
  final bool showRoadEdge;
  final bool showLead1;
  final bool showLead2;
  final bool showRadarBadge;
  final bool showRadarVector;
  final bool showStopDistanceTf;
  final bool showStateText;

  static const double _baseSourceWidth = 1928.0;
  static const double _baseSourceHeight = 1208.0;
  static const double _clipMargin = 500.0;
  static const _M3 _viewFromDevice = _M3(
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    1.0,
    1.0,
    0.0,
    0.0,
  );

  const _DriveOverlayPainter({
    required this.snapshot,
    required this.isConnected,
    required this.sourceSize,
    required this.cameraKind,
    required this.coverViewport,
    this.showDebugGuides = false,
    this.showPathFill = true,
    this.showLaneLines = true,
    this.showRoadEdge = true,
    this.showLead1 = true,
    this.showLead2 = true,
    this.showRadarBadge = true,
    this.showRadarVector = true,
    this.showStopDistanceTf = true,
    this.showStateText = true,
  });

  _M3 _rotationFromEuler(List<double> rpy) {
    if (rpy.length < 3) return const _M3.identity();
    final roll = rpy[0];
    final pitch = rpy[1];
    final yaw = rpy[2];

    final cr = math.cos(roll);
    final sr = math.sin(roll);
    final cp = math.cos(pitch);
    final sp = math.sin(pitch);
    final cy = math.cos(yaw);
    final sy = math.sin(yaw);

    final rx = _M3(
      1.0,
      0.0,
      0.0,
      0.0,
      cr,
      -sr,
      0.0,
      sr,
      cr,
    );
    final ry = _M3(
      cp,
      0.0,
      sp,
      0.0,
      1.0,
      0.0,
      -sp,
      0.0,
      cp,
    );
    final rz = _M3(
      cy,
      -sy,
      0.0,
      sy,
      cy,
      0.0,
      0.0,
      0.0,
      1.0,
    );
    return rz.multiply(ry).multiply(rx);
  }

  _M3 _intrinsicForSource(Size source, bool wideCam) {
    final sx = source.width / _baseSourceWidth;
    final sy = source.height / _baseSourceHeight;
    final focal = wideCam ? 567.0 : 2648.0;
    return _M3(
      focal * sx,
      0.0,
      964.0 * sx,
      0.0,
      focal * sy,
      604.0 * sy,
      0.0,
      0.0,
      1.0,
    );
  }

  _M3 _calibTransformForSource(Size source) {
    final wideCam = cameraKind == _DriveCameraKind.wideRoad;
    final intrinsic = _intrinsicForSource(source, wideCam);
    final deviceFromCalib = _rotationFromEuler(snapshot.calibrationRpy);
    final wideFromDevice = wideCam
        ? _rotationFromEuler(snapshot.wideFromDeviceEuler)
        : const _M3.identity();
    final viewFromCalib = wideCam
        ? _viewFromDevice.multiply(wideFromDevice.multiply(deviceFromCalib))
        : _viewFromDevice.multiply(deviceFromCalib);
    return intrinsic.multiply(viewFromCalib);
  }

  _SourceCanvasPlacement _sourceToCanvasPlacementProjected({
    required Size source,
    required Size canvas,
  }) {
    final wideCam = cameraKind == _DriveCameraKind.wideRoad;
    final intrinsic = _intrinsicForSource(source, wideCam);
    final calibTransform = _calibTransformForSource(source);
    return _sourceToCanvasPlacement(
      source: source,
      canvas: canvas,
      intrinsic: intrinsic,
      calibTransform: calibTransform,
    );
  }

  Color _pathColorFromIndex(int idx) {
    final n = idx % 10;
    switch (n) {
      case 0:
        return const Color(0xFFFF0000);
      case 1:
        return const Color(0xFFFF9900);
      case 2:
        return const Color(0xFFDACA25);
      case 3:
        return const Color(0xFF00CB00);
      case 4:
        return const Color(0xFF0000FF);
      case 5:
        return const Color(0xFF000080);
      case 6:
        return const Color(0xFF8B00FF);
      case 7:
        return const Color(0xFFDA6F25);
      case 8:
        return const Color(0xFFFFFFFF);
      case 9:
      default:
        return const Color(0xFF000000);
    }
  }

  double _pathHalfWidthByMode(int mode, double ratio) {
    return ratio;
  }

  double _clampDouble(double v, double min, double max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  Color _roadEdgeColor(double std) {
    final t = _clampDouble(std / 2.0, 0.0, 1.0);
    final r = _clampDouble((1.0 - t) * 255.0, 0.0, 255.0).round();
    final b = _clampDouble(t * 255.0, 0.0, 255.0).round();
    return Color.fromARGB(255, r, 0, b);
  }

  Size get _effectiveSourceSize {
    if (sourceSize.width > 1 && sourceSize.height > 1) {
      final dw = (sourceSize.width - _baseSourceWidth).abs();
      final dh = (sourceSize.height - _baseSourceHeight).abs();
      // Some decoders report 1936x1216 while the projection intrinsics are
      // calibrated for 1928x1208. Snap near-by metadata to the canonical size.
      if (dw <= 16.0 && dh <= 16.0) {
        return const Size(_baseSourceWidth, _baseSourceHeight);
      }
      return sourceSize;
    }
    return const Size(_baseSourceWidth, _baseSourceHeight);
  }

  // -------------------------------------------------------------------------
  // Projection/Mapping invariants (MUST NOT change in adaptive UI refactors)
  //
  // This block is the source-of-truth for camera->overlay geometric alignment.
  // Keep these equations and transform order stable unless doing explicit
  // projection-engine work with field validation:
  // - _sourceToCanvasPlacement
  // - _sourceToCanvasPlacementFromDisplayTransform
  // - _buildTransform
  // - _mapToScreen
  //
  // Adaptive/responsive changes must be limited to surrounding UI shells
  // (dock/panel/popup/safe-area spacing), not these math paths.
  // -------------------------------------------------------------------------
  _SourceCanvasPlacement _sourceToCanvasPlacement({
    required Size source,
    required Size canvas,
    required _M3 intrinsic,
    required _M3 calibTransform,
  }) {
    final sx = canvas.width / source.width;
    final sy = canvas.height / source.height;
    final scale = coverViewport ? math.max(sx, sy) : math.min(sx, sy);
    final drawW = source.width * scale;
    final drawH = source.height * scale;
    var dx = (canvas.width - drawW) * 0.5;
    var dy = (canvas.height - drawH) * 0.5;
    var xOffset = 0.0;
    var yOffset = 0.0;

    // openpilot annotated_camera::calcFrameMatrix style:
    // use the projected point at "infinity" to compute x/y screen offset.
    final inf = calibTransform.transform(const _V3(1000.0, 0.0, 0.0));
    if (inf.z.isFinite && inf.z.abs() > 1e-6) {
      final centerX = intrinsic.m02;
      final centerY = intrinsic.m12;
      final maxXOffset =
          math.max(0.0, centerX * scale - canvas.width * 0.5 - 5.0);
      final maxYOffset =
          math.max(0.0, centerY * scale - canvas.height * 0.5 - 5.0);
      xOffset = _clampDouble(
        ((inf.x / inf.z) - centerX) * scale,
        -maxXOffset,
        maxXOffset,
      );
      yOffset = _clampDouble(
        ((inf.y / inf.z) - centerY) * scale,
        -maxYOffset,
        maxYOffset,
      );
      dx = (canvas.width * 0.5 - xOffset) - (centerX * scale);
      dy = (canvas.height * 0.5 - yOffset) - (centerY * scale);
    }

    return _SourceCanvasPlacement(
      transform: _M3(
        scale,
        0.0,
        dx,
        0.0,
        scale,
        dy,
        0.0,
        0.0,
        1.0,
      ),
      scale: scale,
      xOffset: xOffset,
      yOffset: yOffset,
    );
  }

  _SourceCanvasPlacement _sourceToCanvasPlacementFromDisplayTransform({
    required Size source,
    required Size canvas,
    required Map<String, dynamic>? displayTransform,
  }) {
    final sx = canvas.width / source.width;
    final sy = canvas.height / source.height;
    final fitScale = coverViewport ? math.max(sx, sy) : math.min(sx, sy);
    final baseDrawW = source.width * fitScale;
    final baseDrawH = source.height * fitScale;
    final baseDx = (canvas.width - baseDrawW) * 0.5;
    final baseDy = (canvas.height - baseDrawH) * 0.5;

    final zoomRaw = displayTransform == null
        ? null
        : _DriveOverlaySnapshot._asDouble(displayTransform['zoom']);
    final txRaw = displayTransform == null
        ? null
        : _DriveOverlaySnapshot._asDouble(displayTransform['tx']);
    final tyRaw = displayTransform == null
        ? null
        : _DriveOverlaySnapshot._asDouble(displayTransform['ty']);
    final xOffsetRaw = displayTransform == null
        ? null
        : _DriveOverlaySnapshot._asDouble(displayTransform['xOffset']);
    final yOffsetRaw = displayTransform == null
        ? null
        : _DriveOverlaySnapshot._asDouble(displayTransform['yOffset']);

    final zoom =
        (zoomRaw != null && zoomRaw.isFinite && zoomRaw > 0.1) ? zoomRaw : 1.0;
    final tx = (txRaw != null && txRaw.isFinite)
        ? txRaw
        : ((source.width - (source.width * zoom)) * 0.5);
    final ty = (tyRaw != null && tyRaw.isFinite)
        ? tyRaw
        : ((source.height - (source.height * zoom)) * 0.5);

    return _SourceCanvasPlacement(
      transform: _M3(
        fitScale * zoom,
        0.0,
        (fitScale * tx) + baseDx,
        0.0,
        fitScale * zoom,
        (fitScale * ty) + baseDy,
        0.0,
        0.0,
        1.0,
      ),
      scale: fitScale * zoom,
      xOffset: (xOffsetRaw != null && xOffsetRaw.isFinite) ? xOffsetRaw : 0.0,
      yOffset: (yOffsetRaw != null && yOffsetRaw.isFinite) ? yOffsetRaw : 0.0,
    );
  }

  _ProjectionTransform _buildTransform(Size size) {
    final src = _effectiveSourceSize;
    final calibTransform = _calibTransformForSource(src);
    final placement = _sourceToCanvasPlacementProjected(
      source: src,
      canvas: size,
    );
    final sourceToCanvas = placement.transform;
    // Keep projection math aligned with openpilot-style transform pipeline:
    // canvas <- source fit <- intrinsics/extrinsics calibrated projection.
    final carSpaceTransform = sourceToCanvas.multiply(calibTransform);
    final clip = Rect.fromLTWH(
      -_clipMargin,
      -_clipMargin,
      size.width + (_clipMargin * 2.0),
      size.height + (_clipMargin * 2.0),
    );
    return _ProjectionTransform(
      carSpaceTransform: carSpaceTransform,
      clip: clip,
      sourceScale: placement.scale,
      xOffset: placement.xOffset,
      yOffset: placement.yOffset,
    );
  }

  bool _mapToScreen(
    _ProjectionTransform transform,
    double inX,
    double inY,
    double inZ,
    void Function(Offset) onPoint,
  ) {
    final p = transform.carSpaceTransform.transform(_V3(inX, inY, inZ));
    if (!p.z.isFinite || p.z <= 1e-3) return false;
    final out = Offset(p.x / p.z, p.y / p.z);
    if (!transform.clip.contains(out)) return false;
    onPoint(out);
    return true;
  }

  int _getPathLengthIdx(List<double> lineX, double pathHeight) {
    var maxIdx = 0;
    for (var i = 1; i < lineX.length && lineX[i] <= pathHeight; i++) {
      maxIdx = i;
    }
    return maxIdx;
  }

  double _interp1D(double x, List<double> xp, List<double> fp) {
    if (xp.isEmpty || fp.isEmpty) return 0.0;
    final n = math.min(xp.length, fp.length);
    if (n <= 1) return fp.first;
    if (x <= xp.first) return fp.first;
    if (x >= xp[n - 1]) return fp[n - 1];
    for (var i = 1; i < n; i++) {
      final x0 = xp[i - 1];
      final x1 = xp[i];
      if (x <= x1) {
        final span = x1 - x0;
        if (span.abs() < 1e-9) return fp[i];
        final t = (x - x0) / span;
        return fp[i - 1] + (fp[i] - fp[i - 1]) * t;
      }
    }
    return fp[n - 1];
  }

  List<double> _monotonicX(List<double> src) {
    if (src.isEmpty) return const <double>[];
    final out = List<double>.filled(src.length, 0.0, growable: false);
    var prev = src.first;
    out[0] = prev;
    for (var i = 1; i < src.length; i++) {
      final v = src[i];
      if (v < prev) {
        out[i] = prev;
      } else {
        out[i] = v;
        prev = v;
      }
    }
    return out;
  }

  List<Offset>? _mapLineToPolygonVertices(
    _ProjectionTransform transform,
    _XyzSeries line,
    double yOff,
    double zOff,
    int maxIdx, {
    bool allowInvert = true,
    double lineCenterShift = 0.0,
  }) {
    if (line.length < 2) return null;
    final left = <Offset>[];
    final right = <Offset>[];
    final end = math.min(maxIdx, line.length - 1);
    for (var i = 0; i <= end; i++) {
      final lx = line.x[i];
      if (!lx.isFinite || lx < 0.0) continue;
      final ly = line.y[i] + lineCenterShift;
      final lz = line.z[i];
      Offset? lp;
      Offset? rp;
      final okL = _mapToScreen(
        transform,
        lx,
        ly - yOff,
        lz + zOff,
        (p) => lp = p,
      );
      final okR = _mapToScreen(
        transform,
        lx,
        ly + yOff,
        lz + zOff,
        (p) => rp = p,
      );
      if (!okL || !okR || lp == null || rp == null) continue;
      if (!allowInvert && left.isNotEmpty && lp!.dy > left.last.dy) {
        continue;
      }
      left.add(lp!);
      right.insert(0, rp!);
    }
    if (left.length < 2 || right.length < 2) return null;
    return <Offset>[...left, ...right];
  }

  Path? _mapLineToPolygon(
    _ProjectionTransform transform,
    _XyzSeries line,
    double yOff,
    double zOff,
    int maxIdx, {
    bool allowInvert = true,
    double lineCenterShift = 0.0,
  }) {
    final vertices = _mapLineToPolygonVertices(
      transform,
      line,
      yOff,
      zOff,
      maxIdx,
      allowInvert: allowInvert,
      lineCenterShift: lineCenterShift,
    );
    if (vertices == null || vertices.length < 3) return null;
    return _pathFromVertices(vertices);
  }

  List<Offset>? _mapLineToTrackVerticesDist(
    _ProjectionTransform transform,
    _XyzSeries line,
    double widthApply,
    double zOffStart,
    double zOffEnd,
    double maxDistance, {
    double startDistance = 2.0,
    bool allowInvert = true,
  }) {
    if (line.length < 2) return null;
    final n = line.length;
    final lineXs = _monotonicX(line.x.take(n).toList(growable: false));
    if (lineXs.isEmpty) return null;
    final lineYs = line.y.take(n).toList(growable: false);
    final lineZs = line.z.take(n).toList(growable: false);
    final idxs = List<double>.generate(n, (i) => i.toDouble(), growable: false);

    final left = <Offset>[];
    final right = <Offset>[];
    var dist = startDistance;
    var done = false;
    while (!done) {
      if (dist >= maxDistance) {
        dist = maxDistance;
        done = true;
      }
      final zOff = _interp1D(dist, const <double>[
        0.0,
        100.0
      ], <double>[
        zOffStart,
        zOffEnd,
      ]);
      final yScale = _interp1D(
        zOff,
        const <double>[-3.0, 0.0, 3.0],
        const <double>[1.5, 0.5, 1.5],
      );
      final yOff = yScale * widthApply;
      final idx = _interp1D(dist, lineXs, idxs);
      if (idx >= (n - 1)) break;
      final lineY = _interp1D(idx, idxs, lineYs);
      final lineZ = _interp1D(idx, idxs, lineZs);

      Offset? lp;
      Offset? rp;
      final okL = _mapToScreen(
        transform,
        dist,
        lineY - yOff,
        lineZ + zOff,
        (p) => lp = p,
      );
      final okR = _mapToScreen(
        transform,
        dist,
        lineY + yOff,
        lineZ + zOff,
        (p) => rp = p,
      );
      if (okL && okR && lp != null && rp != null) {
        if (!allowInvert && left.isNotEmpty && lp!.dy > left.last.dy) {
          dist += dist * 0.15;
          continue;
        }
        left.add(lp!);
        right.insert(0, rp!);
      }
      dist += dist * 0.15;
    }
    if (left.length < 2 || right.length < 2) return null;
    return <Offset>[...left, ...right];
  }

  Path _pathFromVertices(List<Offset> vertices) {
    final path = Path()..moveTo(vertices.first.dx, vertices.first.dy);
    for (var i = 1; i < vertices.length; i++) {
      path.lineTo(vertices[i].dx, vertices[i].dy);
    }
    path.close();
    return path;
  }

  void _drawTrackPolygon(
    Canvas canvas,
    List<Offset> vertices,
    Color fillColor, {
    required bool strokeEnabled,
    required Color strokeColor,
  }) {
    if (vertices.length < 3) return;
    final path = _pathFromVertices(vertices);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = fillColor.withValues(alpha: 0.42),
    );
    if (strokeEnabled) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = strokeColor,
      );
    }
  }

  void _drawSpecialModes(
    Canvas canvas,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    final glen = (trackLen ~/ 2) - 1;
    if (glen < 2) return;
    var g = 0.05;
    var gc = 0.4;
    if (mode == 13) {
      g = 0.2;
      gc = 0.10;
    } else if (mode == 14) {
      g = 0.45;
      gc = 0.05;
    } else if (mode == 15) {
      gc = g;
    }

    final strip0 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    final strip1 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    final strip2 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    for (var i = 0; i < glen; i++) {
      final e = trackLen - i - 1;
      final ge = (glen * 2) - 1 - i;
      final p1 = trackVertices[i];
      final p2 = trackVertices[e];
      strip0[i] = p1;
      strip0[ge] = Offset(
        p1.dx + (p2.dx - p1.dx) * g,
        p1.dy + (p2.dy - p1.dy) * g,
      );
      strip1[i] = Offset(
        p1.dx + (p2.dx - p1.dx) * (0.5 - gc),
        p1.dy + (p2.dy - p1.dy) * (0.5 - gc),
      );
      strip1[ge] = Offset(
        p1.dx + (p2.dx - p1.dx) * (0.5 + gc),
        p1.dy + (p2.dy - p1.dy) * (0.5 + gc),
      );
      strip2[i] = Offset(
        p1.dx + (p2.dx - p1.dx) * (1.0 - g),
        p1.dy + (p2.dy - p1.dy) * (1.0 - g),
      );
      strip2[ge] = p2;
    }

    final baseColor = _pathColorFromIndex(colorIdx);
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    if (mode == 13 || mode == 14) {
      _drawTrackPolygon(
        canvas,
        strip0,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
    if (mode == 13 || mode == 15) {
      _drawTrackPolygon(
        canvas,
        strip1,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
    if (mode == 13 || mode == 14) {
      _drawTrackPolygon(
        canvas,
        strip2,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
  }

  void _drawComplexPath(
    Canvas canvas,
    List<Offset> trackVertices,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 5) return;
    final baseColor = _pathColorFromIndex(colorIdx);
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    for (var i = 0; i < half - 1; i += 3) {
      final e = trackLen - i - 1;
      if (i + 2 >= half || e - 2 < 0) break;
      final p0 = trackVertices[i];
      final p1 = trackVertices[i + 1];
      final p2l = trackVertices[i + 2];
      final p2r = trackVertices[e - 2];
      final p3 = trackVertices[e - 1];
      final p4 = trackVertices[e];
      final p2 = Offset((p2l.dx + p2r.dx) * 0.5, (p2l.dy + p2r.dy) * 0.5);
      final p5 = Offset((p1.dx + p3.dx) * 0.5, (p1.dy + p3.dy) * 0.5);
      _drawTrackPolygon(
        canvas,
        <Offset>[p0, p1, p2, p3, p4, p5],
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
  }

  void _drawMode1To6(
    Canvas canvas,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
    int pathDrawSeq,
    int pathDrawSeq2,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 5) return;
    var colorN = 0;
    for (var i = 0; i < half - 4; i += 2) {
      final draw = (half < 8 ||
          mode == 5 ||
          mode == 6 ||
          pathDrawSeq == i ~/ 2 ||
          pathDrawSeq == (i ~/ 2) - 2 ||
          pathDrawSeq2 == i ~/ 2 ||
          pathDrawSeq2 == (i ~/ 2) - 2);
      if (!draw) {
        if (i > 1) colorN = (colorN + 1) % 7;
        continue;
      }
      final idx = (mode == 2 || mode == 6) ? colorN : (colorIdx % 10);
      final fill = _pathColorFromIndex(idx);
      final strokeEnabled = colorIdx >= 10 || brakeLights;
      final strokeColor =
          brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
      _drawTrackPolygon(
        canvas,
        <Offset>[
          trackVertices[i],
          trackVertices[i + 2],
          trackVertices[trackLen - i - 3],
          trackVertices[trackLen - i - 1],
        ],
        fill,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      if (i > 1) colorN = (colorN + 1) % 7;
    }
  }

  void _drawMode3To8(
    Canvas canvas,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
    int pathDrawSeq,
    int pathDrawSeq2,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 6) return;
    var colorN = 0;
    for (var i = 0; i < half - 4; i += 2) {
      if (i + 4 >= half || trackLen - i - 5 < 0) break;
      final draw = (half < 8 ||
          mode == 7 ||
          mode == 8 ||
          pathDrawSeq == i ~/ 2 ||
          pathDrawSeq == (i ~/ 2) - 2 ||
          pathDrawSeq2 == i ~/ 2 ||
          pathDrawSeq2 == (i ~/ 2) - 2);
      if (!draw) {
        if (i > 1) colorN = (colorN + 1) % 7;
        continue;
      }
      final idx = (mode == 4 || mode == 8) ? colorN : (colorIdx % 10);
      final fill = _pathColorFromIndex(idx);
      final strokeEnabled = colorIdx >= 10 || brakeLights;
      final strokeColor =
          brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);

      final p1 = trackVertices[i + 2];
      final p3 = trackVertices[trackLen - i - 3];
      _drawTrackPolygon(
        canvas,
        <Offset>[
          trackVertices[i],
          p1,
          Offset(
            (trackVertices[i + 4].dx + trackVertices[trackLen - i - 5].dx) *
                0.5,
            (trackVertices[i + 4].dy + trackVertices[trackLen - i - 5].dy) *
                0.5,
          ),
          p3,
          trackVertices[trackLen - i - 1],
          Offset((p1.dx + p3.dx) * 0.5, (p1.dy + p3.dy) * 0.5),
        ],
        fill,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      if (i > 1) colorN = (colorN + 1) % 7;
    }
  }

  void _drawAnimatedPath(
    Canvas canvas,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    if (trackLen < 8) return;
    final maxSeq = math.min((trackLen ~/ 4) + 3, 16);
    if (maxSeq <= 0) return;
    final phase = snapshot.animationPhase;
    var normalized = phase % maxSeq;
    if (normalized < 0) normalized += maxSeq;
    final seqInt = normalized.floor();
    final pathDrawSeq2 =
        (maxSeq > 15) ? ((seqInt - (maxSeq ~/ 2) + maxSeq) % maxSeq) : -5;
    switch (mode) {
      case 1:
      case 2:
      case 5:
      case 6:
        _drawMode1To6(
          canvas,
          trackVertices,
          mode,
          colorIdx,
          brakeLights,
          seqInt,
          pathDrawSeq2,
        );
        break;
      case 3:
      case 4:
      case 7:
      case 8:
        _drawMode3To8(
          canvas,
          trackVertices,
          mode,
          colorIdx,
          brakeLights,
          seqInt,
          pathDrawSeq2,
        );
        break;
      default:
        _drawComplexPath(canvas, trackVertices, colorIdx, brakeLights);
        break;
    }
  }

  void _drawPathByMode(
    Canvas canvas,
    List<Offset> trackVertices,
  ) {
    final mode = snapshot.pathMode;
    final colorIdx = snapshot.pathColor;
    final brakeLights = snapshot.brakeLights;
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    final fillColor = _pathColorFromIndex(colorIdx);
    if (mode == 0) {
      _drawTrackPolygon(
        canvas,
        trackVertices,
        fillColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      return;
    }
    if (mode >= 13 && mode <= 15) {
      _drawSpecialModes(canvas, trackVertices, mode, colorIdx, brakeLights);
      return;
    }
    if (mode >= 9) {
      _drawComplexPath(canvas, trackVertices, colorIdx, brakeLights);
      return;
    }
    _drawAnimatedPath(canvas, trackVertices, mode, colorIdx, brakeLights);
  }

  static Map<String, dynamic>? buildNativeOverlayPayload({
    required _DriveOverlaySnapshot snapshot,
    required Size sourceSize,
    required _DriveCameraKind cameraKind,
    required Size canvasSize,
    required bool coverViewport,
    bool showDebugGuides = false,
    bool showPathFill = true,
    bool showLaneLines = true,
    bool showRoadEdge = true,
    bool showLead1 = true,
    bool showLead2 = true,
    bool showRadarBadge = true,
    bool showRadarVector = true,
    bool showStopDistanceTf = true,
    bool showStateText = true,
  }) {
    final painter = _DriveOverlayPainter(
      snapshot: snapshot,
      isConnected: true,
      sourceSize: sourceSize,
      cameraKind: cameraKind,
      coverViewport: coverViewport,
      showDebugGuides: showDebugGuides,
      showPathFill: showPathFill,
      showLaneLines: showLaneLines,
      showRoadEdge: showRoadEdge,
      showLead1: showLead1,
      showLead2: showLead2,
      showRadarBadge: showRadarBadge,
      showRadarVector: showRadarVector,
      showStopDistanceTf: showStopDistanceTf,
      showStateText: showStateText,
    );
    return painter._buildNativeOverlayPayload(canvasSize);
  }

  static String buildProjectionDebugText({
    required _DriveOverlaySnapshot snapshot,
    required Size sourceSize,
    required _DriveCameraKind cameraKind,
    required Size canvasSize,
    required bool coverViewport,
    required String cameraSourceLabel,
  }) {
    final painter = _DriveOverlayPainter(
      snapshot: snapshot,
      isConnected: true,
      sourceSize: sourceSize,
      cameraKind: cameraKind,
      coverViewport: coverViewport,
    );
    return painter._buildProjectionDebugText(
      canvasSize: canvasSize,
      cameraSourceLabel: cameraSourceLabel,
    );
  }

  String _buildProjectionDebugText({
    required Size canvasSize,
    required String cameraSourceLabel,
  }) {
    final src = _effectiveSourceSize;
    final transform = _buildTransform(canvasSize);
    final cameraFrameId = cameraKind == _DriveCameraKind.wideRoad
        ? (snapshot.wideRoadFrameId ?? snapshot.roadFrameId)
        : snapshot.roadFrameId;
    final modelFrameId = snapshot.modelFrameId;
    final gap = (cameraFrameId != null && modelFrameId != null)
        ? (modelFrameId - cameraFrameId).abs()
        : null;

    final sampleLines = <String>[];
    final refLines = <String>[];
    final line = snapshot.path;
    if (line.length >= 2) {
      final n = line.length;
      final xs = _monotonicX(line.x.take(n).toList(growable: false));
      final ys = line.y.take(n).toList(growable: false);
      final zs = line.z.take(n).toList(growable: false);
      if (xs.isNotEmpty && ys.isNotEmpty && zs.isNotEmpty) {
        final idxs =
            List<double>.generate(n, (i) => i.toDouble(), growable: false);
        for (final d in const <double>[5, 10, 20, 30, 40, 60]) {
          if (d > xs.last) continue;
          final idx = _interp1D(d, xs, idxs);
          if (idx >= (n - 1)) continue;
          final y = _interp1D(idx, idxs, ys);
          final z = _interp1D(idx, idxs, zs);
          Offset? p;
          final ok = _mapToScreen(
            transform,
            d,
            y,
            z + (snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22),
            (pt) => p = pt,
          );
          if (!ok || p == null) {
            sampleLines.add('${d.toStringAsFixed(0)}m: out');
          } else {
            sampleLines.add(
              '${d.toStringAsFixed(0)}m: (${p!.dx.toStringAsFixed(1)}, ${p!.dy.toStringAsFixed(1)})',
            );
          }
        }
      }
    }

    final refZ = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
    for (final d in const <double>[5, 10, 20]) {
      Offset? p;
      final ok = _mapToScreen(transform, d, 0.0, refZ, (pt) => p = pt);
      if (!ok || p == null) {
        refLines.add('${d.toStringAsFixed(0)}m: out');
      } else {
        refLines.add(
          '${d.toStringAsFixed(0)}m: (${p!.dx.toStringAsFixed(1)}, ${p!.dy.toStringAsFixed(1)})',
        );
      }
    }

    final rpy = snapshot.calibrationRpy;
    final rpyText = rpy.length >= 3
        ? '${rpy[0].toStringAsFixed(3)}, ${rpy[1].toStringAsFixed(3)}, ${rpy[2].toStringAsFixed(3)}'
        : 'n/a';
    final wideEuler = snapshot.wideFromDeviceEuler;
    final wideText = wideEuler.length >= 3
        ? '${wideEuler[0].toStringAsFixed(3)}, ${wideEuler[1].toStringAsFixed(3)}, ${wideEuler[2].toStringAsFixed(3)}'
        : 'n/a';

    final sampleText = sampleLines.isEmpty
        ? 'samples: n/a'
        : 'samples: ${sampleLines.join(' | ')}';
    final refText = refLines.isEmpty
        ? 'center ref: n/a'
        : 'center ref: ${refLines.join(' | ')}';
    final gapText = gap == null ? 'n/a' : '$gap';
    final placementText =
        'video shift x=${transform.xOffset.toStringAsFixed(1)} y=${transform.yOffset.toStringAsFixed(1)} scale=${transform.sourceScale.toStringAsFixed(3)}';
    final frameText =
        'frame model=${modelFrameId ?? '-'} cam=${cameraFrameId ?? '-'} gap=$gapText';
    final modeText =
        'path mode=${snapshot.pathMode} color=${snapshot.pathColor} width=${snapshot.pathWidthRatio.toStringAsFixed(2)} '
        'active=${snapshot.active ? 1 : 0} lane=${snapshot.activeLaneLine ? 1 : 0}';
    final pathSourceText =
        'path src=${snapshot.usingLateralPath ? 'lateral' : 'model'} '
        'len=${snapshot.path.length} '
        'modelX=${snapshot.modelPathXMax.toStringAsFixed(1)} '
        'lateralX=${snapshot.lateralPathXMax.toStringAsFixed(1)}';
    final sourceText =
        'src ${src.width.toStringAsFixed(0)}x${src.height.toStringAsFixed(0)} '
        'canvas ${canvasSize.width.toStringAsFixed(0)}x${canvasSize.height.toStringAsFixed(0)} '
        'fit=${coverViewport ? 'cover' : 'contain'} cam=${cameraKind.name} $cameraSourceLabel';

    return <String>[
      '[Projection Verify]',
      sourceText,
      frameText,
      modeText,
      pathSourceText,
      'calib rpy: $rpyText',
      'wide euler: $wideText',
      placementText,
      sampleText,
      refText,
    ].join('\n');
  }

  List<Offset> _decodeOverlayPoints(dynamic raw) {
    if (raw is List) {
      if (raw.length >= 2 && raw.first is List) {
        final out = <Offset>[];
        for (final item in raw) {
          if (item is! List || item.length < 2) continue;
          final dx = _DriveOverlaySnapshot._asDouble(item[0]);
          final dy = _DriveOverlaySnapshot._asDouble(item[1]);
          if (dx == null || dy == null) continue;
          out.add(Offset(dx, dy));
        }
        return out;
      }
      if (raw.length >= 6) {
        final out = <Offset>[];
        for (var i = 0; i + 1 < raw.length; i += 2) {
          final dx = _DriveOverlaySnapshot._asDouble(raw[i]);
          final dy = _DriveOverlaySnapshot._asDouble(raw[i + 1]);
          if (dx == null || dy == null) continue;
          out.add(Offset(dx, dy));
        }
        return out;
      }
    }
    return const <Offset>[];
  }

  List<Offset> _mapSourcePointsToCanvas(
    List<Offset> sourcePoints, {
    required Size canvasSize,
    required double sourceWidth,
    required double sourceHeight,
    Map<String, dynamic>? displayTransform,
  }) {
    if (sourcePoints.isEmpty) return const <Offset>[];
    final srcW = (sourceWidth > 1.0) ? sourceWidth : _baseSourceWidth;
    final srcH = (sourceHeight > 1.0) ? sourceHeight : _baseSourceHeight;
    final source = Size(srcW, srcH);
    // Invariant: sidecar points are already projected in source pixel space.
    // Only apply the same display transform used by the camera layer.
    // Do not insert extra projection/normalization here for UI-only changes.
    final placement = _sourceToCanvasPlacementFromDisplayTransform(
      source: source,
      canvas: canvasSize,
      displayTransform: displayTransform,
    );
    final out = <Offset>[];
    for (final p in sourcePoints) {
      final mapped = placement.transform.transform(_V3(p.dx, p.dy, 1.0));
      if (!mapped.x.isFinite || !mapped.y.isFinite) continue;
      out.add(Offset(mapped.x, mapped.y));
    }
    return out;
  }

  Map<String, dynamic>? _currentCameraOverlay2d() {
    final root = snapshot.sidecarOverlay2d;
    if (root == null) return null;
    final cameras = root['cameras'];
    if (cameras is! Map) return null;
    final key = cameraKind == _DriveCameraKind.wideRoad ? 'wideRoad' : 'road';
    final selected = cameras[key];
    if (selected is! Map) return null;
    return Map<String, dynamic>.from(selected);
  }

  Map<String, dynamic>? _buildNativeOverlayPayloadFromSidecar2d(Size size) {
    final cam = _currentCameraOverlay2d();
    if (cam == null) return null;
    final transform = _buildTransform(size);
    final sourceWidth =
        _DriveOverlaySnapshot._asDouble(cam['sourceWidth']) ?? _baseSourceWidth;
    final sourceHeight = _DriveOverlaySnapshot._asDouble(cam['sourceHeight']) ??
        _baseSourceHeight;
    final displayTransformRaw = cam['displayTransform'];
    final displayTransform = displayTransformRaw is Map
        ? Map<String, dynamic>.from(displayTransformRaw)
        : null;
    var sidecarPathMode =
        _DriveOverlaySnapshot._asInt(cam['pathMode']) ?? snapshot.pathMode;
    var sidecarPathColor =
        _DriveOverlaySnapshot._asInt(cam['pathColor']) ?? snapshot.pathColor;
    // Enforce classic visual style on sidecar-provided payload as well.
    if (sidecarPathMode >= 13 && sidecarPathMode <= 15) {
      sidecarPathMode = 0;
    }
    if (sidecarPathColor == 14 || sidecarPathColor == 19) {
      sidecarPathColor = 3;
    }
    var sidecarBrakeLights = snapshot.brakeLights;
    final meta = cam['meta'];
    if (meta is Map) {
      final brakeRaw = meta['brakeLights'];
      if (brakeRaw is bool) {
        sidecarBrakeLights = brakeRaw;
      } else if (brakeRaw is num) {
        sidecarBrakeLights = brakeRaw != 0;
      } else if (brakeRaw is String) {
        final lower = brakeRaw.trim().toLowerCase();
        if (lower == '1' || lower == 'true' || lower == 'yes') {
          sidecarBrakeLights = true;
        } else if (lower == '0' || lower == 'false' || lower == 'no') {
          sidecarBrakeLights = false;
        }
      }
    }
    final polygons = <Map<String, dynamic>>[];
    final labels = <Map<String, dynamic>>[];

    final laneRaw = cam['lanePolygons'];
    if (showLaneLines && laneRaw is List) {
      for (final item in laneRaw) {
        if (item is! Map) continue;
        final points = _mapSourcePointsToCanvas(
          _decodeOverlayPoints(item['points']),
          canvasSize: size,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          displayTransform: displayTransform,
        );
        if (points.length < 3) continue;
        final probability =
            (_DriveOverlaySnapshot._asDouble(item['probability']) ?? 0.0)
                .clamp(0.0, 1.0);
        if (probability <= 0.3) continue;
        final laneIndex = _DriveOverlaySnapshot._asInt(item['index']) ?? -1;
        Color laneColor = Colors.white;
        if (laneIndex == 1 && snapshot.leftLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        } else if (laneIndex == 2 && snapshot.rightLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        }
        polygons.add(
          _encodePolygon(
            points,
            laneColor.withValues(alpha: 220.0 / 255.0),
          ),
        );
      }
    }

    final edgeRaw = cam['roadEdgePolygons'];
    if (showRoadEdge && edgeRaw is List) {
      for (final item in edgeRaw) {
        if (item is! Map) continue;
        final points = _mapSourcePointsToCanvas(
          _decodeOverlayPoints(item['points']),
          canvasSize: size,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          displayTransform: displayTransform,
        );
        if (points.length < 3) continue;
        final std = _DriveOverlaySnapshot._asDouble(item['std']) ?? 1.0;
        polygons.add(_encodePolygon(points, _roadEdgeColor(std)));
      }
    }

    var trackVertices = _mapSourcePointsToCanvas(
      _decodeOverlayPoints(cam['pathTrackVertices']),
      canvasSize: size,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      displayTransform: displayTransform,
    );
    if (trackVertices.length < 3 && snapshot.path.length >= 2) {
      final modelMax = snapshot.path.x.isNotEmpty ? snapshot.path.x.last : 0.0;
      final maxDistance = modelMax.clamp(10.0, 100.0);
      final widthApply = _pathHalfWidthByMode(
        sidecarPathMode,
        snapshot.pathWidthRatio,
      );
      final zOff = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
      final fallbackTrack = _mapLineToTrackVerticesDist(
        transform,
        snapshot.path,
        widthApply,
        zOff,
        zOff,
        maxDistance,
        startDistance: snapshot.active ? 2.0 : 3.5,
        allowInvert: false,
      );
      if (fallbackTrack != null && fallbackTrack.length >= 3) {
        trackVertices = fallbackTrack;
      }
    }
    if (showPathFill && trackVertices.length >= 3) {
      _collectPathPolygonsByMode(
        polygons,
        trackVertices,
        sidecarPathMode,
        sidecarPathColor,
        sidecarBrakeLights,
      );
    }

    _appendSidecarLeadAndRadarPolygons(
      cam: cam,
      canvasSize: size,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      displayTransform: displayTransform,
      polygons: polygons,
      labels: labels,
      showLead1: showLead1,
      showLead2: showLead2,
      showRadarBadge: showRadarBadge,
      showRadarVector: showRadarVector,
      showStopDistanceTf: showStopDistanceTf,
      showStateText: showStateText,
    );
    _appendNavArOverlayPolygons(
      polygons: polygons,
      labels: labels,
      transform: transform,
      canvasSize: size,
    );

    if (showDebugGuides) {
      _appendDebugScreenGridPolygons(
        polygons,
        canvasSize: size,
      );
      labels.addAll(_buildDebugGridLabels(canvasSize: size));
    }

    if (polygons.isEmpty && labels.isEmpty) return null;
    return <String, dynamic>{
      'version': 3,
      'canvasWidth': size.width,
      'canvasHeight': size.height,
      'sourceWidth': sourceWidth,
      'sourceHeight': sourceHeight,
      'polygons': polygons,
      if (labels.isNotEmpty) 'labels': labels,
    };
  }

  Map<String, dynamic>? _buildNativeOverlayPayload(Size size) {
    final sidecarPayload = _buildNativeOverlayPayloadFromSidecar2d(size);
    if (sidecarPayload != null) return sidecarPayload;
    if (snapshot.path.length < 2) return null;

    final transform = _buildTransform(size);
    final modelMax = snapshot.path.x.isNotEmpty ? snapshot.path.x.last : 0.0;
    final maxDistance = modelMax.clamp(10.0, 100.0);
    final laneBaseX = snapshot.laneLines.isNotEmpty
        ? snapshot.laneLines.first.line.x
        : snapshot.path.x;
    final laneMaxIdx = laneBaseX.isNotEmpty
        ? _getPathLengthIdx(laneBaseX, maxDistance)
        : _getPathLengthIdx(snapshot.path.x, maxDistance);

    final polygons = <Map<String, dynamic>>[];
    List<Map<String, dynamic>>? labels;

    if (showLaneLines) {
      for (var i = 0; i < snapshot.laneLines.length; i++) {
        final ln = snapshot.laneLines[i];
        var lineWidth = 0.025;
        if (i == 1 && snapshot.leftLaneLine >= 20) {
          lineWidth = 0.05;
        }
        final poly = _mapLineToPolygonVertices(
          transform,
          ln.line,
          lineWidth,
          0.0,
          laneMaxIdx,
        );
        if (poly == null) continue;
        final alpha = ln.probability > 0.3 ? (220.0 / 255.0) : 0.0;
        if (alpha <= 0.0) continue;
        Color laneColor = Colors.white;
        if (i == 1 && snapshot.leftLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        } else if (i == 2 && snapshot.rightLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        }
        polygons.add(_encodePolygon(
          poly,
          laneColor.withValues(alpha: alpha),
        ));
        if (i == 1 && (snapshot.leftLaneLine % 10) == 4) {
          final doublePoly = _mapLineToPolygonVertices(
            transform,
            ln.line,
            lineWidth,
            0.0,
            laneMaxIdx,
            lineCenterShift: -0.3,
          );
          if (doublePoly != null) {
            polygons.add(_encodePolygon(
              doublePoly,
              laneColor.withValues(alpha: alpha),
            ));
          }
        }
      }
    }

    if (showRoadEdge) {
      for (final edge in snapshot.roadEdges) {
        final poly = _mapLineToPolygonVertices(
          transform,
          edge.line,
          0.025,
          0.0,
          laneMaxIdx,
        );
        if (poly == null) continue;
        polygons.add(_encodePolygon(poly, _roadEdgeColor(edge.std)));
      }
    }

    final pathMode = snapshot.pathMode;
    final widthApply = _pathHalfWidthByMode(pathMode, snapshot.pathWidthRatio);
    final zOff = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
    final startDistance = snapshot.active ? 2.0 : 3.5;
    final trackVertices = _mapLineToTrackVerticesDist(
      transform,
      snapshot.path,
      widthApply,
      zOff,
      zOff,
      maxDistance,
      startDistance: startDistance,
      allowInvert: false,
    );
    if (showPathFill && trackVertices != null && trackVertices.length >= 3) {
      final colorIdx = snapshot.pathColor;
      final brakeLights = snapshot.brakeLights;
      _collectPathPolygonsByMode(
        polygons,
        trackVertices,
        pathMode,
        colorIdx,
        brakeLights,
      );
    }
    labels ??= <Map<String, dynamic>>[];
    _appendNavArOverlayPolygons(
      polygons: polygons,
      labels: labels,
      transform: transform,
      canvasSize: size,
    );
    if (labels.isEmpty) labels = null;

    if (showDebugGuides) {
      _appendDebugGuidePolygons(
        polygons,
        canvasSize: size,
        transform: transform,
        trackVertices: trackVertices,
      );
      labels = _buildDebugGridLabels(canvasSize: size);
    }

    if (polygons.isEmpty && (labels == null || labels.isEmpty)) return null;
    final src = _effectiveSourceSize;
    return <String, dynamic>{
      'version': 2,
      'canvasWidth': size.width,
      'canvasHeight': size.height,
      'sourceWidth': src.width,
      'sourceHeight': src.height,
      'polygons': polygons,
      if (labels != null && labels.isNotEmpty) 'labels': labels,
    };
  }

  void _appendPathPolygon(
    List<Map<String, dynamic>> out,
    List<Offset> vertices,
    Color fillColor, {
    required bool strokeEnabled,
    required Color strokeColor,
  }) {
    if (vertices.length < 3) return;
    out.add(
      _encodePolygon(
        vertices,
        fillColor.withValues(alpha: 0.42),
        strokeColor: strokeEnabled ? strokeColor : null,
        strokeWidth: strokeEnabled ? 2.0 : 0.0,
      ),
    );
  }

  void _collectSpecialModePolygons(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    final glen = (trackLen ~/ 2) - 1;
    if (glen < 2) return;
    var g = 0.05;
    var gc = 0.4;
    if (mode == 13) {
      g = 0.2;
      gc = 0.10;
    } else if (mode == 14) {
      g = 0.45;
      gc = 0.05;
    } else if (mode == 15) {
      gc = g;
    }

    final strip0 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    final strip1 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    final strip2 = List<Offset>.filled(glen * 2, Offset.zero, growable: false);
    for (var i = 0; i < glen; i++) {
      final e = trackLen - i - 1;
      final ge = (glen * 2) - 1 - i;
      final p1 = trackVertices[i];
      final p2 = trackVertices[e];
      strip0[i] = p1;
      strip0[ge] = Offset(
        p1.dx + (p2.dx - p1.dx) * g,
        p1.dy + (p2.dy - p1.dy) * g,
      );
      strip1[i] = Offset(
        p1.dx + (p2.dx - p1.dx) * (0.5 - gc),
        p1.dy + (p2.dy - p1.dy) * (0.5 - gc),
      );
      strip1[ge] = Offset(
        p1.dx + (p2.dx - p1.dx) * (0.5 + gc),
        p1.dy + (p2.dy - p1.dy) * (0.5 + gc),
      );
      strip2[i] = Offset(
        p1.dx + (p2.dx - p1.dx) * (1.0 - g),
        p1.dy + (p2.dy - p1.dy) * (1.0 - g),
      );
      strip2[ge] = p2;
    }

    final baseColor = _pathColorFromIndex(colorIdx);
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    if (mode == 13 || mode == 14) {
      _appendPathPolygon(
        out,
        strip0,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
    if (mode == 13 || mode == 15) {
      _appendPathPolygon(
        out,
        strip1,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
    if (mode == 13 || mode == 14) {
      _appendPathPolygon(
        out,
        strip2,
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
  }

  void _collectComplexPathPolygons(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 5) return;
    final baseColor = _pathColorFromIndex(colorIdx);
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    for (var i = 0; i < half - 1; i += 3) {
      final e = trackLen - i - 1;
      if (i + 2 >= half || e - 2 < 0) break;
      final p0 = trackVertices[i];
      final p1 = trackVertices[i + 1];
      final p2l = trackVertices[i + 2];
      final p2r = trackVertices[e - 2];
      final p3 = trackVertices[e - 1];
      final p4 = trackVertices[e];
      final p2 = Offset((p2l.dx + p2r.dx) * 0.5, (p2l.dy + p2r.dy) * 0.5);
      final p5 = Offset((p1.dx + p3.dx) * 0.5, (p1.dy + p3.dy) * 0.5);
      _appendPathPolygon(
        out,
        <Offset>[p0, p1, p2, p3, p4, p5],
        baseColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
    }
  }

  void _collectMode1To6Polygons(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
    int pathDrawSeq,
    int pathDrawSeq2,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 5) return;
    var colorN = 0;
    for (var i = 0; i < half - 4; i += 2) {
      final draw = (half < 8 ||
          mode == 5 ||
          mode == 6 ||
          pathDrawSeq == i ~/ 2 ||
          pathDrawSeq == (i ~/ 2) - 2 ||
          pathDrawSeq2 == i ~/ 2 ||
          pathDrawSeq2 == (i ~/ 2) - 2);
      if (!draw) {
        if (i > 1) colorN = (colorN + 1) % 7;
        continue;
      }
      final idx = (mode == 2 || mode == 6) ? colorN : (colorIdx % 10);
      final fill = _pathColorFromIndex(idx);
      final strokeEnabled = colorIdx >= 10 || brakeLights;
      final strokeColor =
          brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
      _appendPathPolygon(
        out,
        <Offset>[
          trackVertices[i],
          trackVertices[i + 2],
          trackVertices[trackLen - i - 3],
          trackVertices[trackLen - i - 1],
        ],
        fill,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      if (i > 1) colorN = (colorN + 1) % 7;
    }
  }

  void _collectMode3To8Polygons(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
    int pathDrawSeq,
    int pathDrawSeq2,
  ) {
    final trackLen = trackVertices.length;
    final half = trackLen ~/ 2;
    if (half < 6) return;
    var colorN = 0;
    for (var i = 0; i < half - 4; i += 2) {
      if (i + 4 >= half || trackLen - i - 5 < 0) break;
      final draw = (half < 8 ||
          mode == 7 ||
          mode == 8 ||
          pathDrawSeq == i ~/ 2 ||
          pathDrawSeq == (i ~/ 2) - 2 ||
          pathDrawSeq2 == i ~/ 2 ||
          pathDrawSeq2 == (i ~/ 2) - 2);
      if (!draw) {
        if (i > 1) colorN = (colorN + 1) % 7;
        continue;
      }
      final idx = (mode == 4 || mode == 8) ? colorN : (colorIdx % 10);
      final fill = _pathColorFromIndex(idx);
      final strokeEnabled = colorIdx >= 10 || brakeLights;
      final strokeColor =
          brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);

      final p1 = trackVertices[i + 2];
      final p3 = trackVertices[trackLen - i - 3];
      _appendPathPolygon(
        out,
        <Offset>[
          trackVertices[i],
          p1,
          Offset(
            (trackVertices[i + 4].dx + trackVertices[trackLen - i - 5].dx) *
                0.5,
            (trackVertices[i + 4].dy + trackVertices[trackLen - i - 5].dy) *
                0.5,
          ),
          p3,
          trackVertices[trackLen - i - 1],
          Offset((p1.dx + p3.dx) * 0.5, (p1.dy + p3.dy) * 0.5),
        ],
        fill,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      if (i > 1) colorN = (colorN + 1) % 7;
    }
  }

  void _collectAnimatedPathPolygons(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
  ) {
    final trackLen = trackVertices.length;
    if (trackLen < 8) return;
    final maxSeq = math.min((trackLen ~/ 4) + 3, 16);
    if (maxSeq <= 0) return;
    final phase = snapshot.animationPhase;
    var normalized = phase % maxSeq;
    if (normalized < 0) normalized += maxSeq;
    final seqInt = normalized.floor();
    final pathDrawSeq2 =
        (maxSeq > 15) ? ((seqInt - (maxSeq ~/ 2) + maxSeq) % maxSeq) : -5;
    switch (mode) {
      case 1:
      case 2:
      case 5:
      case 6:
        _collectMode1To6Polygons(
          out,
          trackVertices,
          mode,
          colorIdx,
          brakeLights,
          seqInt,
          pathDrawSeq2,
        );
        break;
      case 3:
      case 4:
      case 7:
      case 8:
        _collectMode3To8Polygons(
          out,
          trackVertices,
          mode,
          colorIdx,
          brakeLights,
          seqInt,
          pathDrawSeq2,
        );
        break;
      default:
        _collectComplexPathPolygons(out, trackVertices, colorIdx, brakeLights);
        break;
    }
  }

  void _collectPathPolygonsByMode(
    List<Map<String, dynamic>> out,
    List<Offset> trackVertices,
    int mode,
    int colorIdx,
    bool brakeLights,
  ) {
    final strokeEnabled = colorIdx >= 10 || brakeLights;
    final strokeColor =
        brakeLights ? const Color(0xFFFF0000) : const Color(0xFFFFFFFF);
    final fillColor = _pathColorFromIndex(colorIdx);
    if (mode == 0) {
      _appendPathPolygon(
        out,
        trackVertices,
        fillColor,
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
      );
      return;
    }
    if (mode >= 13 && mode <= 15) {
      _collectSpecialModePolygons(
          out, trackVertices, mode, colorIdx, brakeLights);
      return;
    }
    if (mode >= 9) {
      _collectComplexPathPolygons(out, trackVertices, colorIdx, brakeLights);
      return;
    }
    _collectAnimatedPathPolygons(
        out, trackVertices, mode, colorIdx, brakeLights);
  }

  Map<String, dynamic> _encodePolygon(
    List<Offset> vertices,
    Color fillColor, {
    Color? strokeColor,
    double strokeWidth = 0.0,
  }) {
    final points = <double>[];
    for (final v in vertices) {
      points
        ..add(v.dx)
        ..add(v.dy);
    }
    return <String, dynamic>{
      'points': points,
      'fillColor': fillColor.toARGB32(),
      if (strokeColor != null) 'strokeColor': strokeColor.toARGB32(),
      if (strokeColor != null) 'strokeWidth': strokeWidth,
    };
  }

  List<Offset> _lineQuadVertices(Offset a, Offset b, double thickness) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = math.sqrt((dx * dx) + (dy * dy));
    if (!len.isFinite || len <= 1e-6) {
      final t = thickness * 0.5;
      return <Offset>[
        Offset(a.dx - t, a.dy - t),
        Offset(a.dx + t, a.dy - t),
        Offset(a.dx + t, a.dy + t),
        Offset(a.dx - t, a.dy + t),
      ];
    }
    final nx = -dy / len;
    final ny = dx / len;
    final t = thickness * 0.5;
    final ox = nx * t;
    final oy = ny * t;
    return <Offset>[
      Offset(a.dx + ox, a.dy + oy),
      Offset(b.dx + ox, b.dy + oy),
      Offset(b.dx - ox, b.dy - oy),
      Offset(a.dx - ox, a.dy - oy),
    ];
  }

  void _appendDebugLinePolygon(
    List<Map<String, dynamic>> out, {
    required Offset a,
    required Offset b,
    required Color color,
    double thickness = 2.0,
  }) {
    if (!a.dx.isFinite ||
        !a.dy.isFinite ||
        !b.dx.isFinite ||
        !b.dy.isFinite ||
        thickness <= 0.0) {
      return;
    }
    final quad = _lineQuadVertices(a, b, thickness);
    if (quad.length < 4) return;
    out.add(_encodePolygon(quad, color));
  }

  Rect? _verticesBounds(List<Offset> vertices) {
    if (vertices.isEmpty) return null;
    var minX = vertices.first.dx;
    var minY = vertices.first.dy;
    var maxX = vertices.first.dx;
    var maxY = vertices.first.dy;
    for (final p in vertices) {
      if (!p.dx.isFinite || !p.dy.isFinite) continue;
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    if ((maxX - minX) <= 1e-3 || (maxY - minY) <= 1e-3) return null;
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  bool _boolFromDynamic(dynamic raw, {bool fallback = false}) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final value = raw.trim().toLowerCase();
      if (value == '1' || value == 'true' || value == 'yes' || value == 'on') {
        return true;
      }
      if (value == '0' || value == 'false' || value == 'no' || value == 'off') {
        return false;
      }
    }
    return fallback;
  }

  List<Offset> _rectVertices(
      double left, double top, double right, double bottom) {
    return <Offset>[
      Offset(left, top),
      Offset(right, top),
      Offset(right, bottom),
      Offset(left, bottom),
    ];
  }

  List<Offset> _roundedRectVertices(
    Rect rect, {
    double radius = 15.0,
    int segmentsPerCorner = 4,
  }) {
    if (rect.width <= 0.0 || rect.height <= 0.0) return const <Offset>[];
    final r = math.min(radius, math.min(rect.width, rect.height) * 0.5);
    final seg = math.max(2, segmentsPerCorner);
    final points = <Offset>[];
    void addArc(Offset center, double start, double end) {
      for (var i = 0; i <= seg; i++) {
        final t = i / seg;
        final a = start + ((end - start) * t);
        points.add(Offset(
            center.dx + (math.cos(a) * r), center.dy + (math.sin(a) * r)));
      }
    }

    addArc(Offset(rect.right - r, rect.top + r), -math.pi / 2.0, 0.0);
    addArc(Offset(rect.right - r, rect.bottom - r), 0.0, math.pi / 2.0);
    addArc(Offset(rect.left + r, rect.bottom - r), math.pi / 2.0, math.pi);
    addArc(Offset(rect.left + r, rect.top + r), math.pi, math.pi * 1.5);
    return points;
  }

  List<Offset> _circleVertices(
    Offset center,
    double radius, {
    int segments = 18,
  }) {
    if (radius <= 0.0) return const <Offset>[];
    final steps = segments < 6 ? 6 : segments;
    final points = <Offset>[];
    for (var i = 0; i < steps; i++) {
      final theta = (math.pi * 2.0 * i) / steps;
      points.add(
        Offset(
          center.dx + (math.cos(theta) * radius),
          center.dy + (math.sin(theta) * radius),
        ),
      );
    }
    return points;
  }

  void _appendOverlayLabel(
    List<Map<String, dynamic>> labels, {
    required Offset anchor,
    required String text,
    required Color color,
    double size = 20.0,
    bool centered = true,
  }) {
    final content = text.trim();
    if (content.isEmpty || !anchor.dx.isFinite || !anchor.dy.isFinite) return;
    final x =
        centered ? (anchor.dx - (content.length * size * 0.22)) : anchor.dx;
    labels.add(<String, dynamic>{
      'x': x,
      'y': anchor.dy,
      'text': content,
      'color': color.toARGB32(),
      'size': size,
    });
  }

  void _appendBadge(
    List<Map<String, dynamic>> polygons,
    List<Map<String, dynamic>> labels, {
    required Offset center,
    required String text,
    required Color fillColor,
    required Color textColor,
    Color? strokeColor,
    double fontSize = 22.0,
    double minWidth = 54.0,
    double height = 38.0,
  }) {
    final content = text.trim();
    if (content.isEmpty || !center.dx.isFinite || !center.dy.isFinite) return;
    final width = math
        .max(minWidth, (content.length * fontSize * 0.62) + 18.0)
        .toDouble();
    final left = center.dx - (width * 0.5);
    final top = center.dy - (height * 0.5);
    final right = left + width;
    final bottom = top + height;
    polygons.add(
      _encodePolygon(
        _rectVertices(left, top, right, bottom),
        fillColor,
        strokeColor: strokeColor,
        strokeWidth: strokeColor == null ? 0.0 : 2.0,
      ),
    );
    _appendOverlayLabel(
      labels,
      anchor: Offset(center.dx, top + (height * 0.70)),
      text: content,
      color: textColor,
      size: fontSize,
      centered: true,
    );
  }

  String _navTurnText(int turnInfo, String fallbackText) {
    final fallback = fallbackText.trim();
    if (fallback.isNotEmpty) return fallback;
    switch (turnInfo) {
      case 1:
        return '좌회전';
      case 2:
        return '우회전';
      case 3:
        return '좌차선 변경';
      case 4:
        return '우차선 변경';
      case 7:
        return '유턴';
      case 8:
        return '도착';
      default:
        return '';
    }
  }

  String _formatNavDistance(double? distanceMeters) {
    if (distanceMeters == null ||
        !distanceMeters.isFinite ||
        distanceMeters <= 0) {
      return '';
    }
    if (distanceMeters >= 1000.0) {
      return '${(distanceMeters / 1000.0).toStringAsFixed(1)}km';
    }
    return '${distanceMeters.round()}m';
  }

  List<Offset> _arrowHeadVertices(Offset center, double angle, double size) {
    final forward = Offset(math.cos(angle), math.sin(angle));
    final side = Offset(-forward.dy, forward.dx);
    final tip = Offset(
      center.dx + (forward.dx * size),
      center.dy + (forward.dy * size),
    );
    final rear = Offset(
      center.dx - (forward.dx * size * 0.92),
      center.dy - (forward.dy * size * 0.92),
    );
    final left = Offset(
      rear.dx + (side.dx * size * 0.70),
      rear.dy + (side.dy * size * 0.70),
    );
    final right = Offset(
      rear.dx - (side.dx * size * 0.70),
      rear.dy - (side.dy * size * 0.70),
    );
    final inner = Offset(
      center.dx - (forward.dx * size * 0.16),
      center.dy - (forward.dy * size * 0.16),
    );
    return <Offset>[left, tip, right, inner];
  }

  void _appendNavArOverlayPolygons({
    required List<Map<String, dynamic>> polygons,
    required List<Map<String, dynamic>> labels,
    required _ProjectionTransform transform,
    required Size canvasSize,
  }) {
    if (cameraKind != _DriveCameraKind.road) return;

    // Road-camera AR tuning knobs:
    // - distanceScale: perspective depth scaling for nav path/chevrons
    // - pathVerticalOffsetPx: vertical offset applied to projected nav path
    // - gateVerticalOffsetPx: additional vertical offset for turn board
    const distanceScale = 0.92;
    final pathVerticalOffsetPx = canvasSize.height * 0.018;
    final gateVerticalOffsetPx = -(canvasSize.height * 0.028);

    final navPath = snapshot.navPathPoints;
    final hasTurnText = snapshot.navMainText.trim().isNotEmpty;
    final hasTurnInfo = snapshot.navTurnInfo != 0 || hasTurnText;
    if (navPath.length < 2 && !hasTurnInfo) return;

    final laneBaseLine = snapshot.laneLines.length > 2
        ? snapshot.laneLines[2].line
        : (snapshot.laneLines.isNotEmpty
            ? snapshot.laneLines.first.line
            : null);
    final laneX = laneBaseLine?.x ?? snapshot.path.x;
    final laneZ = laneBaseLine?.z ?? snapshot.path.z;
    final zOffset = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;

    final projected = <Offset>[];
    final projectedDist = <double>[];
    for (final p in navPath) {
      if (!p.x.isFinite || !p.y.isFinite || !p.d.isFinite) continue;
      if (p.x < 2.0 || p.x > 140.0) continue;
      final sampleDist = (p.d > 0 ? p.d : p.x) * distanceScale;
      var z = 0.0;
      if (laneX.isNotEmpty && laneZ.isNotEmpty) {
        final idx = _getPathLengthIdx(laneX, sampleDist);
        if (laneZ.isNotEmpty) {
          final zi = idx.clamp(0, laneZ.length - 1);
          z = laneZ[zi];
        }
      }
      Offset? out;
      final ok = _mapToScreen(
        transform,
        ((p.x < 3.0 ? 5.0 : p.x) * distanceScale).clamp(2.0, 140.0),
        p.y,
        z + zOffset,
        (pt) => out = pt,
      );
      if (!ok || out == null) continue;
      final o = Offset(out!.dx, out!.dy + pathVerticalOffsetPx);
      if (o.dx < -60.0 ||
          o.dx > canvasSize.width + 60.0 ||
          o.dy < -60.0 ||
          o.dy > canvasSize.height + 60.0) {
        continue;
      }
      projected.add(o);
      projectedDist.add(sampleDist);
      if (projected.length >= 90) break;
    }

    if (projected.length >= 2) {
      final segmentStep = math.max(1, (projected.length / 34).floor());
      for (var i = 0; i + segmentStep < projected.length; i += segmentStep) {
        final a = projected[i];
        final b = projected[i + segmentStep];
        final t = i / math.max(1, projected.length - 1);
        final glowWidth = (11.0 - (t * 4.5)).clamp(4.8, 11.0);
        final coreWidth = (5.6 - (t * 2.2)).clamp(2.4, 5.6);
        polygons.add(
          _encodePolygon(
            _lineQuadVertices(a, b, glowWidth),
            const Color(0x5535FF84),
          ),
        );
        polygons.add(
          _encodePolygon(
            _lineQuadVertices(a, b, coreWidth),
            const Color(0xCC2EEA6A),
          ),
        );
      }

      final chevronCount = math.min(3, projected.length - 1);
      final chevronSize = (canvasSize.width * 0.013).clamp(8.0, 14.0);
      for (var c = 0; c < chevronCount; c++) {
        final idx = (((c + 1) * (projected.length - 2)) / (chevronCount + 1))
            .round()
            .clamp(0, projected.length - 2);
        final a = projected[idx];
        final b = projected[idx + 1];
        final dir = b - a;
        final len = dir.distance;
        if (!len.isFinite || len <= 1.0) continue;
        final center = Offset(
          a.dx + (dir.dx * 0.35),
          a.dy + (dir.dy * 0.35),
        );
        final angle = math.atan2(dir.dy, dir.dx);
        polygons.add(
          _encodePolygon(
            _arrowHeadVertices(center, angle, chevronSize),
            const Color(0xCC244CFF),
            strokeColor: const Color(0xCCFFFFFF),
            strokeWidth: 1.4,
          ),
        );
      }
    }

    final turnText = _navTurnText(snapshot.navTurnInfo, snapshot.navMainText);
    final turnDistText = _formatNavDistance(snapshot.navDistToTurn);
    final gateText = turnText.isEmpty
        ? ''
        : (turnDistText.isEmpty ? turnText : '$turnDistText ??$turnText');

    if (gateText.isNotEmpty) {
      Offset gateAnchor;
      if (projected.isNotEmpty) {
        var anchorIdx = -1;
        for (var i = 0; i < projected.length; i++) {
          final d = i < projectedDist.length ? projectedDist[i] : 0.0;
          if (d >= 14.0 && d <= 38.0) {
            anchorIdx = i;
            break;
          }
        }
        if (anchorIdx < 0) anchorIdx = projected.length ~/ 2;
        gateAnchor = projected[anchorIdx];
      } else {
        gateAnchor = Offset(canvasSize.width * 0.5, canvasSize.height * 0.28);
      }

      final fontSize = (canvasSize.width * 0.017).clamp(13.0, 20.0);
      final boardWidth = math
          .min(
            canvasSize.width * 0.66,
            math.max(170.0, (gateText.length * fontSize * 0.58) + 38.0),
          )
          .toDouble();
      final boardHeight = (fontSize * 2.2).clamp(46.0, 74.0);
      final left = (gateAnchor.dx - (boardWidth * 0.5))
          .clamp(12.0, canvasSize.width - boardWidth - 12.0);
      final top = (gateAnchor.dy -
              boardHeight -
              (fontSize * 1.8) +
              gateVerticalOffsetPx)
          .clamp(12.0, canvasSize.height - boardHeight - 20.0);
      final gateRect = Rect.fromLTWH(left, top, boardWidth, boardHeight);

      polygons.add(
        _encodePolygon(
          _roundedRectVertices(gateRect, radius: 14.0, segmentsPerCorner: 5),
          const Color(0xE617A84B),
          strokeColor: const Color(0xCCFFFFFF),
          strokeWidth: 1.4,
        ),
      );
      _appendOverlayLabel(
        labels,
        anchor:
            Offset(gateRect.center.dx, gateRect.center.dy + (fontSize * 0.22)),
        text: gateText,
        color: Colors.white,
        size: fontSize,
        centered: true,
      );
    }

    String statusText;
    Color statusFill;
    if (snapshot.navTurnInfo == 8 ||
        turnText.contains('도착') ||
        snapshot.navMainText.contains('도착')) {
      statusText = '도착 임박';
      statusFill = const Color(0xE617A84B);
    } else if (projected.length >= 2) {
      statusText = '정상 경로';
      statusFill = const Color(0xE617A84B);
    } else {
      statusText = '경로 탐색 중';
      statusFill = const Color(0xD9A36800);
    }
    _appendBadge(
      polygons,
      labels,
      center: Offset(canvasSize.width * 0.5, canvasSize.height - 58.0),
      text: statusText,
      fillColor: statusFill,
      textColor: Colors.white,
      strokeColor: const Color(0xB3FFFFFF),
      fontSize: (canvasSize.width * 0.012).clamp(12.0, 16.0),
      minWidth: 132.0,
      height: 36.0,
    );
  }

  void _appendSidecarLeadAndRadarPolygons({
    required Map<String, dynamic> cam,
    required Size canvasSize,
    required double sourceWidth,
    required double sourceHeight,
    required Map<String, dynamic>? displayTransform,
    required List<Map<String, dynamic>> polygons,
    required List<Map<String, dynamic>> labels,
    required bool showLead1,
    required bool showLead2,
    required bool showRadarBadge,
    required bool showRadarVector,
    required bool showStopDistanceTf,
    required bool showStateText,
  }) {
    final meta = cam['meta'];
    final showRadarInfo = meta is Map
        ? (_DriveOverlaySnapshot._asInt(meta['showRadarInfo']) ?? 0)
        : 0;
    final xState =
        meta is Map ? (_DriveOverlaySnapshot._asInt(meta['xState']) ?? 0) : 0;
    final trafficState = meta is Map
        ? (_DriveOverlaySnapshot._asInt(meta['trafficState']) ?? 0)
        : 0;
    final longActive = meta is Map
        ? _boolFromDynamic(meta['longActive'], fallback: false)
        : false;
    final vEgoMps = meta is Map
        ? (_DriveOverlaySnapshot._asDouble(meta['vEgoMps']) ?? 0.0)
        : 0.0;

    var drawDistanceBadges = true;
    String? stateText;
    if (longActive) {
      if (xState == 3 || xState == 5) {
        drawDistanceBadges = false;
        if (vEgoMps < 1.0) {
          stateText = trafficState >= 1000 ? 'Signal Error' : 'Signal Ready';
        } else {
          stateText = 'Signal slowing';
        }
      } else if (xState == 4) {
        drawDistanceBadges = false;
        stateText = 'E2E 주행중';
      } else if (xState == 0 || xState == 1 || xState == 2) {
        drawDistanceBadges = true;
      } else {
        drawDistanceBadges = false;
      }
    }
    final badgeTextColor = xState == 0
        ? Colors.white
        : (xState == 1 ? const Color(0xFFB0B0B0) : const Color(0xFF23D55D));

    Offset? mapSingleSourcePoint(dynamic raw) {
      if (raw is! List || raw.length < 2) return null;
      final sx = _DriveOverlaySnapshot._asDouble(raw[0]);
      final sy = _DriveOverlaySnapshot._asDouble(raw[1]);
      if (sx == null || sy == null) return null;
      final mapped = _mapSourcePointsToCanvas(
        <Offset>[Offset(sx, sy)],
        canvasSize: canvasSize,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        displayTransform: displayTransform,
      );
      if (mapped.isEmpty) return null;
      return mapped.first;
    }

    Offset? leadPrimaryCenter;
    Rect? leadPrimaryBounds;
    final leadRaw = cam['leadAreaBoxes'];
    if (leadRaw is List) {
      for (final item in leadRaw) {
        if (item is! Map) continue;
        final lead = Map<String, dynamic>.from(item);
        final mapped = _mapSourcePointsToCanvas(
          _decodeOverlayPoints(lead['points']),
          canvasSize: canvasSize,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          displayTransform: displayTransform,
        );
        if (mapped.length < 3) continue;
        final bounds = _verticesBounds(mapped);
        if (bounds == null) continue;

        final kind = lead['kind']?.toString() ?? 'leadOne';
        if (kind == 'leadOne' && !showLead1) continue;
        if (kind == 'leadTwo' && !showLead2) continue;
        final status = _DriveOverlaySnapshot._asInt(lead['status']) ?? 0;
        final radarDetected = _boolFromDynamic(lead['radar']);
        final radarTrackId =
            _DriveOverlaySnapshot._asInt(lead['radarTrackId']) ?? -1;
        final isLeadScc = radarTrackId < 1;
        final strokeArgb =
            _DriveOverlaySnapshot._asInt(lead['strokeColorArgb']);
        final fillArgb = _DriveOverlaySnapshot._asInt(lead['fillColorArgb']);

        Color strokeColor;
        Color fillColor;
        if (strokeArgb != null || fillArgb != null) {
          strokeColor = strokeArgb != null
              ? Color(strokeArgb)
              : (kind == 'leadTwo'
                  ? const Color(0xFFB68A3A)
                  : const Color(0xFFFFA726));
          fillColor = fillArgb != null
              ? Color(fillArgb)
              : (kind == 'leadTwo'
                  ? (status >= 2
                      ? const Color(0x66FF3B30)
                      : const Color(0x33000000))
                  : const Color(0x33000000));
        } else if (kind == 'leadTwo') {
          strokeColor = const Color(0xFFB68A3A);
          fillColor =
              status >= 2 ? const Color(0x66FF3B30) : const Color(0x33000000);
        } else {
          fillColor = const Color(0x33000000);
          if (!radarDetected) {
            strokeColor = const Color(0xFF3D7BFF);
          } else {
            strokeColor =
                isLeadScc ? const Color(0xFFFF3B30) : const Color(0xFFFFA726);
          }
        }
        polygons.add(
          _encodePolygon(
            _roundedRectVertices(bounds, radius: 15.0, segmentsPerCorner: 4),
            fillColor,
            strokeColor: strokeColor,
            strokeWidth: 3.0,
          ),
        );

        if (kind == 'leadOne') {
          leadPrimaryBounds ??= bounds;
          leadPrimaryCenter ??=
              mapSingleSourcePoint(lead['anchorCenter']) ?? bounds.center;
          final radarDist =
              _DriveOverlaySnapshot._asDouble(lead['radarDistance']) ?? 0.0;
          final visionDist =
              _DriveOverlaySnapshot._asDouble(lead['visionDistance']) ?? 0.0;
          final radarBadgeCenter =
              mapSingleSourcePoint(lead['radarBadgeCenter']);
          final visionBadgeCenter =
              mapSingleSourcePoint(lead['visionBadgeCenter']);
          final radarBadgeColorArgb =
              _DriveOverlaySnapshot._asInt(lead['radarBadgeColorArgb']);
          final visionBadgeColorArgb =
              _DriveOverlaySnapshot._asInt(lead['visionBadgeColorArgb']);
          final canvasBadgeDx =
              (bounds.width * 0.62).clamp(64.0, 140.0).toDouble();
          final canvasBadgeY = bounds.bottom +
              (bounds.height * 0.32).clamp(18.0, 48.0).toDouble();
          if (drawDistanceBadges && showRadarBadge && radarDist > 0.0) {
            _appendBadge(
              polygons,
              labels,
              center: radarBadgeCenter ??
                  Offset(bounds.center.dx - canvasBadgeDx, canvasBadgeY),
              text: radarDist.toStringAsFixed(1),
              fillColor: radarBadgeColorArgb != null
                  ? Color(radarBadgeColorArgb)
                  : (isLeadScc
                      ? const Color(0xFFFF3B30)
                      : const Color(0xFFFFA726)),
              textColor: badgeTextColor,
            );
          }
          if (drawDistanceBadges && showRadarBadge && visionDist > 0.0) {
            _appendBadge(
              polygons,
              labels,
              center: visionBadgeCenter ??
                  Offset(bounds.center.dx + canvasBadgeDx, canvasBadgeY),
              text: visionDist.toStringAsFixed(1),
              fillColor: visionBadgeColorArgb != null
                  ? Color(visionBadgeColorArgb)
                  : const Color(0xFF3D7BFF),
              textColor: badgeTextColor,
            );
          }
        }
      }
    }

    final tfRaw = cam['tfMarker'];
    if (showStopDistanceTf && tfRaw is Map) {
      final tf = Map<String, dynamic>.from(tfRaw);
      final mapped = _mapSourcePointsToCanvas(
        _decodeOverlayPoints(tf['points']),
        canvasSize: canvasSize,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        displayTransform: displayTransform,
      );
      if (mapped.length >= 2) {
        final left = mapped.first;
        final right = mapped.last;
        _appendDebugLinePolygon(
          polygons,
          a: left,
          b: right,
          color: Colors.white,
          thickness: 3.0,
        );
        final dist = _DriveOverlaySnapshot._asDouble(tf['distance']) ?? 0.0;
        final tFollow = _DriveOverlaySnapshot._asDouble(tf['tFollow']) ?? 0.0;
        if (dist > 0.0) {
          _appendOverlayLabel(
            labels,
            anchor: right,
            text: '${dist.toStringAsFixed(1)}(${tFollow.toStringAsFixed(2)})',
            color: Colors.white,
            size: 20.0,
            centered: false,
          );
        }
      }
    }

    if (showStateText && stateText != null) {
      dynamic leadOneAnchorRaw;
      if (leadRaw is List) {
        for (final e in leadRaw) {
          if (e is Map && (e['kind']?.toString() ?? 'leadOne') == 'leadOne') {
            leadOneAnchorRaw = e;
            break;
          }
        }
      }
      Offset? stateAnchor;
      if (leadOneAnchorRaw is Map) {
        final stateCenterRaw = leadOneAnchorRaw['stateTextCenter'];
        stateAnchor = mapSingleSourcePoint(stateCenterRaw);
      }
      if (stateAnchor == null && leadOneAnchorRaw is Map) {
        final raw = leadOneAnchorRaw['anchorCenter'];
        final anchorWidthSrc =
            _DriveOverlaySnapshot._asDouble(leadOneAnchorRaw['anchorWidth']);
        final sourceStateDy = (anchorWidthSrc != null && anchorWidthSrc > 0.0)
            ? (anchorWidthSrc * 0.52).clamp(52.0, 140.0).toDouble()
            : 60.0;
        if (raw is List && raw.length >= 2) {
          final ax = _DriveOverlaySnapshot._asDouble(raw[0]);
          final ay = _DriveOverlaySnapshot._asDouble(raw[1]);
          if (ax != null && ay != null) {
            stateAnchor =
                mapSingleSourcePoint(<double>[ax, ay + sourceStateDy]);
          }
        }
      }
      final primaryCenter = leadPrimaryCenter;
      final anchor = stateAnchor ??
          (primaryCenter != null
              ? Offset(
                  primaryCenter.dx,
                  (leadPrimaryBounds?.bottom ?? primaryCenter.dy) +
                      ((leadPrimaryBounds?.height ?? 72.0) * 0.72)
                          .clamp(36.0, 92.0)
                          .toDouble(),
                )
              : Offset(canvasSize.width * 0.5, canvasSize.height * 0.72));
      _appendOverlayLabel(
        labels,
        anchor: anchor,
        text: stateText,
        color: Colors.white,
        size: 34.0,
        centered: true,
      );
    }

    final radarRaw = cam['radarTargets'];
    if (showRadarInfo <= 0 ||
        radarRaw is! List ||
        (!showRadarBadge && !showRadarVector)) {
      return;
    }
    for (final item in radarRaw) {
      if (item is! Map) continue;
      final radar = Map<String, dynamic>.from(item);
      final center = mapSingleSourcePoint(radar['center']);
      if (center == null) continue;

      final vSigned =
          _DriveOverlaySnapshot._asDouble(radar['speedMpsSigned']) ?? 0.0;
      final speedAbs = vSigned.abs();
      final dRel = _DriveOverlaySnapshot._asDouble(radar['dRel']) ?? 0.0;
      final yRel = _DriveOverlaySnapshot._asDouble(radar['yRel']) ?? 0.0;
      final radarDetected = _boolFromDynamic(radar['radar']);
      final modelProb =
          _DriveOverlaySnapshot._asDouble(radar['modelProb']) ?? 0.0;

      final future = mapSingleSourcePoint(radar['future']);
      if (showRadarVector && future != null && speedAbs > 3.0) {
        _appendDebugLinePolygon(
          polygons,
          a: center,
          b: future,
          color: vSigned >= 0.0
              ? const Color(0xFF23D55D)
              : const Color(0xFFFF3B30),
          thickness: 3.0,
        );
        polygons.add(
          _encodePolygon(
            _circleVertices(future, 7.0),
            vSigned >= 0.0 ? const Color(0xFF23D55D) : const Color(0xFFFF3B30),
          ),
        );
      }

      if (showRadarBadge && speedAbs > 3.0) {
        final speedKph =
            _DriveOverlaySnapshot._asDouble(radar['speedKphSigned']) ??
                (vSigned * 3.6);
        Color badgeColor;
        if (!radarDetected) {
          badgeColor = const Color(0xFF3D7BFF);
        } else if ((modelProb - 0.01).abs() < 1e-3) {
          badgeColor = const Color(0xFF23D55D);
        } else if (vSigned > 0.0) {
          badgeColor = const Color(0xFFFFA726);
        } else {
          badgeColor = const Color(0xFFFF3B30);
        }
        _appendBadge(
          polygons,
          labels,
          center: Offset(center.dx, center.dy - 14.0),
          text: speedKph.toStringAsFixed(0),
          fillColor: badgeColor,
          textColor: Colors.white,
        );
        if (showRadarInfo >= 2) {
          _appendOverlayLabel(
            labels,
            anchor: Offset(center.dx, center.dy - 44.0),
            text: yRel.toStringAsFixed(1),
            color: Colors.white,
            size: 18.0,
            centered: true,
          );
          _appendOverlayLabel(
            labels,
            anchor: Offset(center.dx, center.dy + 28.0),
            text: dRel.toStringAsFixed(1),
            color: Colors.white,
            size: 18.0,
            centered: true,
          );
        }
      } else if (showRadarInfo >= 3) {
        _appendOverlayLabel(
          labels,
          anchor: center,
          text: '*',
          color: Colors.white,
          size: 28.0,
          centered: true,
        );
      }
    }
  }

  void _appendDebugScreenGridPolygons(
    List<Map<String, dynamic>> out, {
    required Size canvasSize,
  }) {
    const minorColor = Color(0x9955FF55);
    const majorColor = Color(0xEE00FF00);
    const cols = 10;
    const rows = 6;
    // Strong frame border so the 2D grid coverage is visually unmistakable.
    _appendDebugLinePolygon(
      out,
      a: const Offset(0, 0),
      b: Offset(canvasSize.width, 0),
      color: majorColor,
      thickness: 3.0,
    );
    _appendDebugLinePolygon(
      out,
      a: Offset(canvasSize.width, 0),
      b: Offset(canvasSize.width, canvasSize.height),
      color: majorColor,
      thickness: 3.0,
    );
    _appendDebugLinePolygon(
      out,
      a: Offset(canvasSize.width, canvasSize.height),
      b: Offset(0, canvasSize.height),
      color: majorColor,
      thickness: 3.0,
    );
    _appendDebugLinePolygon(
      out,
      a: Offset(0, canvasSize.height),
      b: const Offset(0, 0),
      color: majorColor,
      thickness: 3.0,
    );

    for (var i = 1; i < cols; i++) {
      final x = (canvasSize.width * i) / cols;
      final isMajor =
          i == (cols ~/ 2) || i == (cols ~/ 4) || i == ((cols * 3) ~/ 4);
      _appendDebugLinePolygon(
        out,
        a: Offset(x, 0),
        b: Offset(x, canvasSize.height),
        color: isMajor ? majorColor : minorColor,
        thickness: isMajor ? 2.4 : 1.6,
      );
    }
    for (var i = 1; i < rows; i++) {
      final y = (canvasSize.height * i) / rows;
      final isMajor = i == (rows ~/ 2);
      _appendDebugLinePolygon(
        out,
        a: Offset(0, y),
        b: Offset(canvasSize.width, y),
        color: isMajor ? majorColor : minorColor,
        thickness: isMajor ? 2.4 : 1.6,
      );
    }
  }

  List<Map<String, dynamic>> _buildDebugGridLabels({
    required Size canvasSize,
  }) {
    const cols = 10;
    const rows = 6;
    const color = Color(0xDDFAFF9A);
    final labels = <Map<String, dynamic>>[];
    for (var r = 0; r <= rows; r++) {
      final y = (canvasSize.height * r) / rows;
      for (var c = 0; c <= cols; c++) {
        final x = (canvasSize.width * c) / cols;
        final nx = (c / cols).toStringAsFixed(1);
        final ny = (r / rows).toStringAsFixed(1);
        final lx =
            _clampDouble(x + 4.0, 2.0, math.max(2.0, canvasSize.width - 48.0));
        final ly = _clampDouble(
            y + 11.0, 10.0, math.max(10.0, canvasSize.height - 2.0));
        labels.add(<String, dynamic>{
          'x': lx,
          'y': ly,
          'text': '$nx,$ny',
          'color': color.toARGB32(),
          'size': 10.0,
        });
      }
    }
    return labels;
  }

  void _drawDebugGridLabels(
    Canvas canvas, {
    required Size size,
  }) {
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    );
    final labels = _buildDebugGridLabels(canvasSize: size);
    for (final raw in labels) {
      final dx = _DriveOverlaySnapshot._asDouble(raw['x']);
      final dy = _DriveOverlaySnapshot._asDouble(raw['y']);
      final text = raw['text']?.toString() ?? '';
      if (dx == null || dy == null || text.isEmpty) continue;
      final colorInt = _DriveOverlaySnapshot._asInt(raw['color']) ??
          const Color(0xDDFAFF9A).toARGB32();
      final sizePx = _DriveOverlaySnapshot._asDouble(raw['size']) ?? 10.0;
      tp.text = TextSpan(
        text: text,
        style: TextStyle(
          color: Color(colorInt),
          fontSize: sizePx,
          fontWeight: FontWeight.w500,
        ),
      );
      tp.layout(maxWidth: 80.0);
      tp.paint(canvas, Offset(dx, dy));
    }
  }

  void _drawDebugScreenGrid(
    Canvas canvas, {
    required Size size,
  }) {
    final minorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = const Color(0x9955FF55);
    final majorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = const Color(0xEE00FF00);
    const cols = 10;
    const rows = 6;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      majorPaint,
    );
    for (var i = 1; i < cols; i++) {
      final x = (size.width * i) / cols;
      final isMajor =
          i == (cols ~/ 2) || i == (cols ~/ 4) || i == ((cols * 3) ~/ 4);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        isMajor ? majorPaint : minorPaint,
      );
    }
    for (var i = 1; i < rows; i++) {
      final y = (size.height * i) / rows;
      final isMajor = i == (rows ~/ 2);
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        isMajor ? majorPaint : minorPaint,
      );
    }
    _drawDebugGridLabels(
      canvas,
      size: size,
    );
  }

  List<List<Offset>> _buildWorldGridPolylines(_ProjectionTransform transform) {
    final polylines = <List<Offset>>[];
    final zBase = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
    const gridLat = <double>[-3.5, -1.75, 0.0, 1.75, 3.5];
    const gridDist = <double>[3.0, 5.0, 8.0, 12.0, 20.0, 30.0, 45.0, 60.0];

    for (final lat in gridLat) {
      final line = <Offset>[];
      for (final dist in gridDist) {
        Offset? p;
        final ok = _mapToScreen(transform, dist, lat, zBase, (pt) => p = pt);
        if (!ok || p == null) continue;
        line.add(p!);
      }
      if (line.length >= 2) polylines.add(line);
    }

    for (final dist in gridDist) {
      final line = <Offset>[];
      for (final lat in gridLat) {
        Offset? p;
        final ok = _mapToScreen(transform, dist, lat, zBase, (pt) => p = pt);
        if (!ok || p == null) continue;
        line.add(p!);
      }
      if (line.length >= 2) polylines.add(line);
    }
    return polylines;
  }

  void _appendDebugWorldGridPolygons(
    List<Map<String, dynamic>> out, {
    required _ProjectionTransform transform,
  }) {
    final gridLines = _buildWorldGridPolylines(transform);
    if (gridLines.isEmpty) return;
    const lineColor = Color(0x6674B9FF);
    for (final line in gridLines) {
      for (var i = 1; i < line.length; i++) {
        _appendDebugLinePolygon(
          out,
          a: line[i - 1],
          b: line[i],
          color: lineColor,
          thickness: 1.6,
        );
      }
    }
  }

  void _drawDebugWorldGrid(
    Canvas canvas, {
    required _ProjectionTransform transform,
  }) {
    final gridLines = _buildWorldGridPolylines(transform);
    if (gridLines.isEmpty) return;
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x6674B9FF);
    for (final line in gridLines) {
      if (line.length < 2) continue;
      final path = Path()..moveTo(line.first.dx, line.first.dy);
      for (var i = 1; i < line.length; i++) {
        path.lineTo(line[i].dx, line[i].dy);
      }
      canvas.drawPath(path, gridPaint);
    }
  }

  void _appendDebugGuidePolygons(
    List<Map<String, dynamic>> out, {
    required Size canvasSize,
    required _ProjectionTransform transform,
    required List<Offset>? trackVertices,
  }) {
    _appendDebugScreenGridPolygons(
      out,
      canvasSize: canvasSize,
    );
    final cx = canvasSize.width * 0.5;
    final cy = canvasSize.height * 0.5;
    const centerColor = Color(0x88FF4D4D);
    _appendDebugLinePolygon(
      out,
      a: Offset(cx, 0),
      b: Offset(cx, canvasSize.height),
      color: centerColor,
      thickness: 2.0,
    );
    _appendDebugLinePolygon(
      out,
      a: Offset(0, cy),
      b: Offset(canvasSize.width, cy),
      color: centerColor,
      thickness: 2.0,
    );
    _appendDebugWorldGridPolygons(
      out,
      transform: transform,
    );

    if (trackVertices == null || trackVertices.length < 3) return;
    final bounds = _verticesBounds(trackVertices);
    if (bounds == null) return;
    const boxColor = Color(0xCCFFD700);
    _appendDebugLinePolygon(
      out,
      a: bounds.topLeft,
      b: bounds.topRight,
      color: boxColor,
      thickness: 2.5,
    );
    _appendDebugLinePolygon(
      out,
      a: bounds.topRight,
      b: bounds.bottomRight,
      color: boxColor,
      thickness: 2.5,
    );
    _appendDebugLinePolygon(
      out,
      a: bounds.bottomRight,
      b: bounds.bottomLeft,
      color: boxColor,
      thickness: 2.5,
    );
    _appendDebugLinePolygon(
      out,
      a: bounds.bottomLeft,
      b: bounds.topLeft,
      color: boxColor,
      thickness: 2.5,
    );
  }

  void _drawDebugGuides(
    Canvas canvas, {
    required Size size,
    required _ProjectionTransform transform,
    required List<Offset>? trackVertices,
  }) {
    _drawDebugScreenGrid(
      canvas,
      size: size,
    );
    final centerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0x99FF4D4D);
    canvas.drawLine(
      Offset(size.width * 0.5, 0),
      Offset(size.width * 0.5, size.height),
      centerPaint,
    );
    canvas.drawLine(
      Offset(0, size.height * 0.5),
      Offset(size.width, size.height * 0.5),
      centerPaint,
    );
    _drawDebugWorldGrid(
      canvas,
      transform: transform,
    );

    if (trackVertices == null || trackVertices.length < 3) return;
    final bounds = _verticesBounds(trackVertices);
    if (bounds == null) return;
    final rectPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xCCFFD700);
    canvas.drawRect(bounds, rectPaint);
  }

  void _drawEncodedOverlayPayload(
    Canvas canvas,
    Size canvasSize,
    Map<String, dynamic> payload,
  ) {
    final polygonsRaw = payload['polygons'];
    if (polygonsRaw is List) {
      for (final item in polygonsRaw) {
        if (item is! Map) continue;
        final points = _decodeOverlayPoints(item['points']);
        if (points.length < 3) continue;
        final fillInt = _DriveOverlaySnapshot._asInt(item['fillColor']) ??
            const Color(0x00000000).toARGB32();
        final strokeInt = _DriveOverlaySnapshot._asInt(item['strokeColor']);
        final strokeWidth =
            (_DriveOverlaySnapshot._asDouble(item['strokeWidth']) ?? 0.0)
                .clamp(0.0, 20.0);
        final path = _pathFromVertices(points);
        final fillColor = Color(fillInt);
        final fillAlpha = (fillColor.a * 255.0).round().clamp(0, 255);
        if (fillAlpha > 0) {
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.fill
              ..color = fillColor,
          );
        }
        if (strokeInt != null && strokeWidth > 0.0) {
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..color = Color(strokeInt),
          );
        }
      }
    }

    final labelsRaw = payload['labels'];
    if (labelsRaw is! List || labelsRaw.isEmpty) return;
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    );
    for (final item in labelsRaw) {
      if (item is! Map) continue;
      final dx = _DriveOverlaySnapshot._asDouble(item['x']);
      final dy = _DriveOverlaySnapshot._asDouble(item['y']);
      final text = item['text']?.toString() ?? '';
      if (dx == null || dy == null || text.isEmpty) continue;
      final colorInt = _DriveOverlaySnapshot._asInt(item['color']) ??
          const Color(0xFFFFFFFF).toARGB32();
      final sizePx = (_DriveOverlaySnapshot._asDouble(item['size']) ?? 16.0)
          .clamp(8.0, 72.0);
      final centered = _boolFromDynamic(item['centered']);
      tp.text = TextSpan(
        text: text,
        style: TextStyle(
          color: Color(colorInt),
          fontSize: sizePx,
          fontWeight: FontWeight.w700,
        ),
      );
      final labelMaxWidth = (canvasSize.width * 0.42).clamp(140.0, 760.0);
      tp.layout(maxWidth: labelMaxWidth.toDouble());
      final paintOffset = centered
          ? Offset(dx - (tp.width * 0.5), dy - (tp.height * 0.5))
          : Offset(dx, dy - tp.height);
      tp.paint(canvas, paintOffset);
    }
  }

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final sidecarPayload = _buildNativeOverlayPayloadFromSidecar2d(size);
    if (sidecarPayload != null) {
      _drawEncodedOverlayPayload(canvas, size, sidecarPayload);
      return;
    }
    if (snapshot.path.length < 2) return;
    final transform = _buildTransform(size);
    final modelMax = snapshot.path.x.isNotEmpty ? snapshot.path.x.last : 0.0;
    final maxDistance = modelMax.clamp(10.0, 100.0);
    final laneBaseX = snapshot.laneLines.isNotEmpty
        ? snapshot.laneLines.first.line.x
        : snapshot.path.x;
    final laneMaxIdx = laneBaseX.isNotEmpty
        ? _getPathLengthIdx(laneBaseX, maxDistance)
        : _getPathLengthIdx(snapshot.path.x, maxDistance);

    if (showLaneLines) {
      final laneFill = Paint()..style = PaintingStyle.fill;
      for (var i = 0; i < snapshot.laneLines.length; i++) {
        final ln = snapshot.laneLines[i];
        var lineWidth = 0.025;
        if (i == 1 && snapshot.leftLaneLine >= 20) {
          lineWidth = 0.05;
        }
        final poly = _mapLineToPolygon(
          transform,
          ln.line,
          lineWidth,
          0.0,
          laneMaxIdx,
        );
        if (poly == null) continue;
        final alpha = ln.probability > 0.3 ? (220.0 / 255.0) : 0.0;
        if (alpha <= 0.0) continue;
        Color laneColor = Colors.white;
        if (i == 1 && snapshot.leftLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        } else if (i == 2 && snapshot.rightLaneLine >= 20) {
          laneColor = const Color(0xFFFFD95E);
        }
        laneFill.color = laneColor.withValues(alpha: alpha);
        canvas.drawPath(poly, laneFill);
        if (i == 1 && (snapshot.leftLaneLine % 10) == 4) {
          final doublePoly = _mapLineToPolygon(
            transform,
            ln.line,
            lineWidth,
            0.0,
            laneMaxIdx,
            lineCenterShift: -0.3,
          );
          if (doublePoly != null) {
            canvas.drawPath(doublePoly, laneFill);
          }
        }
      }
    }

    if (showRoadEdge) {
      final edgeFill = Paint()..style = PaintingStyle.fill;
      for (final edge in snapshot.roadEdges) {
        final poly = _mapLineToPolygon(
          transform,
          edge.line,
          0.025,
          0.0,
          laneMaxIdx,
        );
        if (poly == null) continue;
        edgeFill.color = _roadEdgeColor(edge.std);
        canvas.drawPath(poly, edgeFill);
      }
    }

    final pathMode = snapshot.pathMode;
    final widthApply = _pathHalfWidthByMode(pathMode, snapshot.pathWidthRatio);
    final zOff = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
    final startDistance = snapshot.active ? 2.0 : 3.5;
    final trackVertices = _mapLineToTrackVerticesDist(
      transform,
      snapshot.path,
      widthApply,
      zOff,
      zOff,
      maxDistance,
      startDistance: startDistance,
      allowInvert: false,
    );
    if (showPathFill && trackVertices != null) {
      _drawPathByMode(canvas, trackVertices);
    }
    final navPolygons = <Map<String, dynamic>>[];
    final navLabels = <Map<String, dynamic>>[];
    _appendNavArOverlayPolygons(
      polygons: navPolygons,
      labels: navLabels,
      transform: transform,
      canvasSize: size,
    );
    if (navPolygons.isNotEmpty || navLabels.isNotEmpty) {
      _drawEncodedOverlayPayload(
        canvas,
        size,
        <String, dynamic>{
          'polygons': navPolygons,
          if (navLabels.isNotEmpty) 'labels': navLabels,
        },
      );
    }
    if (showDebugGuides) {
      _drawDebugGuides(
        canvas,
        size: size,
        transform: transform,
        trackVertices: trackVertices,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DriveOverlayPainter oldDelegate) {
    return oldDelegate.snapshot != snapshot ||
        oldDelegate.isConnected != isConnected ||
        oldDelegate.sourceSize != sourceSize ||
        oldDelegate.cameraKind != cameraKind ||
        oldDelegate.coverViewport != coverViewport ||
        oldDelegate.showDebugGuides != showDebugGuides ||
        oldDelegate.showPathFill != showPathFill ||
        oldDelegate.showLaneLines != showLaneLines ||
        oldDelegate.showRoadEdge != showRoadEdge ||
        oldDelegate.showLead1 != showLead1 ||
        oldDelegate.showLead2 != showLead2 ||
        oldDelegate.showRadarBadge != showRadarBadge ||
        oldDelegate.showRadarVector != showRadarVector ||
        oldDelegate.showStopDistanceTf != showStopDistanceTf ||
        oldDelegate.showStateText != showStateText;
  }
}

