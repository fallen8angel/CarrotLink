part of 'live_drive_canvas_screen.dart';

class _DriveOverlayPainter extends CustomPainter {
  final _DriveOverlaySnapshot snapshot;
  final bool isConnected;
  final Size sourceSize;
  final _DriveCameraKind cameraKind;
  final bool coverViewport;
  final double viewportZoom;
  final Rect? visibleViewportRect;
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
  final bool showStockTopRight;
  final bool showLaneMetrics;
  final bool showDebugPlot;
  final _DriveDebugPlotState debugPlotState;

  static const double _baseSourceWidth = 1928.0;
  static const double _baseSourceHeight = 1208.0;
  static const double _clipMargin = 500.0;

  // Keep some smoothing, but bias closer to live radar movement for lower lag.
  // Two slots: 0 = leadOne, 1 = leadTwo. Static so they persist across painter instances.
  static const double _leadEmaAlpha = 0.72;
  static const double _leadCloseEmaAlpha = 0.62;
  static const double _leadNearEmaAlpha = 0.68;
  static double _emaFx0 = 0.0, _emaFy0 = 0.0, _emaFw0 = 0.0;
  static int _emaTrackId0 = -99999;
  static double _emaFx1 = 0.0, _emaFy1 = 0.0, _emaFw1 = 0.0;
  static int _emaTrackId1 = -99999;
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
    this.viewportZoom = 1.0,
    this.visibleViewportRect,
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
    this.showStockTopRight = true,
    this.showLaneMetrics = true,
    this.showDebugPlot = true,
    this.debugPlotState = const _DriveDebugPlotState.hidden(),
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
    return _sourceToPlacedCanvasPlacement(
      source: source,
      canvas: canvas,
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
  // - _sourceToPlacedCanvasPlacement
  // - _sourceToCanvasPlacementFromDisplayTransform
  // - _buildTransform
  // - _mapToScreen
  //
  // Adaptive/responsive changes must be limited to surrounding UI shells
  // (dock/panel/popup/safe-area spacing), not these math paths.
  // -------------------------------------------------------------------------
  _SourceCanvasPlacement _sourceToPlacedCanvasPlacement({
    required Size source,
    required Size canvas,
  }) {
    final sx = canvas.width / source.width;
    final sy = canvas.height / source.height;
    final fitScale = coverViewport ? math.max(sx, sy) : math.min(sx, sy);
    final scale = fitScale;
    final drawW = source.width * scale;
    final drawH = source.height * scale;
    final dx = (canvas.width - drawW) * 0.5;
    final dy = (canvas.height - drawH) * 0.5;

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
      // The outer layout already applies annotated-camera pan/zoom by placing
      // the video surface at the resolved global rect. Reapplying x/y shift
      // inside this local canvas would move every overlay element twice.
      xOffset: 0.0,
      yOffset: 0.0,
    );
  }

  _SourceCanvasPlacement _sourceToCanvasPlacementFromDisplayTransform({
    required Size source,
    required Size canvas,
    required Map<String, dynamic>? displayTransform,
  }) {
    // `displayTransform` describes the original full-screen annotated-camera
    // placement. By the time overlay painting happens, the video surface is
    // already positioned into that resolved global rect by the outer layout,
    // so the local child canvas must only scale/crop source pixels.
    return _sourceToPlacedCanvasPlacement(
      source: source,
      canvas: canvas,
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

  List<Offset>? _mapLineToVerticalRibbonVertices(
    _ProjectionTransform transform,
    _XyzSeries line,
    double topZOff,
    double bottomZOff,
    int maxIdx, {
    bool allowInvert = true,
    double lineCenterShift = 0.0,
  }) {
    if (line.length < 2) return null;
    final top = <Offset>[];
    final bottom = <Offset>[];
    final end = math.min(maxIdx, line.length - 1);
    for (var i = 0; i <= end; i++) {
      final lx = line.x[i];
      if (!lx.isFinite || lx < 0.0) continue;
      final ly = line.y[i] + lineCenterShift;
      final lz = line.z[i];
      Offset? tp;
      Offset? bp;
      final okTop = _mapToScreen(
        transform,
        lx,
        ly,
        lz + topZOff,
        (p) => tp = p,
      );
      final okBottom = _mapToScreen(
        transform,
        lx,
        ly,
        lz + bottomZOff,
        (p) => bp = p,
      );
      if (!okTop || !okBottom || tp == null || bp == null) continue;
      if (!allowInvert && top.isNotEmpty && tp!.dy > top.last.dy) {
        continue;
      }
      top.add(tp!);
      bottom.insert(0, bp!);
    }
    if (top.length < 2 || bottom.length < 2) return null;
    return <Offset>[...top, ...bottom];
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
          dist += dist * 0.08;
          continue;
        }
        left.add(lp!);
        right.insert(0, rp!);
      }
      dist += dist * 0.08;
    }
    if (left.length < 2 || right.length < 2) return null;
    return <Offset>[...left, ...right];
  }

  /// Builds a closed polygon from [vertices] with quadratic Bezier smoothing
  /// applied independently to each edge (left: near→far, right: far→near).
  /// The vertices list is assumed to be [...leftEdge, ...rightEdge] as produced
  /// by [_mapLineToPolygonVertices] and [_mapTrackToPolygonVertices].
  /// Using straight lineTo between each vertex produces a visibly jagged polygon;
  /// the midpoint-Bezier technique rounds the corners at each vertex so the
  /// resulting path looks smooth like the native openpilot overlay.
  Path _pathFromVertices(List<Offset> vertices) {
    if (vertices.length < 3) {
      final path = Path()..moveTo(vertices.first.dx, vertices.first.dy);
      for (var i = 1; i < vertices.length; i++) {
        path.lineTo(vertices[i].dx, vertices[i].dy);
      }
      path.close();
      return path;
    }

    // Split into left edge (near → far) and right edge (far → near).
    final half = vertices.length ~/ 2;
    final left = vertices.sublist(0, half);
    final right = vertices.sublist(half);

    final path = Path()..moveTo(left.first.dx, left.first.dy);
    _addSmoothedEdge(path, left);
    // Sharp join at the far end — both sides meet here.
    path.lineTo(right.first.dx, right.first.dy);
    _addSmoothedEdge(path, right);
    path.close(); // Sharp join at the near end.
    return path;
  }

  /// Appends a quadratic-Bezier–smoothed polyline from [pts][0] to [pts][n-1]
  /// onto [path].  Caller must have already moved/linked to [pts][0].
  /// Uses the midpoint technique: for each interior vertex V_i the control point
  /// is V_i and the anchor is the midpoint of V_i → V_{i+1}, which produces a
  /// smooth C1-continuous curve through all midpoints.
  void _addSmoothedEdge(Path path, List<Offset> pts) {
    if (pts.length < 2) return;
    if (pts.length == 2) {
      path.lineTo(pts[1].dx, pts[1].dy);
      return;
    }
    for (var i = 1; i < pts.length - 1; i++) {
      final mid = Offset(
        (pts[i].dx + pts[i + 1].dx) * 0.5,
        (pts[i].dy + pts[i + 1].dy) * 0.5,
      );
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
  }

  Offset _quadraticPoint(Offset p0, Offset p1, Offset p2, double t) {
    final mt = 1.0 - t;
    final x = (mt * mt * p0.dx) + (2.0 * mt * t * p1.dx) + (t * t * p2.dx);
    final y = (mt * mt * p0.dy) + (2.0 * mt * t * p1.dy) + (t * t * p2.dy);
    return Offset(x, y);
  }

  void _appendSampledQuadratic(
    List<Offset> out, {
    required Offset start,
    required Offset control,
    required Offset end,
    required int segments,
  }) {
    final clampedSegments = segments.clamp(2, 8);
    for (var i = 1; i <= clampedSegments; i++) {
      final t = i / clampedSegments;
      final pt = _quadraticPoint(start, control, end, t);
      if (out.isEmpty || (pt - out.last).distanceSquared > 0.25) {
        out.add(pt);
      }
    }
  }

  void _appendSmoothedEdgeVertices(
    List<Offset> out,
    List<Offset> pts, {
    int baseSegments = 3,
  }) {
    if (pts.length < 2) return;
    if (out.isEmpty) {
      out.add(pts.first);
    }
    if (pts.length == 2) {
      if ((pts.last - out.last).distanceSquared > 0.25) {
        out.add(pts.last);
      }
      return;
    }
    for (var i = 1; i < pts.length - 1; i++) {
      final start = out.last;
      final control = pts[i];
      final end = Offset(
        (pts[i].dx + pts[i + 1].dx) * 0.5,
        (pts[i].dy + pts[i + 1].dy) * 0.5,
      );
      final edgeLength = (end - start).distance;
      final segments = math.max(baseSegments, (edgeLength / 22.0).round());
      _appendSampledQuadratic(
        out,
        start: start,
        control: control,
        end: end,
        segments: segments,
      );
    }
    if ((pts.last - out.last).distanceSquared > 0.25) {
      out.add(pts.last);
    }
  }

  // Native overlay payload carries polygons only, so approximate the Flutter
  // quadratic path with extra sampled vertices before serializing.
  List<Offset> _smoothedPolygonVertices(List<Offset> vertices) {
    if (vertices.length < 6) return vertices;
    final half = vertices.length ~/ 2;
    if (half < 2 || (vertices.length - half) < 2) return vertices;
    final left = vertices.sublist(0, half);
    final right = vertices.sublist(half);
    final out = <Offset>[left.first];
    _appendSmoothedEdgeVertices(out, left);
    if ((right.first - out.last).distanceSquared > 0.25) {
      out.add(right.first);
    }
    _appendSmoothedEdgeVertices(out, right);
    return out;
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
    double viewportZoom = 1.0,
    Rect? visibleViewportRect,
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
    bool showStockTopRight = true,
    bool showLaneMetrics = true,
    bool showDebugPlot = true,
    _DriveDebugPlotState debugPlotState = const _DriveDebugPlotState.hidden(),
  }) {
    final painter = _DriveOverlayPainter(
      snapshot: snapshot,
      isConnected: true,
      sourceSize: sourceSize,
      cameraKind: cameraKind,
      coverViewport: coverViewport,
      viewportZoom: viewportZoom,
      visibleViewportRect: visibleViewportRect,
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
      showStockTopRight: showStockTopRight,
      showLaneMetrics: showLaneMetrics,
      showDebugPlot: showDebugPlot,
      debugPlotState: debugPlotState,
    );
    return painter._buildNativeOverlayPayload(canvasSize);
  }

  static String buildProjectionDebugText({
    required _DriveOverlaySnapshot snapshot,
    required Size sourceSize,
    required _DriveCameraKind cameraKind,
    required Size canvasSize,
    required bool coverViewport,
    double viewportZoom = 1.0,
    required String cameraSourceLabel,
  }) {
    final painter = _DriveOverlayPainter(
      snapshot: snapshot,
      isConnected: true,
      sourceSize: sourceSize,
      cameraKind: cameraKind,
      coverViewport: coverViewport,
      viewportZoom: viewportZoom,
      visibleViewportRect: null,
      debugPlotState: const _DriveDebugPlotState.hidden(),
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
        'local canvas scale=${transform.sourceScale.toStringAsFixed(3)} '
        '(global annotated-camera pan is applied by outer video placement)';
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
        'fit=${coverViewport ? 'cover' : 'contain'} zoom=${viewportZoom.toStringAsFixed(2)} '
        'cam=${cameraKind.name} $cameraSourceLabel';
    final sidecarRoot = snapshot.sidecarOverlay2d;
    String sidecarCameraText = 'sidecar: n/a';
    String sidecarLeadText = 'lead debug: n/a';
    if (sidecarRoot != null) {
      final sidecarRootMap = Map<dynamic, dynamic>.from(sidecarRoot);
      final cameras = sidecarRootMap['cameras'];
      if (cameras is Map) {
        final selectedKey =
            cameraKind == _DriveCameraKind.wideRoad ? 'wideRoad' : 'road';
        final camRaw = cameras[selectedKey];
        if (camRaw is Map) {
          final cam = Map<String, dynamic>.from(camRaw);
          final dtRaw = cam['displayTransform'];
          final dt = dtRaw is Map ? Map<String, dynamic>.from(dtRaw) : null;
          final metaRaw = cam['meta'];
          final meta =
              metaRaw is Map ? Map<String, dynamic>.from(metaRaw) : null;
          final sidecarGap = meta == null
              ? null
              : _DriveOverlaySnapshot._asInt(meta['leadFrameGap']);
          final resetReason =
              meta == null ? null : meta['leadAnchorResetReason']?.toString();
          final cameraMode = meta == null ? null : meta['cameraMode'];
          final zoomText = dt == null
              ? '-'
              : (_DriveOverlaySnapshot._asDouble(dt['zoom'])
                      ?.toStringAsFixed(3) ??
                  '-');
          final txText = dt == null
              ? '-'
              : (_DriveOverlaySnapshot._asDouble(dt['tx'])
                      ?.toStringAsFixed(1) ??
                  '-');
          final tyText = dt == null
              ? '-'
              : (_DriveOverlaySnapshot._asDouble(dt['ty'])
                      ?.toStringAsFixed(1) ??
                  '-');
          sidecarCameraText =
              'sidecar camera=$selectedKey mode=${cameraMode ?? '-'} '
              'gap=${sidecarGap ?? '-'} reset=${(resetReason == null || resetReason.trim().isEmpty) ? '-' : resetReason} '
              'zoom=$zoomText tx=$txText ty=$tyText';
          final leadRaw = cam['leadAreaBoxes'];
          if (leadRaw is List && leadRaw.isNotEmpty) {
            final leadDebug = <String>[];
            for (final item in leadRaw) {
              if (item is! Map) continue;
              final lead = Map<String, dynamic>.from(item);
              final kind = lead['kind']?.toString() ?? 'lead';
              final centerRaw = lead['anchorCenter'];
              final width =
                  _DriveOverlaySnapshot._asDouble(lead['anchorWidth']);
              final topY = _DriveOverlaySnapshot._asDouble(lead['boxTopY']);
              final bottomY =
                  _DriveOverlaySnapshot._asDouble(lead['boxBottomY']);
              String centerText = '-';
              if (centerRaw is List && centerRaw.length >= 2) {
                final cx = _DriveOverlaySnapshot._asDouble(centerRaw[0]);
                final cy = _DriveOverlaySnapshot._asDouble(centerRaw[1]);
                if (cx != null && cy != null) {
                  centerText =
                      '${cx.toStringAsFixed(1)},${cy.toStringAsFixed(1)}';
                }
              }
              leadDebug.add(
                '$kind c=[$centerText] w=${width?.toStringAsFixed(1) ?? '-'} '
                'top=${topY?.toStringAsFixed(1) ?? '-'} bot=${bottomY?.toStringAsFixed(1) ?? '-'} '
                'lat=${lead['lateralSource'] ?? '-'} '
                'rb=${lead['radarBadgeCenter'] is List ? 'y' : 'n'} '
                'vb=${lead['visionBadgeCenter'] is List ? 'y' : 'n'} '
                'st=${lead['stateTextCenter'] is List ? 'y' : 'n'}',
              );
            }
            if (leadDebug.isNotEmpty) {
              sidecarLeadText = 'lead debug: ${leadDebug.join(' | ')}';
            }
          }
        }
      }
    }

    return <String>[
      '[Projection Verify]',
      sourceText,
      frameText,
      sidecarCameraText,
      sidecarLeadText,
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

  Map<String, dynamic>? _buildNativeOverlayPayload(Size size) {
    final transform = _buildTransform(size);
    final polygons = <Map<String, dynamic>>[];
    final gradients = <Map<String, dynamic>>[];
    List<Map<String, dynamic>>? labels;

    List<Offset>? trackVertices;
    if (snapshot.path.length >= 2) {
      final sceneMaxDistance = _sceneMaxDistanceForOverlay();
      final pathMaxDistance = _pathMaxDistanceForOverlay(sceneMaxDistance);
      final laneBaseX = snapshot.laneLines.isNotEmpty
          ? snapshot.laneLines.first.line.x
          : snapshot.path.x;
      final laneMaxIdx = laneBaseX.isNotEmpty
          ? _getPathLengthIdx(laneBaseX, sceneMaxDistance)
          : _getPathLengthIdx(snapshot.path.x, sceneMaxDistance);

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
            _smoothedPolygonVertices(poly),
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
                _smoothedPolygonVertices(doublePoly),
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
          polygons.add(
            _encodePolygon(
              _smoothedPolygonVertices(poly),
              _roadEdgeColor(edge.std),
            ),
          );
        }
      }

      _appendBlindSpotBarrierPolygons(
        transform: transform,
        polygons: polygons,
      );

      final pathMode = snapshot.pathMode;
      final widthApply =
          _pathHalfWidthByMode(pathMode, snapshot.pathWidthRatio);
      final zOff = snapshot.pathOffsetZ.isFinite ? snapshot.pathOffsetZ : 1.22;
      final startDistance = snapshot.active ? 2.0 : 3.5;
      trackVertices = _mapLineToTrackVerticesDist(
        transform,
        snapshot.path,
        widthApply,
        zOff,
        zOff,
        pathMaxDistance,
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

      final usedSidecarTfMarker = _appendPreferredTfMarker(
        canvasSize: size,
        polygons: polygons,
        labels: labels ??= <Map<String, dynamic>>[],
      );
      if (!usedSidecarTfMarker) {
        _appendProjectedTfMarker(
          transform: transform,
          canvasSize: size,
          polygons: polygons,
          labels: labels,
        );
      }
      final usedSidecarLeadRadar = _appendPreferredLeadAndRadarPolygons(
        canvasSize: size,
        polygons: polygons,
        labels: labels,
      );
      if (!usedSidecarLeadRadar) {
        _appendProjectedLeadAndRadarPolygons(
          transform: transform,
          canvasSize: size,
          polygons: polygons,
          labels: labels,
        );
      }
    }
    _appendViewportFadeGradients(
      gradients,
      canvasSize: size,
    );
    labels ??= <Map<String, dynamic>>[];
    if (showLaneMetrics) {
      _appendLaneDebugMetricsLabel(
        canvasSize: size,
        labels: labels,
      );
    }
    if (showStockTopRight) {
      _appendStockDebugTopRightLabel(
        canvasSize: size,
        labels: labels,
      );
    }
    if (showDebugPlot) {
      _appendDebugPlotPayload(
        polygons,
        labels,
        canvasSize: size,
      );
    }
    if (labels.isEmpty) labels = null;

    if (showDebugGuides) {
      _appendDebugGuidePolygons(
        polygons,
        canvasSize: size,
        transform: transform,
        trackVertices: trackVertices,
      );
      labels ??= <Map<String, dynamic>>[];
      labels.addAll(_buildDebugGridLabels(canvasSize: size));
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
      if (gradients.isNotEmpty) 'gradients': gradients,
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
    final encodedVertices = _smoothedPolygonVertices(vertices);
    out.add(
      _encodePolygon(
        encodedVertices,
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
    Color? strokeColor,
    double strokeWidth = 0.0,
    double size = 20.0,
    bool centered = true,
    int fontWeight = 700,
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
      if (strokeColor != null) 'strokeColor': strokeColor.toARGB32(),
      if (strokeColor != null && strokeWidth > 0.0) 'strokeWidth': strokeWidth,
      'size': size,
      'fontWeight': fontWeight,
    });
  }

  double _fitSingleLineOverlayFontSize({
    required String text,
    required double preferredSize,
    required double maxWidth,
    double minSize = 4.5,
    double charWidthFactor = 0.64,
  }) {
    final content = text.trim();
    if (content.isEmpty) return preferredSize;
    final estimatedWidth =
        math.max(1.0, content.length * preferredSize * charWidthFactor);
    if (estimatedWidth <= maxWidth) {
      return preferredSize;
    }
    final scaled = preferredSize * ((maxWidth / estimatedWidth) * 0.985);
    return _clampDouble(scaled, minSize, preferredSize);
  }

  Rect _resolvedOverlayViewportRect(Size canvasSize) {
    final full = Offset.zero & canvasSize;
    final candidate = (visibleViewportRect ?? full).intersect(full);
    if (candidate.width < 80.0 || candidate.height < 60.0) {
      return full;
    }
    return candidate;
  }

  void _appendViewportFadeGradients(
    List<Map<String, dynamic>> gradients, {
    required Size canvasSize,
  }) {
    final viewportRect = _resolvedOverlayViewportRect(canvasSize);
    if (viewportRect.width < 40.0 || viewportRect.height < 40.0) return;

    final topHeight =
        (viewportRect.height * 0.17).clamp(52.0, 124.0).toDouble();
    final bottomHeight =
        (viewportRect.height * 0.23).clamp(72.0, 184.0).toDouble();

    void appendGradientRect({
      required bool top,
      required double fadeHeight,
      required double edgeAlpha,
      required double centerAlpha,
    }) {
      const left = 0.0;
      final right = canvasSize.width;
      final topY = top ? viewportRect.top : viewportRect.bottom - fadeHeight;
      final bottomY = top ? viewportRect.top + fadeHeight : viewportRect.bottom;
      gradients.add(<String, dynamic>{
        'left': left,
        'top': topY,
        'right': right,
        'bottom': bottomY,
        'startX': left,
        'startY': top ? topY : bottomY,
        'endX': left,
        'endY': top ? bottomY : topY,
        'colors': <int>[
          Colors.black.withValues(alpha: edgeAlpha).toARGB32(),
          Colors.black.withValues(alpha: centerAlpha).toARGB32(),
          Colors.transparent.toARGB32(),
        ],
        'stops': const <double>[0.0, 0.42, 1.0],
      });
    }

    appendGradientRect(
      top: true,
      fadeHeight: topHeight,
      edgeAlpha: 0.52,
      centerAlpha: 0.18,
    );
    appendGradientRect(
      top: false,
      fadeHeight: bottomHeight,
      edgeAlpha: 0.66,
      centerAlpha: 0.24,
    );
  }

  String _formatTfMarkerText(double distance, double tFollow) {
    return '${distance.toStringAsFixed(1)}(${tFollow.toStringAsFixed(2)})';
  }

  Offset _clampTfMarkerLabelAnchor({
    required Size canvasSize,
    required Offset lineRight,
    required double sourceScale,
    required String text,
    required double fontSize,
  }) {
    final margin = _clampDouble(10.0 * sourceScale, 8.0, 18.0);
    final dx = _clampDouble(11.0 * sourceScale, 8.0, 16.0);
    final dy = _clampDouble(4.0 * sourceScale, 2.0, 8.0);
    final estimatedWidth = math.max(
      48.0,
      text.length * fontSize * 0.56,
    );
    final maxX = math.max(margin, canvasSize.width - estimatedWidth - margin);
    final minY = margin + fontSize;
    final maxY = math.max(minY, canvasSize.height - margin);
    return Offset(
      (lineRight.dx + dx).clamp(margin, maxX).toDouble(),
      (lineRight.dy + dy).clamp(minY, maxY).toDouble(),
    );
  }

  void _appendStockDebugTopRightLabel({
    required Size canvasSize,
    required List<Map<String, dynamic>> labels,
  }) {
    final text = snapshot.stockDebugTopRightText
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (text.isEmpty) return;
    final exactC3Mode =
        canvasSize.width >= 1280.0 && canvasSize.height >= 720.0;
    final baseScale = math.min(
      canvasSize.width / 1920.0,
      canvasSize.height / 1080.0,
    );
    final viewportRect = _resolvedOverlayViewportRect(canvasSize);
    final scale = _clampDouble(baseScale, 0.48, 1.0);
    final edgeInsetX = exactC3Mode ? 1.5 : _clampDouble(2.0 * scale, 1.0, 2.5);
    final edgeInsetTop =
        exactC3Mode ? 1.5 : _clampDouble(2.0 * scale, 1.0, 2.5);
    final maxWidth = math.max(120.0, viewportRect.width - (edgeInsetX * 2.0));
    final preferredFontSize =
        exactC3Mode ? 24.0 : _clampDouble(24.0 * scale, 7.0, 24.0);
    final fontSize = _fitSingleLineOverlayFontSize(
      text: text,
      preferredSize: preferredFontSize,
      maxWidth: maxWidth,
      minSize: 4.5,
      charWidthFactor: 0.69,
    );
    final labelAlpha = _overlayPhaseLabelAlpha(phaseShift: 0.0);
    labels.add(<String, dynamic>{
      'x': viewportRect.right - edgeInsetX,
      'y': viewportRect.top + edgeInsetTop,
      'text': text,
      'color': const Color(0xFFF4F4F4).withValues(alpha: labelAlpha).toARGB32(),
      'strokeColor': const Color(0xEE000000)
          .withValues(alpha: _clampDouble(labelAlpha + 0.08, 0.0, 1.0))
          .toARGB32(),
      'strokeWidth': _clampDouble(4.2 * scale, 2.8, 5.4),
      'size': fontSize,
      'fontWeight': 900,
      'alignX': 'right',
      'alignY': 'top',
      'maxWidth': maxWidth,
      'maxLines': 1,
    });
  }

  double _overlayPhaseLabelAlpha({required double phaseShift}) {
    if (snapshot.pathMode < 1 || snapshot.pathMode > 8) {
      return 0.94;
    }
    final wave =
        (math.sin((snapshot.animationPhase * 0.78) + phaseShift) + 1.0) * 0.5;
    final eased = math.pow(wave, 1.7).toDouble();
    return _clampDouble(0.14 + (eased * 0.86), 0.14, 1.0);
  }

  bool _hasNearbyAssistLead(_RadarLeadSample? lead, double speedMps) {
    if (!speedMps.isFinite || speedMps <= 0.0) {
      return false;
    }
    final threshold = speedMps * 3.0;
    if (threshold <= 0.0) return false;
    if (lead != null && lead.status && lead.dRel.isFinite) {
      return lead.dRel > 0.0 && lead.dRel < threshold;
    }
    return false;
  }

  String _laneDebugText() {
    final raw = snapshot.latDebugText.trim();
    final modeText = snapshot.useLaneLineSpeed > 0 ? 'LaneMode' : 'Laneless';
    if (raw.isEmpty) return modeText;
    final normalized = raw.toLowerCase();
    if (normalized.startsWith('lanemode') ||
        normalized.startsWith('laneless')) {
      return raw;
    }
    return '$modeText | $raw';
  }

  void _appendBlindSpotBarrierPolygons({
    required _ProjectionTransform transform,
    required List<Map<String, dynamic>> polygons,
  }) {
    if (cameraKind != _DriveCameraKind.road) return;
    final laneChangeState = snapshot.laneChangeState;
    final laneChangeDirection = snapshot.laneChangeDirection;
    final preLaneChange = laneChangeState == 1;
    final leftAssistWarn = !snapshot.leftBlindspot &&
        preLaneChange &&
        laneChangeDirection == 1 &&
        _hasNearbyAssistLead(snapshot.leadLeft, snapshot.speedMps ?? 0.0);
    final rightAssistWarn = !snapshot.rightBlindspot &&
        preLaneChange &&
        laneChangeDirection == 2 &&
        _hasNearbyAssistLead(snapshot.leadRight, snapshot.speedMps ?? 0.0);
    if (!snapshot.leftBlindspot &&
        !snapshot.rightBlindspot &&
        !leftAssistWarn &&
        !rightAssistWarn) {
      return;
    }
    final centerLine = snapshot.modelPath;
    if (centerLine.length < 2) return;
    final maxIdx = _getPathLengthIdx(centerLine.x, 40.0);
    const goldFillColor = Color(0x7AFFD700);
    const goldStrokeColor = Color(0xD6FFD700);
    const greenFillColor = Color(0x7800CC00);
    const greenStrokeColor = Color(0xD000CC00);

    void appendRibbon(double shift, Color fillColor, Color strokeColor) {
      final vertices = _mapLineToVerticalRibbonVertices(
        transform,
        centerLine,
        1.15,
        0.60,
        maxIdx,
        allowInvert: false,
        lineCenterShift: shift,
      );
      if (vertices == null || vertices.length < 8) return;
      final count = vertices.length;
      for (var i = 0; i < (count ~/ 2) - 2; i += 2) {
        polygons.add(
          _encodePolygon(
            <Offset>[
              vertices[i + 0],
              vertices[i + 1],
              vertices[count - i - 3],
              vertices[count - i - 2],
            ],
            fillColor,
            strokeColor: strokeColor,
            strokeWidth: 1.2,
          ),
        );
      }
    }

    if (snapshot.leftBlindspot) {
      appendRibbon(-1.7, goldFillColor, goldStrokeColor);
    } else if (leftAssistWarn) {
      appendRibbon(-1.7, greenFillColor, greenStrokeColor);
    }
    if (snapshot.rightBlindspot) {
      appendRibbon(1.7, goldFillColor, goldStrokeColor);
    } else if (rightAssistWarn) {
      appendRibbon(1.7, greenFillColor, greenStrokeColor);
    }
  }

  void _appendLaneDebugMetricsLabel({
    required Size canvasSize,
    required List<Map<String, dynamic>> labels,
  }) {
    if (!isConnected || cameraKind != _DriveCameraKind.road) return;
    final text = _laneDebugText();
    if (text.isEmpty) return;
    final exactC3Mode =
        canvasSize.width >= 1280.0 && canvasSize.height >= 720.0;
    final baseScale = math.min(
      canvasSize.width / 1920.0,
      canvasSize.height / 1080.0,
    );
    final viewportRect = _resolvedOverlayViewportRect(canvasSize);
    final scale = _clampDouble(baseScale, 0.48, 1.0);
    final maxWidth = math.max(120.0, viewportRect.width - 4.0);
    final preferredFontSize =
        exactC3Mode ? 24.0 : _clampDouble(24.0 * scale, 7.0, 24.0);
    final fontSize = _fitSingleLineOverlayFontSize(
      text: text,
      preferredSize: preferredFontSize,
      maxWidth: maxWidth,
      minSize: 4.5,
      charWidthFactor: 0.69,
    );
    final bottomInset = exactC3Mode ? 1.5 : _clampDouble(2.0 * scale, 1.0, 2.5);
    final labelAlpha = _overlayPhaseLabelAlpha(phaseShift: math.pi);
    labels.add(<String, dynamic>{
      'x': viewportRect.center.dx,
      'y': viewportRect.bottom - bottomInset,
      'text': text,
      'color': const Color(0xFFECECEC).withValues(alpha: labelAlpha).toARGB32(),
      'strokeColor': const Color(0xF0000000)
          .withValues(alpha: _clampDouble(labelAlpha + 0.08, 0.0, 1.0))
          .toARGB32(),
      'strokeWidth': _clampDouble(4.0 * scale, 2.8, 5.2),
      'size': fontSize,
      'fontWeight': 900,
      'alignX': 'center',
      'alignY': 'baselineBottom',
      'maxWidth': maxWidth,
      'maxLines': 1,
    });
  }

  void _appendProjectedTfMarker({
    required _ProjectionTransform transform,
    required Size canvasSize,
    required List<Map<String, dynamic>> polygons,
    required List<Map<String, dynamic>> labels,
  }) {
    if (!showStopDistanceTf) return;
    final tfDistance = snapshot.desiredDistance;
    if (!tfDistance.isFinite || tfDistance <= 0.0) return;
    final centerLine = snapshot.modelPath;
    if (centerLine.length < 2) return;
    final xs = _monotonicX(
      centerLine.x.take(centerLine.length).toList(growable: false),
    );
    if (xs.length < 2) return;
    final ys = centerLine.y.take(centerLine.length).toList(growable: false);
    final zs = centerLine.z.take(centerLine.length).toList(growable: false);
    final idxs =
        List<double>.generate(xs.length, (i) => i.toDouble(), growable: false);
    final dist = tfDistance.clamp(0.0, xs.last);
    final idx = _interp1D(dist, xs, idxs);
    if (!idx.isFinite || idx >= (xs.length - 1)) return;
    final lineY = _interp1D(idx, idxs, ys);
    final lineZ = _interp1D(idx, idxs, zs);
    Offset? left;
    Offset? right;
    final okL = _mapToScreen(
      transform,
      dist,
      lineY - 1.0,
      lineZ + 1.22,
      (p) => left = p,
    );
    final okR = _mapToScreen(
      transform,
      dist,
      lineY + 1.0,
      lineZ + 1.22,
      (p) => right = p,
    );
    if (!okL || !okR || left == null || right == null) return;
    final sourceScale =
        transform.sourceScale.isFinite && transform.sourceScale > 0.0
            ? transform.sourceScale
            : 1.0;
    _appendDebugLinePolygon(
      polygons,
      a: left!,
      b: right!,
      color: Colors.white,
      thickness: _clampDouble(3.0 * sourceScale, 2.4, 4.2),
    );
    final labelText = _formatTfMarkerText(
      snapshot.desiredDistance,
      snapshot.tFollow,
    );
    final labelSize = _clampDouble(20.0 * sourceScale, 16.0, 24.0);
    final labelAnchor = _clampTfMarkerLabelAnchor(
      canvasSize: canvasSize,
      lineRight: right!,
      sourceScale: sourceScale,
      text: labelText,
      fontSize: labelSize,
    );
    _appendOverlayLabel(
      labels,
      anchor: labelAnchor,
      text: labelText,
      color: Colors.white,
      strokeColor: Colors.black,
      strokeWidth: 1.8,
      size: labelSize,
      centered: false,
    );
  }

  void _appendBadge(
    List<Map<String, dynamic>> polygons,
    List<Map<String, dynamic>> labels, {
    required Offset center,
    required String text,
    required Color fillColor,
    required Color textColor,
    Color? strokeColor,
    Color? textStrokeColor,
    double textStrokeWidth = 0.0,
    double fontSize = 22.0,
    double minWidth = 56.0,
    double height = 42.0,
    double radius = 15.0,
    double strokeWidth = 2.0,
    double horizontalPadding = 18.0,
    int fontWeight = 700,
  }) {
    final content = text.trim();
    if (content.isEmpty || !center.dx.isFinite || !center.dy.isFinite) return;
    final width = math
        .max(minWidth, (content.length * fontSize * 0.60) + horizontalPadding)
        .toDouble();
    final left = center.dx - (width * 0.5);
    final top = center.dy - (height * 0.5);
    final right = left + width;
    final bottom = top + height;
    polygons.add(
      _encodePolygon(
        _roundedRectVertices(
          Rect.fromLTRB(left, top, right, bottom),
          radius: radius,
          segmentsPerCorner: 5,
        ),
        fillColor,
        strokeColor: strokeColor,
        strokeWidth: strokeColor == null ? 0.0 : strokeWidth,
      ),
    );
    _appendOverlayLabel(
      labels,
      anchor: Offset(center.dx, top + (height * 0.70)),
      text: content,
      color: textColor,
      strokeColor: textStrokeColor,
      strokeWidth: textStrokeWidth,
      size: fontSize,
      centered: true,
      fontWeight: fontWeight,
    );
  }

  double _leadBoxCornerRadius(double sourceScale) {
    return _clampDouble(11.0 * sourceScale, 8.0, 12.0);
  }

  double _leadBoxStrokeWidth(double sourceScale) {
    return _clampDouble(2.0 * sourceScale, 1.6, 2.4);
  }

  double _leadBadgeRadius(double sourceScale) {
    return _clampDouble(18.0 * sourceScale, 14.0, 20.0);
  }

  double _leadBadgeStrokeWidth(double sourceScale) {
    return _clampDouble(2.2 * sourceScale, 1.8, 2.8);
  }

  _LeadDistanceBadgeLayout _leadDistanceBadgeLayout(
    Rect rect,
    double sourceScale,
  ) {
    final height = _clampDouble(26.0 * sourceScale, 22.0, 30.0);
    final fontSize = _clampDouble(21.0 * sourceScale, 18.0, 24.0);
    final minWidth = _clampDouble(46.0 * sourceScale, 40.0, 56.0);
    final attachOverlap = _clampDouble(4.0 * sourceScale, 3.0, 5.0);
    return _LeadDistanceBadgeLayout(
      center: Offset(
        rect.center.dx,
        rect.bottom + (height * 0.5) - attachOverlap,
      ),
      fontSize: fontSize,
      minWidth: minWidth,
      height: height,
    );
  }

  _LeadDistanceBadgeLayout _leadStateBadgeLayout(
    Rect rect,
    double sourceScale,
  ) {
    final height = _clampDouble(44.0 * sourceScale, 38.0, 50.0);
    final fontSize = _clampDouble(25.0 * sourceScale, 21.0, 30.0);
    final minWidth = _clampDouble(132.0 * sourceScale, 108.0, 176.0);
    final attachOverlap = _clampDouble(5.0 * sourceScale, 4.0, 7.0);
    return _LeadDistanceBadgeLayout(
      center: Offset(
        rect.center.dx,
        rect.bottom + (height * 0.5) - attachOverlap,
      ),
      fontSize: fontSize,
      minWidth: minWidth,
      height: height,
    );
  }

  Color _leadCardFillColor(
    Color accent,
    Color baseFill, {
    required bool primary,
  }) {
    final darkBase = Colors.black.withValues(alpha: primary ? 0.055 : 0.045);
    final tintedBase = Color.alphaBlend(
      accent.withValues(alpha: primary ? 0.028 : 0.022),
      darkBase,
    );
    return Color.alphaBlend(
      baseFill.withValues(alpha: primary ? 0.022 : 0.018),
      tintedBase,
    );
  }

  void _appendLeadBoxCard(
    List<Map<String, dynamic>> polygons, {
    required Rect rect,
    required double sourceScale,
    required Color strokeColor,
    required Color fillColor,
    required bool primary,
  }) {
    final cornerRadius = _leadBoxCornerRadius(sourceScale);
    final shadowShiftY = _clampDouble(5.0 * sourceScale, 3.0, 7.0);
    final shadowInflate = _clampDouble(2.5 * sourceScale, 1.5, 3.5);
    final glowInflate = _clampDouble(8.0 * sourceScale, 5.0, 10.0);
    final innerInset = _clampDouble(4.0 * sourceScale, 2.5, 5.5);

    polygons.add(
      _encodePolygon(
        _roundedRectVertices(
          rect.shift(Offset(0.0, shadowShiftY)).inflate(shadowInflate),
          radius: cornerRadius + shadowShiftY,
          segmentsPerCorner: 4,
        ),
        const Color(0x22000000),
      ),
    );
    polygons.add(
      _encodePolygon(
        _roundedRectVertices(
          rect.inflate(glowInflate),
          radius: cornerRadius + glowInflate,
          segmentsPerCorner: 4,
        ),
        strokeColor.withValues(alpha: primary ? 0.13 : 0.09),
      ),
    );
    polygons.add(
      _encodePolygon(
        _roundedRectVertices(
          rect,
          radius: cornerRadius,
          segmentsPerCorner: 4,
        ),
        _leadCardFillColor(
          strokeColor,
          fillColor,
          primary: primary,
        ),
        strokeColor: strokeColor,
        strokeWidth: _leadBoxStrokeWidth(sourceScale),
      ),
    );

    final innerRect = rect.deflate(innerInset);
    if (innerRect.width > 18.0 && innerRect.height > 18.0) {
      polygons.add(
        _encodePolygon(
          _roundedRectVertices(
            innerRect,
            radius: math.max(2.0, cornerRadius - innerInset),
            segmentsPerCorner: 4,
          ),
          Colors.white.withValues(alpha: primary ? 0.012 : 0.008),
          strokeColor: Colors.white.withValues(alpha: primary ? 0.08 : 0.05),
          strokeWidth: _clampDouble(1.0 * sourceScale, 0.8, 1.2),
        ),
      );
    }
  }

  void _appendLeadDistanceBadge(
    List<Map<String, dynamic>> polygons,
    List<Map<String, dynamic>> labels, {
    required _LeadDistanceBadgeLayout layout,
    required double sourceScale,
    required String text,
    required Color accentColor,
    required Color textColor,
  }) {
    final fillColor = Color.alphaBlend(
      accentColor.withValues(alpha: 0.92),
      const Color(0xFF0F141B),
    );
    _appendBadge(
      polygons,
      labels,
      center: layout.center,
      text: text,
      fillColor: fillColor,
      textColor: textColor,
      strokeColor: Colors.black.withValues(alpha: 0.96),
      textStrokeColor: Colors.black,
      textStrokeWidth: 2.6,
      fontSize: layout.fontSize,
      minWidth: layout.minWidth,
      height: layout.height,
      radius: _leadBadgeRadius(sourceScale),
      strokeWidth: _clampDouble(2.8 * sourceScale, 2.2, 3.4),
      horizontalPadding: _clampDouble(10.0 * sourceScale, 8.0, 12.0),
      fontWeight: 900,
    );
  }

  Color _leadStateAccentColor(int xState) {
    switch (xState) {
      case 3:
      case 5:
        return const Color(0xFFFFA726);
      case 4:
        return const Color(0xFF23D55D);
      case 1:
        return const Color(0xFF91A4BF);
      default:
        return Colors.white;
    }
  }

  void _appendLeadStateBadge(
    List<Map<String, dynamic>> polygons,
    List<Map<String, dynamic>> labels, {
    required Rect rect,
    required double sourceScale,
    required int xState,
    required String text,
  }) {
    final layout = _leadStateBadgeLayout(rect, sourceScale);
    final accentColor = _leadStateAccentColor(xState);
    final fillColor = Color.alphaBlend(
      accentColor.withValues(alpha: 0.18),
      const Color(0xE610151C),
    );
    _appendBadge(
      polygons,
      labels,
      center: layout.center,
      text: text,
      fillColor: fillColor,
      textColor: Colors.white,
      strokeColor: accentColor.withValues(alpha: 0.82),
      textStrokeColor: Colors.black,
      textStrokeWidth: 1.9,
      fontSize: layout.fontSize,
      minWidth: layout.minWidth,
      height: layout.height,
      radius: _leadBadgeRadius(sourceScale),
      strokeWidth: _leadBadgeStrokeWidth(sourceScale),
    );
  }

  void _appendRadarSpeedBadge(
    List<Map<String, dynamic>> polygons,
    List<Map<String, dynamic>> labels, {
    required Offset center,
    required double sourceScale,
    required String text,
    required Color accentColor,
  }) {
    final fillColor = Color.alphaBlend(
      accentColor.withValues(alpha: 0.76),
      const Color(0xFF10161E),
    );
    _appendBadge(
      polygons,
      labels,
      center: center,
      text: text,
      fillColor: fillColor,
      textColor: Colors.white,
      strokeColor: Colors.white.withValues(alpha: 0.24),
      textStrokeColor: Colors.black,
      textStrokeWidth: 1.8,
      fontSize: _clampDouble(24.0 * sourceScale, 21.0, 28.0),
      minWidth: _clampDouble(62.0 * sourceScale, 54.0, 72.0),
      height: _clampDouble(42.0 * sourceScale, 36.0, 46.0),
      radius: _clampDouble(16.0 * sourceScale, 13.0, 18.0),
      strokeWidth: _leadBadgeStrokeWidth(sourceScale),
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
    required bool showStateText,
  }) {
    final cameraFrameId = _DriveOverlaySnapshot._asInt(cam['cameraFrameId']);
    final modelFrameId = _DriveOverlaySnapshot._asInt(cam['modelFrameId']);
    final frameGap = (cameraFrameId != null && modelFrameId != null)
        ? (modelFrameId - cameraFrameId).abs()
        : null;
    // Stock lead/radar box parity is more important than showing stale boxes.
    // When model/camera frames drift too far apart, skip the decorations.
    if (frameGap != null && frameGap > 3) {
      return;
    }

    final meta = cam['meta'];
    final showRadarInfo = meta is Map
        ? (_DriveOverlaySnapshot._asInt(meta['showRadarInfo']) ?? 0)
        : 0;
    final xState = meta is Map
        ? (_DriveOverlaySnapshot._asInt(meta['xState']) ?? snapshot.xState)
        : snapshot.xState;
    final trafficState = meta is Map
        ? (_DriveOverlaySnapshot._asInt(meta['trafficState']) ??
            snapshot.trafficState)
        : snapshot.trafficState;
    final longActive = meta is Map
        ? _boolFromDynamic(meta['longActive'], fallback: snapshot.longActive)
        : snapshot.longActive;
    final vEgoMps = meta is Map
        ? (_DriveOverlaySnapshot._asDouble(meta['vEgoMps']) ??
            (snapshot.speedMps ?? 0.0))
        : (snapshot.speedMps ?? 0.0);

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
    final sourceScale = _sourceToCanvasPlacementFromDisplayTransform(
      source: Size(sourceWidth, sourceHeight),
      canvas: canvasSize,
      displayTransform: displayTransform,
    ).scale;

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
        _appendLeadBoxCard(
          polygons,
          rect: bounds,
          sourceScale: sourceScale,
          strokeColor: strokeColor,
          fillColor: fillColor,
          primary: kind == 'leadOne',
        );

        if (kind == 'leadOne') {
          final radarDist =
              _DriveOverlaySnapshot._asDouble(lead['radarDistance']) ?? 0.0;
          final visionDist =
              _DriveOverlaySnapshot._asDouble(lead['visionDistance']) ?? 0.0;
          final radarBadgeColorArgb =
              _DriveOverlaySnapshot._asInt(lead['radarBadgeColorArgb']);
          final visionBadgeColorArgb =
              _DriveOverlaySnapshot._asInt(lead['visionBadgeColorArgb']);
          final badgeLayout = _leadDistanceBadgeLayout(bounds, sourceScale);
          final hasRadarDistance = radarDist > 0.0;
          final hasVisionDistance = visionDist > 0.0;
          final primaryDistance = hasRadarDistance
              ? radarDist
              : (hasVisionDistance ? visionDist : 0.0);
          final primaryBadgeColor = hasRadarDistance
              ? (radarBadgeColorArgb != null
                  ? Color(radarBadgeColorArgb)
                  : (isLeadScc
                      ? const Color(0xFFFF3B30)
                      : const Color(0xFFFFA726)))
              : (visionBadgeColorArgb != null
                  ? Color(visionBadgeColorArgb)
                  : const Color(0xFF3D7BFF));
          if (drawDistanceBadges && showRadarBadge && primaryDistance > 0.0) {
            _appendLeadDistanceBadge(
              polygons,
              labels,
              layout: badgeLayout,
              sourceScale: sourceScale,
              text: primaryDistance.toStringAsFixed(1),
              accentColor: primaryBadgeColor,
              textColor: badgeTextColor,
            );
          }
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
      if (leadOneAnchorRaw is Map) {
        final mapped = _mapSourcePointsToCanvas(
          _decodeOverlayPoints(leadOneAnchorRaw['points']),
          canvasSize: canvasSize,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          displayTransform: displayTransform,
        );
        final bounds = mapped.length >= 3 ? _verticesBounds(mapped) : null;
        if (bounds != null) {
          _appendLeadStateBadge(
            polygons,
            labels,
            rect: bounds,
            sourceScale: sourceScale,
            xState: xState,
            text: stateText,
          );
        }
      }
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
        _appendRadarSpeedBadge(
          polygons,
          labels,
          center: Offset(center.dx, center.dy - (18.0 * sourceScale)),
          sourceScale: sourceScale,
          text: speedKph.toStringAsFixed(0),
          accentColor: badgeColor,
        );
        if (showRadarInfo >= 2) {
          _appendOverlayLabel(
            labels,
            anchor: Offset(center.dx, center.dy - (48.0 * sourceScale)),
            text: yRel.toStringAsFixed(1),
            color: Colors.white,
            strokeColor: Colors.black,
            strokeWidth: 1.4,
            size: _clampDouble(18.0 * sourceScale, 16.0, 21.0),
            centered: true,
          );
          _appendOverlayLabel(
            labels,
            anchor: Offset(center.dx, center.dy + (30.0 * sourceScale)),
            text: dRel.toStringAsFixed(1),
            color: Colors.white,
            strokeColor: Colors.black,
            strokeWidth: 1.4,
            size: _clampDouble(18.0 * sourceScale, 16.0, 21.0),
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

  void _appendSidecarTfMarker({
    required Map<String, dynamic> cam,
    required Size canvasSize,
    required double sourceWidth,
    required double sourceHeight,
    required Map<String, dynamic>? displayTransform,
    required List<Map<String, dynamic>> polygons,
    required List<Map<String, dynamic>> labels,
    required bool showStopDistanceTf,
  }) {
    final tfRaw = cam['tfMarker'];
    if (!showStopDistanceTf || tfRaw is! Map) return;
    final sourceScale = _sourceToCanvasPlacementFromDisplayTransform(
      source: Size(sourceWidth, sourceHeight),
      canvas: canvasSize,
      displayTransform: displayTransform,
    ).scale;
    final tf = Map<String, dynamic>.from(tfRaw);
    final mapped = _mapSourcePointsToCanvas(
      _decodeOverlayPoints(tf['points']),
      canvasSize: canvasSize,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      displayTransform: displayTransform,
    );
    if (mapped.length < 2) return;
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
    if (dist <= 0.0) return;
    final labelText = _formatTfMarkerText(dist, tFollow);
    final labelSize = _clampDouble(20.0 * sourceScale, 16.0, 24.0);
    final labelAnchor = _clampTfMarkerLabelAnchor(
      canvasSize: canvasSize,
      lineRight: right,
      sourceScale: sourceScale,
      text: labelText,
      fontSize: labelSize,
    );
    _appendOverlayLabel(
      labels,
      anchor: labelAnchor,
      text: labelText,
      color: Colors.white,
      strokeColor: Colors.black,
      strokeWidth: 1.8,
      size: labelSize,
      centered: false,
    );
  }

  double _sampleModelZAtDistance(double distance) {
    final modelPath =
        snapshot.modelPath.length >= 2 ? snapshot.modelPath : snapshot.path;
    if (modelPath.length < 2) return 0.0;
    final xs =
        _monotonicX(modelPath.x.take(modelPath.length).toList(growable: false));
    if (xs.isEmpty) return 0.0;
    final zs = modelPath.z.take(modelPath.length).toList(growable: false);
    final idxs = List<double>.generate(
      modelPath.length,
      (i) => i.toDouble(),
      growable: false,
    );
    final idx = _interp1D(distance, xs, idxs);
    return _interp1D(idx, idxs, zs);
  }

  double _sampleRadarZAtDistance(double distance) {
    if (snapshot.laneLines.length >= 3) {
      final lane = snapshot.laneLines[2].line;
      if (lane.length >= 2) {
        final xs =
            _monotonicX(lane.x.take(lane.length).toList(growable: false));
        if (xs.isNotEmpty) {
          final zs = lane.z.take(lane.length).toList(growable: false);
          final idxs = List<double>.generate(
            lane.length,
            (i) => i.toDouble(),
            growable: false,
          );
          final idx = _interp1D(distance, xs, idxs);
          return _interp1D(idx, idxs, zs);
        }
      }
    }
    return _sampleModelZAtDistance(distance);
  }

  double _sceneMaxDistanceForOverlay() {
    final modelMax = snapshot.path.x.isNotEmpty ? snapshot.path.x.last : 0.0;
    var maxDistance = modelMax.clamp(10.0, 100.0).toDouble();
    final leadOne = snapshot.leadOne;
    if (leadOne != null &&
        leadOne.status &&
        leadOne.dRel.isFinite &&
        leadOne.dRel > 0.0) {
      maxDistance = math.min(maxDistance, leadOne.dRel);
    }
    return maxDistance;
  }

  double _pathMaxDistanceForOverlay(double sceneMaxDistance) {
    return math.max(0.0, sceneMaxDistance - 2.0);
  }

  bool _appendPreferredTfMarker({
    required Size canvasSize,
    required List<Map<String, dynamic>> polygons,
    required List<Map<String, dynamic>> labels,
  }) {
    final cam = _currentCameraOverlay2d();
    if (cam == null || cam['tfMarker'] is! Map) return false;
    final sourceWidth =
        _DriveOverlaySnapshot._asDouble(cam['sourceWidth']) ?? _baseSourceWidth;
    final sourceHeight = _DriveOverlaySnapshot._asDouble(cam['sourceHeight']) ??
        _baseSourceHeight;
    final displayTransformRaw = cam['displayTransform'];
    final displayTransform = displayTransformRaw is Map
        ? Map<String, dynamic>.from(displayTransformRaw)
        : null;

    _appendSidecarTfMarker(
      cam: cam,
      canvasSize: canvasSize,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      displayTransform: displayTransform,
      polygons: polygons,
      labels: labels,
      showStopDistanceTf: showStopDistanceTf,
    );
    return true;
  }

  bool _appendPreferredLeadAndRadarPolygons({
    required Size canvasSize,
    required List<Map<String, dynamic>> polygons,
    required List<Map<String, dynamic>> labels,
  }) {
    final cam = _currentCameraOverlay2d();
    if (cam == null) return false;
    final hasLeadBoxes = cam['leadAreaBoxes'] is List;
    final hasRadarTargets = cam['radarTargets'] is List;
    if (!hasLeadBoxes && !hasRadarTargets) {
      return false;
    }
    final sourceWidth =
        _DriveOverlaySnapshot._asDouble(cam['sourceWidth']) ?? _baseSourceWidth;
    final sourceHeight = _DriveOverlaySnapshot._asDouble(cam['sourceHeight']) ??
        _baseSourceHeight;
    final displayTransformRaw = cam['displayTransform'];
    final displayTransform = displayTransformRaw is Map
        ? Map<String, dynamic>.from(displayTransformRaw)
        : null;

    // Prefer the sidecar's projected lead/radar overlays when available.
    // The sidecar already mirrors carrot.cc anchor smoothing/clamping and
    // fixed-Z lead box policy, which is more stable in close stop-and-go scenes.
    _appendSidecarLeadAndRadarPolygons(
      cam: cam,
      canvasSize: canvasSize,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      displayTransform: displayTransform,
      polygons: polygons,
      labels: labels,
      showLead1: showLead1,
      showLead2: showLead2,
      showRadarBadge: showRadarBadge,
      showRadarVector: showRadarVector,
      showStateText: showStateText,
    );
    return true;
  }

  _ProjectedLeadBox? _projectLeadBox(
    _ProjectionTransform transform,
    Size canvasSize,
    _RadarLeadSample lead, {
    int slot = 0,
  }) {
    if (!lead.status || !lead.dRel.isFinite || lead.dRel <= 0.0) return null;
    const zBase = 1.22;
    final z = _sampleModelZAtDistance(lead.dRel);
    final yCenter = -lead.yRel;

    Offset? left;
    Offset? right;
    final okL = _mapToScreen(
      transform,
      lead.dRel,
      yCenter - 1.2,
      z + zBase,
      (p) => left = p,
    );
    final okR = _mapToScreen(
      transform,
      lead.dRel,
      yCenter + 1.2,
      z + zBase,
      (p) => right = p,
    );
    if (!okL || !okR || left == null || right == null) return null;

    final rawWidth = (right!.dx - left!.dx).abs();
    final rawCenterX = (left!.dx + right!.dx) * 0.5;
    final rawCenterY = (left!.dy + right!.dy) * 0.5;
    if (!rawWidth.isFinite ||
        !rawCenterX.isFinite ||
        !rawCenterY.isFinite ||
        rawWidth <= 1.0) {
      return null;
    }

    // EMA smoothing — matches carrot.cc path_fx/fy/fwidth with alpha=0.85.
    // Prevents the anchor from jumping when a vehicle appears or comes close.
    final int prevTrackId;
    final double prevFx, prevFy, prevFw;
    if (slot == 0) {
      prevTrackId = _emaTrackId0;
      prevFx = _emaFx0;
      prevFy = _emaFy0;
      prevFw = _emaFw0;
    } else {
      prevTrackId = _emaTrackId1;
      prevFx = _emaFx1;
      prevFy = _emaFy1;
      prevFw = _emaFw1;
    }
    final bool trackChanged = prevTrackId != lead.radarTrackId ||
        !prevFx.isFinite ||
        !prevFy.isFinite;
    final double emaAlpha;
    if (lead.dRel <= 14.0) {
      emaAlpha = _leadCloseEmaAlpha;
    } else if (lead.dRel <= 28.0) {
      emaAlpha = _leadNearEmaAlpha;
    } else {
      emaAlpha = _leadEmaAlpha;
    }
    final double smoothX = trackChanged
        ? rawCenterX
        : prevFx * emaAlpha + rawCenterX * (1.0 - emaAlpha);
    final double smoothY = trackChanged
        ? rawCenterY
        : prevFy * emaAlpha + rawCenterY * (1.0 - emaAlpha);
    final double smoothW = trackChanged
        ? rawWidth
        : prevFw * emaAlpha + rawWidth * (1.0 - emaAlpha);
    if (slot == 0) {
      _emaFx0 = smoothX;
      _emaFy0 = smoothY;
      _emaFw0 = smoothW;
      _emaTrackId0 = lead.radarTrackId;
    } else {
      _emaFx1 = smoothX;
      _emaFy1 = smoothY;
      _emaFw1 = smoothW;
      _emaTrackId1 = lead.radarTrackId;
    }

    final sourceScale =
        transform.sourceScale.isFinite && transform.sourceScale > 0.0
            ? transform.sourceScale
            : 1.0;
    // Clamp margins match carrot.cc: [350, fb_w-350] × [200, fb_h-80] in source pixels.
    final marginX = math.min(canvasSize.width * 0.35, 350.0 * sourceScale);
    final topMargin = math.min(canvasSize.height * 0.28, 200.0 * sourceScale);
    // Use max (not min) for bottom margin so it is at least 80 source-px from bottom.
    final bottomMargin = math.max(canvasSize.height * 0.14, 80.0 * sourceScale);
    final centerX = _clampDouble(
      smoothX,
      marginX,
      math.max(marginX, canvasSize.width - marginX),
    );
    final centerY = _clampDouble(
      smoothY,
      topMargin,
      math.max(topMargin, canvasSize.height - bottomMargin),
    );
    final width =
        _clampDouble(smoothW, 120.0 * sourceScale, 800.0 * sourceScale);
    final sidePad = 10.0 * sourceScale;
    final boxHeight = math.max(width * 0.8, 12.0 * sourceScale);
    final rect = Rect.fromLTRB(
      centerX - (width * 0.5) - sidePad,
      centerY - boxHeight,
      centerX + (width * 0.5) + sidePad,
      centerY,
    );
    return _ProjectedLeadBox(
      rect: rect,
      center: Offset(centerX, centerY),
      width: width,
      yCenter: centerY,
      radarDetected: lead.radar,
      radarTrackId: lead.radarTrackId,
    );
  }

  void _appendProjectedLeadAndRadarPolygons({
    required _ProjectionTransform transform,
    required Size canvasSize,
    required List<Map<String, dynamic>> polygons,
    required List<Map<String, dynamic>> labels,
  }) {
    if (cameraKind != _DriveCameraKind.road) return;
    final cameraFrameId = snapshot.roadFrameId;
    final modelFrameId = snapshot.modelFrameId;
    final frameGap = (cameraFrameId != null && modelFrameId != null)
        ? (modelFrameId - cameraFrameId).abs()
        : null;
    if (frameGap != null && frameGap > 3) {
      return;
    }

    final cam = _currentCameraOverlay2d();
    final meta = cam?['meta'];
    final showRadarInfo = meta is Map
        ? (_DriveOverlaySnapshot._asInt(meta['showRadarInfo']) ?? 0)
        : 0;
    final xState = meta is Map
        ? (_DriveOverlaySnapshot._asInt(meta['xState']) ?? snapshot.xState)
        : snapshot.xState;
    final trafficState = meta is Map
        ? (_DriveOverlaySnapshot._asInt(meta['trafficState']) ??
            snapshot.trafficState)
        : snapshot.trafficState;
    final longActive = meta is Map
        ? _boolFromDynamic(meta['longActive'], fallback: snapshot.longActive)
        : snapshot.longActive;
    final vEgoMps = meta is Map
        ? (_DriveOverlaySnapshot._asDouble(meta['vEgoMps']) ??
            (snapshot.speedMps ?? 0.0))
        : (snapshot.speedMps ?? 0.0);
    final radarLatFactor = meta is Map
        ? (_DriveOverlaySnapshot._asDouble(meta['radarLatFactor']) ?? 0.0)
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

    final sourceScale =
        transform.sourceScale.isFinite && transform.sourceScale > 0.0
            ? transform.sourceScale
            : 1.0;
    int leadTwoStatus = 1;
    final leadAreaBoxes = cam?['leadAreaBoxes'];
    if (leadAreaBoxes is List) {
      for (final item in leadAreaBoxes) {
        if (item is Map && (item['kind']?.toString() ?? '') == 'leadTwo') {
          leadTwoStatus = _DriveOverlaySnapshot._asInt(item['status']) ?? 1;
          break;
        }
      }
    }

    final leadOne = snapshot.leadOne;
    final leadOneBox = leadOne != null && leadOne.status
        ? _projectLeadBox(transform, canvasSize, leadOne, slot: 0)
        : null;
    if (leadOneBox != null && showLead1) {
      final isLeadScc = leadOneBox.radarTrackId < 1;
      final strokeColor = !leadOneBox.radarDetected
          ? const Color(0xFF3D7BFF)
          : (isLeadScc ? const Color(0xFFFF3B30) : const Color(0xFFFFA726));
      _appendLeadBoxCard(
        polygons,
        rect: leadOneBox.rect,
        sourceScale: sourceScale,
        strokeColor: strokeColor,
        fillColor: const Color(0x33000000),
        primary: true,
      );

      final radarDist =
          leadOneBox.radarDetected ? math.max(0.0, leadOne?.dRel ?? 0.0) : 0.0;
      final visionDist = leadOne != null && leadOne.modelProb > 0.5
          ? math.max(0.0, leadOne.dRel - 1.52)
          : 0.0;
      final badgeLayout =
          _leadDistanceBadgeLayout(leadOneBox.rect, sourceScale);
      final hasRadarDistance = radarDist > 0.0;
      final hasVisionDistance = visionDist > 0.0;
      final primaryDistance =
          hasRadarDistance ? radarDist : (hasVisionDistance ? visionDist : 0.0);
      final primaryBadgeColor = hasRadarDistance
          ? (isLeadScc ? const Color(0xFFFF3B30) : const Color(0xFFFFA726))
          : const Color(0xFF3D7BFF);
      if (drawDistanceBadges && showRadarBadge && primaryDistance > 0.0) {
        _appendLeadDistanceBadge(
          polygons,
          labels,
          layout: badgeLayout,
          sourceScale: sourceScale,
          text: primaryDistance.toStringAsFixed(1),
          accentColor: primaryBadgeColor,
          textColor: badgeTextColor,
        );
      }
      if (showStateText && stateText != null) {
        _appendLeadStateBadge(
          polygons,
          labels,
          rect: leadOneBox.rect,
          sourceScale: sourceScale,
          xState: xState,
          text: stateText,
        );
      }
    }

    final leadTwo = snapshot.leadTwo;
    final validLeadTwo = leadTwo != null &&
        leadTwo.status &&
        leadTwo.radar &&
        (leadOne == null || leadTwo.dRel > (leadOne.dRel + 3.0)) &&
        leadTwo.radarTrackId != (leadOne?.radarTrackId ?? -9999);
    final _RadarLeadSample? leadTwoSample = validLeadTwo ? leadTwo : null;
    final leadTwoBox = leadTwoSample != null
        ? _projectLeadBox(transform, canvasSize, leadTwoSample, slot: 1)
        : null;
    if (leadTwoBox != null && showLead2) {
      _appendLeadBoxCard(
        polygons,
        rect: leadTwoBox.rect,
        sourceScale: sourceScale,
        strokeColor: const Color(0xFFB68A3A),
        fillColor: leadTwoStatus >= 2
            ? const Color(0x66FF3B30)
            : const Color(0x33000000),
        primary: false,
      );
    }

    if (showRadarInfo <= 0 || (!showRadarBadge && !showRadarVector)) {
      return;
    }
    final radarTracks = <_RadarTrackSample>[
      ...snapshot.leadsLeft,
      ...snapshot.leadsCenter,
      ...snapshot.leadsRight,
    ];
    for (final radar in radarTracks) {
      if (!radar.dRel.isFinite || radar.dRel <= 2.5) continue;
      final z = _sampleRadarZAtDistance(radar.dRel) - 0.61;
      Offset? center;
      final okCenter = _mapToScreen(
        transform,
        radar.dRel,
        -radar.yRel,
        z,
        (p) => center = p,
      );
      if (!okCenter || center == null) continue;
      final Offset centerPoint = center!;

      final vLead = radar.vLeadK.isFinite ? radar.vLeadK : radar.vRel;
      final vAbs = math.sqrt((vLead * vLead) + (radar.vLat * radar.vLat));
      final vSigned = vLead >= 0.0 ? vAbs : -vAbs;
      if (showRadarVector && vAbs > 3.0 && radarLatFactor > 0.0) {
        final futureDRel = math.max(2.0, radar.dRel + (vLead * radarLatFactor));
        final futureYRel = radar.yRel + (radar.vLat * radarLatFactor);
        Offset? future;
        final okFuture = _mapToScreen(
          transform,
          futureDRel,
          -futureYRel,
          z,
          (p) => future = p,
        );
        if (okFuture && future != null) {
          final Offset futurePoint = future!;
          _appendDebugLinePolygon(
            polygons,
            a: centerPoint,
            b: futurePoint,
            color: vSigned >= 0.0
                ? const Color(0xFF23D55D)
                : const Color(0xFFFF3B30),
            thickness: 3.0,
          );
          polygons.add(
            _encodePolygon(
              _circleVertices(
                futurePoint,
                7.0,
              ),
              vSigned >= 0.0
                  ? const Color(0xFF23D55D)
                  : const Color(0xFFFF3B30),
            ),
          );
        }
      }

      if (showRadarBadge && vAbs > 3.0) {
        final speedKph = vSigned * 3.6;
        Color badgeColor;
        if (!radar.radar) {
          badgeColor = const Color(0xFF3D7BFF);
        } else if ((radar.modelProb - 0.01).abs() < 1e-3) {
          badgeColor = const Color(0xFF23D55D);
        } else if (vSigned > 0.0) {
          badgeColor = const Color(0xFFFFA726);
        } else {
          badgeColor = const Color(0xFFFF3B30);
        }
        _appendRadarSpeedBadge(
          polygons,
          labels,
          center: Offset(
            centerPoint.dx,
            centerPoint.dy - (18.0 * sourceScale),
          ),
          sourceScale: sourceScale,
          text: speedKph.toStringAsFixed(0),
          accentColor: badgeColor,
        );
        if (showRadarInfo >= 2) {
          _appendOverlayLabel(
            labels,
            anchor: Offset(
              centerPoint.dx,
              centerPoint.dy - (48.0 * sourceScale),
            ),
            text: radar.yRel.toStringAsFixed(1),
            color: Colors.white,
            strokeColor: Colors.black,
            strokeWidth: 1.4,
            size: _clampDouble(18.0 * sourceScale, 16.0, 21.0),
            centered: true,
          );
          _appendOverlayLabel(
            labels,
            anchor: Offset(
              centerPoint.dx,
              centerPoint.dy + (30.0 * sourceScale),
            ),
            text: radar.dRel.toStringAsFixed(1),
            color: Colors.white,
            strokeColor: Colors.black,
            strokeWidth: 1.4,
            size: _clampDouble(18.0 * sourceScale, 16.0, 21.0),
            centered: true,
          );
        }
      } else if (showRadarInfo >= 3) {
        _appendOverlayLabel(
          labels,
          anchor: centerPoint,
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

    final gradientsRaw = payload['gradients'];
    if (gradientsRaw is List) {
      for (final item in gradientsRaw) {
        if (item is! Map) continue;
        final left = _DriveOverlaySnapshot._asDouble(item['left']);
        final top = _DriveOverlaySnapshot._asDouble(item['top']);
        final right = _DriveOverlaySnapshot._asDouble(item['right']);
        final bottom = _DriveOverlaySnapshot._asDouble(item['bottom']);
        final startX = _DriveOverlaySnapshot._asDouble(item['startX']);
        final startY = _DriveOverlaySnapshot._asDouble(item['startY']);
        final endX = _DriveOverlaySnapshot._asDouble(item['endX']);
        final endY = _DriveOverlaySnapshot._asDouble(item['endY']);
        final colorsRaw = item['colors'];
        final stopsRaw = item['stops'];
        if (left == null ||
            top == null ||
            right == null ||
            bottom == null ||
            startX == null ||
            startY == null ||
            endX == null ||
            endY == null ||
            colorsRaw is! List ||
            stopsRaw is! List ||
            colorsRaw.length < 2 ||
            colorsRaw.length != stopsRaw.length) {
          continue;
        }
        final colors = <Color>[];
        final stops = <double>[];
        var ok = true;
        for (var i = 0; i < colorsRaw.length; i++) {
          final colorInt = _DriveOverlaySnapshot._asInt(colorsRaw[i]);
          final stop = _DriveOverlaySnapshot._asDouble(stopsRaw[i]);
          if (colorInt == null || stop == null) {
            ok = false;
            break;
          }
          colors.add(Color(colorInt));
          stops.add(stop.clamp(0.0, 1.0));
        }
        if (!ok) continue;
        final rect = Rect.fromLTRB(left, top, right, bottom);
        if (rect.width <= 0.0 || rect.height <= 0.0) continue;
        canvas.drawRect(
          rect,
          Paint()
            ..shader = ui.Gradient.linear(
              Offset(startX, startY),
              Offset(endX, endY),
              colors,
              stops,
              TileMode.clamp,
            ),
        );
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
      final strokeInt = _DriveOverlaySnapshot._asInt(item['strokeColor']);
      final strokeWidth =
          (_DriveOverlaySnapshot._asDouble(item['strokeWidth']) ?? 0.0)
              .clamp(0.0, 8.0);
      var sizePx = (_DriveOverlaySnapshot._asDouble(item['size']) ?? 16.0)
          .clamp(4.5, 72.0);
      final maxLinesRaw = _DriveOverlaySnapshot._asInt(item['maxLines']);
      final maxLines =
          maxLinesRaw != null && maxLinesRaw > 0 ? maxLinesRaw : null;
      final ellipsis = item['ellipsis']?.toString();
      final fontWeightRaw =
          _DriveOverlaySnapshot._asInt(item['fontWeight']) ?? 700;
      final fontWeight = switch (fontWeightRaw) {
        >= 900 => FontWeight.w900,
        >= 800 => FontWeight.w800,
        >= 700 => FontWeight.w700,
        >= 600 => FontWeight.w600,
        >= 500 => FontWeight.w500,
        >= 400 => FontWeight.w400,
        >= 300 => FontWeight.w300,
        >= 200 => FontWeight.w200,
        >= 100 => FontWeight.w100,
        _ => FontWeight.w700,
      };
      final centered = _boolFromDynamic(item['centered']);
      final alignXRaw = item['alignX']?.toString().trim().toLowerCase();
      final alignYRaw = item['alignY']?.toString().trim().toLowerCase();
      final alignX = switch (alignXRaw) {
        'left' => 'left',
        'right' => 'right',
        'center' => 'center',
        _ => centered ? 'center' : 'left',
      };
      final alignY = switch (alignYRaw) {
        'top' => 'top',
        'bottom' => 'bottom',
        'baselinebottom' => 'baselineBottom',
        'center' || 'middle' => 'middle',
        _ => centered ? 'middle' : 'bottom',
      };
      final labelMaxWidth =
          (_DriveOverlaySnapshot._asDouble(item['maxWidth']) ??
                  (canvasSize.width * 0.42))
              .clamp(120.0, 1600.0);
      final shouldScaleSingleLine = (maxLines == null || maxLines <= 1) &&
          (ellipsis == null || ellipsis.isEmpty);
      if (shouldScaleSingleLine) {
        tp.text = TextSpan(
          text: text,
          style: TextStyle(
            color: Color(colorInt),
            fontSize: sizePx,
            fontWeight: fontWeight,
          ),
        );
        tp.maxLines = 1;
        tp.ellipsis = null;
        tp.layout();
        if (tp.width > labelMaxWidth && tp.width > 1.0) {
          sizePx = (sizePx * ((labelMaxWidth / tp.width) * 0.985)).clamp(
            4.5,
            sizePx,
          );
        }
      }
      tp.text = TextSpan(
        text: text,
        style: TextStyle(
          color: Color(colorInt),
          fontSize: sizePx,
          fontWeight: fontWeight,
        ),
      );
      tp.maxLines = maxLines;
      tp.ellipsis = ellipsis;
      tp.layout(maxWidth: labelMaxWidth.toDouble());
      final baseline =
          tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      final paintX = switch (alignX) {
        'center' => dx - (tp.width * 0.5),
        'right' => dx - tp.width,
        _ => dx,
      };
      final paintY = switch (alignY) {
        'top' => dy,
        'middle' => dy - (tp.height * 0.5),
        'baselineBottom' => dy - baseline,
        _ => dy - tp.height,
      };
      final paintOffset = Offset(paintX, paintY);
      if (strokeInt != null && strokeWidth > 0.0) {
        final strokeTp = TextPainter(
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
          maxLines: maxLines,
          ellipsis: ellipsis,
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontSize: sizePx,
              fontWeight: fontWeight,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeJoin = StrokeJoin.round
                ..strokeWidth = strokeWidth
                ..color = Color(strokeInt),
            ),
          ),
        );
        strokeTp.layout(maxWidth: labelMaxWidth.toDouble());
        strokeTp.paint(canvas, paintOffset);
      }
      tp.paint(canvas, paintOffset);
    }
  }

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    if (snapshot.path.length < 2) {
      final plotPayload =
          showDebugPlot ? _buildDebugPlotOverlayPayload(size) : null;
      if (plotPayload != null) {
        _drawEncodedOverlayPayload(canvas, size, plotPayload);
      }
      return;
    }
    final transform = _buildTransform(size);
    final sceneMaxDistance = _sceneMaxDistanceForOverlay();
    final pathMaxDistance = _pathMaxDistanceForOverlay(sceneMaxDistance);
    final laneBaseX = snapshot.laneLines.isNotEmpty
        ? snapshot.laneLines.first.line.x
        : snapshot.path.x;
    final laneMaxIdx = laneBaseX.isNotEmpty
        ? _getPathLengthIdx(laneBaseX, sceneMaxDistance)
        : _getPathLengthIdx(snapshot.path.x, sceneMaxDistance);

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
      pathMaxDistance,
      startDistance: startDistance,
      allowInvert: false,
    );
    if (showPathFill && trackVertices != null) {
      _drawPathByMode(canvas, trackVertices);
    }
    if (showDebugGuides) {
      _drawDebugGuides(
        canvas,
        size: size,
        transform: transform,
        trackVertices: trackVertices,
      );
    }
    final fadeGradients = <Map<String, dynamic>>[];
    _appendViewportFadeGradients(
      fadeGradients,
      canvasSize: size,
    );
    if (fadeGradients.isNotEmpty) {
      _drawEncodedOverlayPayload(
        canvas,
        size,
        <String, dynamic>{
          'version': 3,
          'canvasWidth': size.width,
          'canvasHeight': size.height,
          'gradients': fadeGradients,
        },
      );
    }
    final plotPayload =
        showDebugPlot ? _buildDebugPlotOverlayPayload(size) : null;
    if (plotPayload != null) {
      _drawEncodedOverlayPayload(canvas, size, plotPayload);
    }
  }

  @override
  bool shouldRepaint(covariant _DriveOverlayPainter oldDelegate) {
    return oldDelegate.snapshot != snapshot ||
        oldDelegate.isConnected != isConnected ||
        oldDelegate.sourceSize != sourceSize ||
        oldDelegate.cameraKind != cameraKind ||
        oldDelegate.coverViewport != coverViewport ||
        oldDelegate.viewportZoom != viewportZoom ||
        oldDelegate.visibleViewportRect != visibleViewportRect ||
        oldDelegate.showDebugGuides != showDebugGuides ||
        oldDelegate.showPathFill != showPathFill ||
        oldDelegate.showLaneLines != showLaneLines ||
        oldDelegate.showRoadEdge != showRoadEdge ||
        oldDelegate.showLead1 != showLead1 ||
        oldDelegate.showLead2 != showLead2 ||
        oldDelegate.showRadarBadge != showRadarBadge ||
        oldDelegate.showRadarVector != showRadarVector ||
        oldDelegate.showStopDistanceTf != showStopDistanceTf ||
        oldDelegate.showStateText != showStateText ||
        oldDelegate.showStockTopRight != showStockTopRight ||
        oldDelegate.showLaneMetrics != showLaneMetrics ||
        oldDelegate.showDebugPlot != showDebugPlot ||
        oldDelegate.debugPlotState != debugPlotState;
  }
}

class _ProjectedLeadBox {
  final Rect rect;
  final Offset center;
  final double width;
  final double yCenter;
  final bool radarDetected;
  final int radarTrackId;

  const _ProjectedLeadBox({
    required this.rect,
    required this.center,
    required this.width,
    required this.yCenter,
    required this.radarDetected,
    required this.radarTrackId,
  });
}

class _LeadDistanceBadgeLayout {
  final Offset center;
  final double fontSize;
  final double minWidth;
  final double height;

  const _LeadDistanceBadgeLayout({
    required this.center,
    required this.fontSize,
    required this.minWidth,
    required this.height,
  });
}
