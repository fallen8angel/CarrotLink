enum YoloRuntimeBackend {
  executorchQnn('executorch_qnn', 'ExecuTorch QNN'),
  executorchXnnpack('executorch_xnnpack', 'ExecuTorch XNNPACK');

  const YoloRuntimeBackend(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static YoloRuntimeBackend fromWireValue(String? raw) {
    final normalized = raw?.trim().toLowerCase();
    for (final backend in values) {
      if (backend.wireValue == normalized) {
        return backend;
      }
    }
    return YoloRuntimeBackend.executorchQnn;
  }
}
