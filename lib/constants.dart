class CarrotConstants {
  // Paths
  static const String openpilotPath = "/data/openpilot";
  static const String paramsPath = "/data/params/d";
  static const String mediaPath = "/data/media/0/videos";

  // Commands
  static const String gitFetchCmd = "cd $openpilotPath && git fetch --all";
  static const String gitBranchCmd =
      "cd $openpilotPath && git rev-parse --abbrev-ref HEAD";
  static const String gitCommitCmd =
      "cd $openpilotPath && git rev-parse --short HEAD";
  static const String dongleIdCmd = "cat $paramsPath/DongleId";
  static const String serialCmd = "cat $paramsPath/HardwareSerial";
  static const String deviceMetadataCmd = "sh -lc '"
      "branch=\$(cd $openpilotPath 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo Unknown); "
      "commit=\$(cd $openpilotPath 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo Unknown); "
      "dongle=\$(cat $paramsPath/DongleId 2>/dev/null || echo Unknown); "
      "serial=\$(cat $paramsPath/HardwareSerial 2>/dev/null || echo Unknown); "
      "printf \"CARROTLINK_META\\t%s\\t%s\\t%s\\t%s\\n\" \"\$branch\" \"\$commit\" \"\$dongle\" \"\$serial\""
      "'";
}
