enum YoloRuntimeBackend {
  liteRtGpu('litert_gpu', 'LiteRT GPU'),
  liteRtCpu('litert_cpu', 'LiteRT CPU'),
  executorchXnnpack('executorch_xnnpack', 'ExecuTorch XNNPACK'),
  // Deprecated: QNN HTP blocked by /dev/fastrpc-cdsp DAC permission on Galaxy.
  executorchQnn('executorch_qnn', 'ExecuTorch QNN (deprecated)');

  const YoloRuntimeBackend(this.wireValue, this.label);

  final String wireValue;
  final String label;

  bool get isLiteRt =>
      this == YoloRuntimeBackend.liteRtGpu ||
      this == YoloRuntimeBackend.liteRtCpu;

  bool get isQnn => this == YoloRuntimeBackend.executorchQnn;

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
