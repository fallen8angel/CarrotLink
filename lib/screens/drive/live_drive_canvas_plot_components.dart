part of 'live_drive_canvas_screen.dart';

const Color _drivePlotTraceYellow = Color(0xFFFFD95E);
const Color _drivePlotTraceGreen = Color(0xFF23D55D);
const Color _drivePlotTraceOrange = Color(0xFFFF9F1C);
const Color _drivePlotLabelMuted = Color(0xB3D6DEE8);
const Color _drivePlotLabelOutline = Color(0xD9000000);

extension _LiveDriveCanvasPlotComponents on _LiveDriveCanvasScreenState {
  void _recordDebugPlotSample(_DriveOverlaySnapshot snapshot) {
    final sample = snapshot.debugPlot;
    if (sample == null) {
      final nowUs = _renderClock.elapsedMicroseconds;
      final stale = _lastDebugPlotSampleUs > 0 &&
          (nowUs - _lastDebugPlotSampleUs) >
              _LiveDriveCanvasScreenState._debugPlotMissingClearGraceUs;
      if (stale) {
        _debugPlotState = _debugPlotState.clear();
        _lastDebugPlotSampleUs = 0;
      }
      return;
    }
    _lastDebugPlotSampleUs = _renderClock.elapsedMicroseconds;
    _debugPlotState = _debugPlotState.push(sample);
  }

  void _clearDebugPlotState() {
    _debugPlotState = _debugPlotState.clear();
    _lastDebugPlotSampleUs = 0;
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
      < 360.0 => 12.0,
      < 720.0 => 15.0,
      _ => 18.0,
    };
    final availableWidth = math.max(148.0, visible.width - (margin * 2));
    final availableHeight = math.max(96.0, visible.height - (margin * 2));
    final gap = minSide < 360.0 ? 8.0 : 10.0;
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
    var valueColumnWidth = (clusterWidth * (isLandscape ? 0.16 : 0.18))
        .clamp(72.0, 120.0)
        .toDouble();
    valueColumnWidth = math.min(
      valueColumnWidth,
      math.max(76.0, availableWidth * 0.24),
    );
    var chartWidth =
        (clusterWidth - valueColumnWidth - gap).clamp(152.0, 428.0).toDouble();
    if ((chartWidth + valueColumnWidth + gap) > availableWidth) {
      chartWidth = math.max(96.0, availableWidth - valueColumnWidth - gap);
      clusterWidth = chartWidth + valueColumnWidth + gap;
    }
    final chartHeight = (visible.height * (isLandscape ? 0.14 : 0.18))
        .clamp(72.0, 132.0)
        .toDouble();
    final resolvedChartHeight = math.min(
      chartHeight,
      math.max(72.0, availableHeight - titleSize - 14.0),
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
      lineThickness: minSide < 360.0 ? 2.2 : 2.9,
      glowThickness: minSide < 360.0 ? 5.8 : 8.0,
      outerDotRadius: minSide < 360.0 ? 4.5 : 5.6,
      innerDotRadius: minSide < 360.0 ? 2.4 : 2.9,
    );
  }

  double _plotYForValue(
      Rect chartRect, double value, double minValue, double maxValue) {
    final span =
        (maxValue - minValue).abs() < 1e-6 ? 1.0 : (maxValue - minValue);
    final t = ((value - minValue) / span).clamp(0.0, 1.0).toDouble();
    final verticalInset = (chartRect.height * 0.08).clamp(4.0, 10.0).toDouble();
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
    final dx = chartRect.width / math.max(1, series.length - 1);
    for (var i = 0; i < series.length; i++) {
      points.add(
        Offset(
          chartRect.left + (dx * i),
          _plotYForValue(chartRect, series[i], minValue, maxValue),
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
    required double glowThickness,
    required double lineThickness,
    required double outerDotRadius,
    required double innerDotRadius,
  }) {
    final points = _plotPoints(series, chartRect, minValue, maxValue);
    if (points.isEmpty) return;
    final glow = color.withValues(alpha: 0.18);
    for (var i = 1; i < points.length; i++) {
      _appendDebugLinePolygon(
        polygons,
        a: points[i - 1],
        b: points[i],
        color: glow,
        thickness: glowThickness,
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
        color.withValues(alpha: 0.28),
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
      glowThickness: layout.glowThickness,
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
      glowThickness: layout.glowThickness,
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
      glowThickness: layout.glowThickness,
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
      strokeWidth: 1.8,
      size: layout.titleSize,
      centered: false,
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
        strokeWidth: 1.8,
        size: layout.valueSize,
        centered: false,
      );
    }
    _appendOverlayLabel(
      labels,
      anchor: layout.countAnchor,
      text: 'n ${debugPlotState.sampleCount}',
      color: _drivePlotLabelMuted,
      strokeColor: _drivePlotLabelOutline,
      strokeWidth: 1.6,
      size: layout.metaSize,
      centered: false,
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
