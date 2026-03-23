enum YoloRuntimeBackend {
  liteRtNpu('litert_npu', 'LiteRT NPU'),
  liteRtGpu('litert_gpu', 'LiteRT GPU'),
  liteRtCpu('litert_cpu', 'LiteRT CPU'),
  executorchXnnpack('executorch_xnnpack', 'ExecuTorch XNNPACK');

  const YoloRuntimeBackend(this.wireValue, this.label);

  final String wireValue;
  final String label;

  bool get isLiteRt =>
      this == YoloRuntimeBackend.liteRtNpu ||
      this == YoloRuntimeBackend.liteRtGpu ||
      this == YoloRuntimeBackend.liteRtCpu;

  static const List<YoloRuntimeBackend> selectableValues = <YoloRuntimeBackend>[
    YoloRuntimeBackend.liteRtNpu,
    YoloRuntimeBackend.liteRtGpu,
    YoloRuntimeBackend.liteRtCpu,
    YoloRuntimeBackend.executorchXnnpack,
  ];

  static YoloRuntimeBackend fromWireValue(String? raw) {
    final normalized = raw?.trim().toLowerCase();
    for (final backend in values) {
      if (backend.wireValue == normalized) {
        return backend;
      }
    }
    return YoloRuntimeBackend.liteRtGpu;
  }
}
