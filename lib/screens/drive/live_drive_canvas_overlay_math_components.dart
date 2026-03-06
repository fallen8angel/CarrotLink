part of 'live_drive_canvas_screen.dart';

class _ProjectionTransform {
  final _M3 carSpaceTransform;
  final Rect clip;
  final double sourceScale;
  final double xOffset;
  final double yOffset;

  const _ProjectionTransform({
    required this.carSpaceTransform,
    required this.clip,
    required this.sourceScale,
    required this.xOffset,
    required this.yOffset,
  });
}

class _DriveVideoPlacement {
  final double left;
  final double top;
  final double width;
  final double height;
  final double scale;
  final double xOffset;
  final double yOffset;

  const _DriveVideoPlacement({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.scale,
    required this.xOffset,
    required this.yOffset,
  });
}

class _SourceCanvasPlacement {
  final _M3 transform;
  final double scale;
  final double xOffset;
  final double yOffset;

  const _SourceCanvasPlacement({
    required this.transform,
    required this.scale,
    required this.xOffset,
    required this.yOffset,
  });
}

class _V3 {
  final double x;
  final double y;
  final double z;

  const _V3(this.x, this.y, this.z);
}

class _M3 {
  final double m00;
  final double m01;
  final double m02;
  final double m10;
  final double m11;
  final double m12;
  final double m20;
  final double m21;
  final double m22;

  const _M3(
    this.m00,
    this.m01,
    this.m02,
    this.m10,
    this.m11,
    this.m12,
    this.m20,
    this.m21,
    this.m22,
  );

  const _M3.identity()
      : m00 = 1.0,
        m01 = 0.0,
        m02 = 0.0,
        m10 = 0.0,
        m11 = 1.0,
        m12 = 0.0,
        m20 = 0.0,
        m21 = 0.0,
        m22 = 1.0;

  _M3 multiply(_M3 o) {
    return _M3(
      m00 * o.m00 + m01 * o.m10 + m02 * o.m20,
      m00 * o.m01 + m01 * o.m11 + m02 * o.m21,
      m00 * o.m02 + m01 * o.m12 + m02 * o.m22,
      m10 * o.m00 + m11 * o.m10 + m12 * o.m20,
      m10 * o.m01 + m11 * o.m11 + m12 * o.m21,
      m10 * o.m02 + m11 * o.m12 + m12 * o.m22,
      m20 * o.m00 + m21 * o.m10 + m22 * o.m20,
      m20 * o.m01 + m21 * o.m11 + m22 * o.m21,
      m20 * o.m02 + m21 * o.m12 + m22 * o.m22,
    );
  }

  _V3 transform(_V3 v) {
    return _V3(
      m00 * v.x + m01 * v.y + m02 * v.z,
      m10 * v.x + m11 * v.y + m12 * v.z,
      m20 * v.x + m21 * v.y + m22 * v.z,
    );
  }
}

  _M3 _rotationFromEulerForVideo(List<double> rpy) {
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

  _M3 _intrinsicForVideo(Size source, bool wideCam) {
    final sx = source.width / 1928.0;
    final sy = source.height / 1208.0;
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

  _DriveVideoPlacement _buildVideoPlacement({
    required Size source,
    required Size viewport,
    required _DriveOverlaySnapshot snapshot,
    required _DriveCameraKind cameraKind,
    required bool coverViewport,
    required double viewportZoom,
    required bool openpilotTransform,
  }) {
    final fitScale = coverViewport
        ? math.max(
            viewport.width / source.width, viewport.height / source.height)
        : math.min(
            viewport.width / source.width, viewport.height / source.height);

    final resolvedViewportZoom =
        (viewportZoom.isFinite && viewportZoom > 0.1) ? viewportZoom : 1.0;
    var scale = fitScale * resolvedViewportZoom;
    var xOffset = 0.0;
    var yOffset = 0.0;
    var dx = (viewport.width - source.width * scale) * 0.5;
    var dy = (viewport.height - source.height * scale) * 0.5;

    if (openpilotTransform) {
      final wideCam = cameraKind == _DriveCameraKind.wideRoad;
      final zoom = wideCam ? 2.0 : 1.1;
      scale = fitScale * zoom * resolvedViewportZoom;

      final intrinsic = _intrinsicForVideo(source, wideCam);
      final deviceFromCalib =
          _rotationFromEulerForVideo(snapshot.calibrationRpy);
      final wideFromDevice = wideCam
          ? _rotationFromEulerForVideo(snapshot.wideFromDeviceEuler)
          : const _M3.identity();
      final viewFromCalib = wideCam
          ? _LiveDriveCanvasScreenState._viewFromDevice
              .multiply(wideFromDevice.multiply(deviceFromCalib))
          : _LiveDriveCanvasScreenState._viewFromDevice
              .multiply(deviceFromCalib);
      final calibTransform = intrinsic.multiply(viewFromCalib);
      final inf = calibTransform.transform(const _V3(1000.0, 0.0, 0.0));
      if (inf.z.isFinite && inf.z.abs() > 1e-6) {
        final centerX = intrinsic.m02;
        final centerY = intrinsic.m12;
        final maxXOffset =
            math.max(0.0, centerX * scale - viewport.width * 0.5 - 5.0);
        final maxYOffset =
            math.max(0.0, centerY * scale - viewport.height * 0.5 - 5.0);
        xOffset = (((inf.x / inf.z) - centerX) * scale)
            .clamp(-maxXOffset, maxXOffset)
            .toDouble();
        yOffset = (((inf.y / inf.z) - centerY) * scale)
            .clamp(-maxYOffset, maxYOffset)
            .toDouble();
        dx = (viewport.width * 0.5 - xOffset) - (centerX * scale);
        dy = (viewport.height * 0.5 - yOffset) - (centerY * scale);
      } else {
        dx = (viewport.width - source.width * scale) * 0.5;
        dy = (viewport.height - source.height * scale) * 0.5;
      }
    }

    return _DriveVideoPlacement(
      left: dx,
      top: dy,
      width: source.width * scale,
      height: source.height * scale,
      scale: scale,
      xOffset: xOffset,
      yOffset: yOffset,
    );
  }
