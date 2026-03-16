part of 'live_drive_canvas_screen.dart';

const Color _drivePlotTraceYellow = Color(0xFFFFD95E);
const Color _drivePlotTraceGreen = Color(0xFF23D55D);
const Color _drivePlotTraceOrange = Color(0xFFFF9F1C);
const Color _drivePlotLabelMuted = Color(0xFFF2F5F8);
const Color _drivePlotLabelOutline = Color(0xE6000000);
const double _drivePlotDxPx = 1.2;

extension _LiveDriveCanvasPlotComponents on _LiveDriveCanvasScreenState {
  void _recordDebugPlotSample(_DriveOverlaySnapshot snapshot) {
    final nowUs = _renderClock.elapsedMicroseconds;
    final sample = snapshot.debugPlot;
    if (sample == null) {
      final stale = _lastDebugPlotSampleUs > 0 &&
          (nowUs - _lastDebugPlotSampleUs) >
              _LiveDriveCanvasScreenState._debugPlotMissingClearGraceUs;
      if (stale) {
        _debugPlotState = _debugPlotState.clear();
        _lastDebugPlotSampleUs = 0;
        _lastDebugPlotQueueUs = 0;
        _latestDebugPlotSample = null;
      }
      return;
    }
    final prev = _latestDebugPlotSample;
    final reset = prev == null ||
        prev.mode != sample.mode ||
        prev.title != sample.title;
    _lastDebugPlotSampleUs = nowUs;
    _latestDebugPlotSample = sample;
    if (reset ||
        _lastDebugPlotQueueUs <= 0 ||
        (nowUs - _lastDebugPlotQueueUs) >=
            _LiveDriveCanvasScreenState._debugPlotTargetQueueIntervalUs) {
      _debugPlotState = _debugPlotState.push(sample);
      _lastDebugPlotQueueUs = nowUs;
    }
  }

  void _clearDebugPlotState() {
    _debugPlotState = _debugPlotState.clear();
    _lastDebugPlotSampleUs = 0;
    _lastDebugPlotQueueUs = 0;
    _latestDebugPlotSample = null;
  }

  void _pumpDebugPlotTick({required int nowUs}) {
    final sample = _latestDebugPlotSample;
    if (sample == null) return;
    if (_lastDebugPlotSampleUs > 0 &&
        (nowUs - _lastDebugPlotSampleUs) >
            _LiveDriveCanvasScreenState._debugPlotMissingClearGraceUs) {
      _clearDebugPlotState();
      return;
    }
    if (_lastDebugPlotQueueUs > 0 &&
        (nowUs - _lastDebugPlotQueueUs) <
            _LiveDriveCanvasScreenState._debugPlotTargetQueueIntervalUs) {
      return;
    }
    _debugPlotState = _debugPlotState.push(sample);
    _lastDebugPlotQueueUs = nowUs;
  }
}

extension _DriveDebugPlotPainterComponents on _DriveOverlayPainter {
  Rect _plotVisibleRect(Size canvasSize) {
    final full = Offset.zero & canvasSize;
    final candidate = (visibleViewportRect ?? full).intersect(full);
    if (candidate.width < 80.0 || candidate.height < 60.0) {
      return full;
    }
    return candidate;
  }

  String _plotShortTitle(String raw) {
    final title = raw.trim();
    if (title.isEmpty) return 'Debug plot';
    final idx = title.indexOf('(');
    return (idx > 0 ? title.substring(0, idx) : title).trim();
  }

  ({
    Rect chartRect,
    Offset titleAnchor,
    Offset countAnchor,
    double valueX,
    double valueBaseY,
    double valueGap,
    double titleSize,
    double valueSize,
    double metaSize,
    double lineThickness,
    double glowThickness,
    double outerDotRadius,
    double innerDotRadius,
  }) _plotHudLayout(Size canvasSize) {
    final visible = _plotVisibleRect(canvasSize);
    final minSide = math.min(visible.width, visible.height);
    final isLandscape = visible.width >= visible.height;
    final margin = switch (minSide) {
      < 360.0 => 6.0,
      < 720.0 => 8.0,
      _ => 10.0,
    };
    final availableWidth = math.max(148.0, visible.width - (margin * 2));
    final availableHeight = math.max(96.0, visible.height - (margin * 2));
    final gap = minSide < 360.0 ? 6.0 : 8.0;
    final titleSize = switch (minSide) {
      < 360.0 => 11.0,
      < 720.0 => 12.0,
      _ => 13.0,
    };
    final valueSize = switch (minSide) {
      < 360.0 => 12.0,
      < 720.0 => 13.5,
      _ => 15.0,
    };
    final metaSize = switch (minSide) {
      < 360.0 => 10.0,
      < 720.0 => 11.0,
      _ => 12.0,
    };
    var clusterWidth = availableWidth;
    var valueColumnWidth = (clusterWidth * (isLandscape ? 0.115 : 0.13))
        .clamp(56.0, 92.0)
        .toDouble();
    valueColumnWidth = math.min(
      valueColumnWidth,
      math.max(58.0, availableWidth * 0.18),
    );
    var chartWidth =
        (clusterWidth - valueColumnWidth - gap).clamp(180.0, 560.0).toDouble();
    if ((chartWidth + valueColumnWidth + gap) > availableWidth) {
      chartWidth = math.max(96.0, availableWidth - valueColumnWidth - gap);
      clusterWidth = chartWidth + valueColumnWidth + gap;
    }
    final chartHeight = (visible.height * (isLandscape ? 0.16 : 0.20))
        .clamp(84.0, 156.0)
        .toDouble();
    final resolvedChartHeight = math.min(
      chartHeight,
      math.max(84.0, availableHeight - titleSize - 12.0),
    );
    final clusterMaxWidth = chartWidth + gap + valueColumnWidth;
    final maxLeft =
        math.max(visible.left + 8.0, visible.right - clusterMaxWidth);
    final maxTop = math.max(
      visible.top + 8.0,
      visible.bottom - (titleSize + 8.0 + resolvedChartHeight),
    );
    final left = math.min(visible.left + margin, maxLeft).toDouble();
    final top = math.min(visible.top + margin, maxTop).toDouble();
    final chartTop = top + titleSize + 8.0;
    final chartRect =
        Rect.fromLTWH(left, chartTop, chartWidth, resolvedChartHeight);
    final valueBaseY = chartRect.top + (valueSize * 0.9);
    final valueGap = switch (chartHeight) {
      < 84.0 => 18.0,
      < 110.0 => 22.0,
      _ => 26.0,
    };
    return (
      chartRect: chartRect,
      titleAnchor: Offset(left, top + titleSize),
      countAnchor: Offset(chartRect.right + gap, chartRect.bottom),
      valueX: chartRect.right + gap,
      valueBaseY: valueBaseY,
      valueGap: valueGap,
      titleSize: titleSize,
      valueSize: valueSize,
      metaSize: metaSize,
      lineThickness: minSide < 360.0 ? 1.9 : 2.5,
      glowThickness: minSide < 360.0 ? 5.0 : 6.8,
      outerDotRadius: minSide < 360.0 ? 4.2 : 5.0,
      innerDotRadius: minSide < 360.0 ? 2.2 : 2.8,
    );
  }

  double _plotYForValue(
      Rect chartRect, double value, double minValue, double maxValue) {
    final span =
        (maxValue - minValue).abs() < 1e-6 ? 1.0 : (maxValue - minValue);
    final t = ((value - minValue) / span).clamp(0.0, 1.0).toDouble();
    final verticalInset =
        (chartRect.height * 0.02).clamp(1.0, 4.0).toDouble();
    final usableHeight = math.max(8.0, chartRect.height - (verticalInset * 2));
    return chartRect.bottom - verticalInset - (usableHeight * t);
  }

  List<Offset> _plotPoints(
      List<double> series, Rect chartRect, double minValue, double maxValue) {
    if (series.isEmpty) return const <Offset>[];
    if (series.length == 1) {
      return <Offset>[
        Offset(
          chartRect.right,
          _plotYForValue(chartRect, series.first, minValue, maxValue),
        ),
      ];
    }
    final points = <Offset>[];
    final maxVisiblePoints =
        math.max(2, (chartRect.width / _drivePlotDxPx).floor() + 1);
    final visibleCount = math.min(series.length, maxVisiblePoints);
    final startIndex = math.max(0, series.length - visibleCount);
    final fillEntireWidth = visibleCount < maxVisiblePoints;
    final dx = fillEntireWidth
        ? chartRect.width / math.max(1, visibleCount - 1)
        : math.min(
            _drivePlotDxPx,
            chartRect.width / math.max(1, visibleCount - 1),
          );
    final totalWidth = dx * math.max(0, visibleCount - 1);
    final startX = fillEntireWidth ? chartRect.left : chartRect.right - totalWidth;
    for (var i = 0; i < visibleCount; i++) {
      final sampleIndex = startIndex + i;
      points.add(
        Offset(
          startX + (dx * i),
          _plotYForValue(chartRect, series[sampleIndex], minValue, maxValue),
        ),
      );
    }
    return points;
  }

  String _formatPlotValue(double value) {
    final absValue = value.abs();
    if (!value.isFinite) return '0.00';
    if (absValue >= 100.0) return value.toStringAsFixed(0);
    if (absValue >= 10.0) return value.toStringAsFixed(1);
    return value.toStringAsFixed(2);
  }

  void _appendPlotTracePolygons(
    List<Map<String, dynamic>> polygons, {
    required List<double> series,
    required Rect chartRect,
    required double minValue,
    required double maxValue,
    required Color color,
    required double lineThickness,
    required double outerDotRadius,
    required double innerDotRadius,
  }) {
    final points = _plotPoints(series, chartRect, minValue, maxValue);
    if (points.isEmpty) return;
    const outlineColor = _drivePlotLabelOutline;
    final outlineThickness = lineThickness + 0.8;
    for (var i = 1; i < points.length; i++) {
      _appendDebugLinePolygon(
        polygons,
        a: points[i - 1],
        b: points[i],
        color: outlineColor,
        thickness: outlineThickness,
      );
      _appendDebugLinePolygon(
        polygons,
        a: points[i - 1],
        b: points[i],
        color: color,
        thickness: lineThickness,
      );
    }
    final last = points.last;
    polygons.add(
      _encodePolygon(
        _circleVertices(last, outerDotRadius, segments: 14),
        outlineColor,
      ),
    );
    polygons.add(
      _encodePolygon(
        _circleVertices(
          last,
          math.max(1.0, innerDotRadius + 0.6),
          segments: 12,
        ),
        color,
      ),
    );
    polygons.add(
      _encodePolygon(
        _circleVertices(last, innerDotRadius, segments: 12),
        color,
      ),
    );
  }

  void _appendDebugPlotPayload(
    List<Map<String, dynamic>> polygons,
    List<Map<String, dynamic>> labels, {
    required Size canvasSize,
  }) {
    if (!debugPlotState.isVisible) return;

    final layout = _plotHudLayout(canvasSize);
    final chartRect = layout.chartRect;
    final title = _plotShortTitle(debugPlotState.title);

    _appendPlotTracePolygons(
      polygons,
      series: debugPlotState.yellow,
      chartRect: chartRect,
      minValue: debugPlotState.minValue,
      maxValue: debugPlotState.maxValue,
      color: _drivePlotTraceYellow,
      lineThickness: layout.lineThickness,
      outerDotRadius: layout.outerDotRadius,
      innerDotRadius: layout.innerDotRadius,
    );
    _appendPlotTracePolygons(
      polygons,
      series: debugPlotState.green,
      chartRect: chartRect,
      minValue: debugPlotState.minValue,
      maxValue: debugPlotState.maxValue,
      color: _drivePlotTraceGreen,
      lineThickness: layout.lineThickness,
      outerDotRadius: layout.outerDotRadius,
      innerDotRadius: layout.innerDotRadius,
    );
    _appendPlotTracePolygons(
      polygons,
      series: debugPlotState.orange,
      chartRect: chartRect,
      minValue: debugPlotState.minValue,
      maxValue: debugPlotState.maxValue,
      color: _drivePlotTraceOrange,
      lineThickness: layout.lineThickness,
      outerDotRadius: layout.outerDotRadius,
      innerDotRadius: layout.innerDotRadius,
    );

    _appendOverlayLabel(
      labels,
      anchor: layout.titleAnchor,
      text: title,
      color: _drivePlotLabelMuted,
      strokeColor: _drivePlotLabelOutline,
      strokeWidth: 2.6,
      size: layout.titleSize,
      centered: false,
      fontWeight: 900,
    );

    final valueRows = <({String key, double value, Color color})>[
      (
        key: 'Y',
        value: debugPlotState.latestYellow,
        color: _drivePlotTraceYellow
      ),
      (
        key: 'G',
        value: debugPlotState.latestGreen,
        color: _drivePlotTraceGreen
      ),
      (
        key: 'O',
        value: debugPlotState.latestOrange,
        color: _drivePlotTraceOrange
      ),
    ];
    for (var i = 0; i < valueRows.length; i++) {
      final row = valueRows[i];
      _appendOverlayLabel(
        labels,
        anchor:
            Offset(layout.valueX, layout.valueBaseY + (i * layout.valueGap)),
        text: '${row.key} ${_formatPlotValue(row.value)}',
        color: row.color,
        strokeColor: _drivePlotLabelOutline,
        strokeWidth: 2.8,
        size: layout.valueSize,
        centered: false,
        fontWeight: 900,
      );
    }
    _appendOverlayLabel(
      labels,
      anchor: layout.countAnchor,
      text: 'n ${debugPlotState.sampleCount}',
      color: _drivePlotLabelMuted,
      strokeColor: _drivePlotLabelOutline,
      strokeWidth: 2.4,
      size: layout.metaSize,
      centered: false,
      fontWeight: 900,
    );
  }

  Map<String, dynamic>? _buildDebugPlotOverlayPayload(Size canvasSize) {
    if (!debugPlotState.isVisible) return null;
    final polygons = <Map<String, dynamic>>[];
    final labels = <Map<String, dynamic>>[];
    _appendDebugPlotPayload(
      polygons,
      labels,
      canvasSize: canvasSize,
    );
    if (polygons.isEmpty && labels.isEmpty) return null;
    return <String, dynamic>{
      'version': 3,
      'canvasWidth': canvasSize.width,
      'canvasHeight': canvasSize.height,
      'polygons': polygons,
      if (labels.isNotEmpty) 'labels': labels,
    };
  }
}
