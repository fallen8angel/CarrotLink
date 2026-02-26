class CarrotConstants {
  // Paths
  static const String openpilotPath = "/data/openpilot";
  static const String paramsPath = "/data/params/d";
  static const String mediaPath = "/data/media/0/videos";
  
  // Commands
  static const String gitFetchCmd = "cd $openpilotPath && git fetch --all";
  static const String gitBranchCmd = "cd $openpilotPath && git rev-parse --abbrev-ref HEAD";
  static const String gitCommitCmd = "cd $openpilotPath && git rev-parse --short HEAD";
  static const String dongleIdCmd = "cat $paramsPath/DongleId";
  static const String serialCmd = "cat $paramsPath/HardwareSerial";
}
