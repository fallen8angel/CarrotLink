import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../../services/diagnostics_service.dart';
import '../../services/github_service.dart';
import '../../services/key_backup_service.dart';
import '../../services/ssh_key_helper.dart';
import '../../services/ssh_service.dart';
import '../../ui/adaptive/layout_tokens.dart';
import '../../ui/adaptive/window_class.dart';
import '../../widgets/custom_toast.dart';
import '../github_login_screen.dart';

part 'connection_settings_persistence.dart';
part 'connection_settings_keys.dart';
part 'connection_settings_auth.dart';
part 'connection_settings_discovery.dart';
part 'connection_settings_widgets.dart';

class ConnectionSettingsScreen extends StatefulWidget {
  const ConnectionSettingsScreen({super.key});

  @override
  State<ConnectionSettingsScreen> createState() =>
      _ConnectionSettingsScreenState();
}

class _ConnectionSettingsScreenState extends State<ConnectionSettingsScreen> {
  // 기본 연결 설정
  final TextEditingController _ipController = TextEditingController(text: '');
  final TextEditingController _usernameController =
      TextEditingController(text: 'comma');
  final TextEditingController _passwordController =
      TextEditingController(text: 'comma');
  final TextEditingController _portController =
      TextEditingController(text: '22');

  // 수동 키 입력용
  final TextEditingController _manualKeyController = TextEditingController();
  bool _isManualKeyEditing = false;

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final GitHubService _githubService = GitHubService();
  final KeyBackupService _keyBackupService = KeyBackupService();
  final DiagnosticsService _diag = DiagnosticsService.instance;
  SSHService? _sshRef;
  static const String _managedKeyPrefix = 'carrotpilot';
  static const String _fixedSshUsername = 'comma';
  static const int _fixedSshPort = 22;

  bool _isGitHubLoggedIn = false;
  List<Map<String, dynamic>> _keys = [];
  Map<String, bool> _localPrivateKeyAvailability = {};

  // 새로운 키 상태 관리
  String? _currentKeyType; // "manual" | "generated" | null
  String? _currentPrivateKey; // 현재 사용 중인 개인키
  String? _activeGeneratedId; // 활성화된 자동 생성 키의 GitHub ID
  String? _activeGeneratedTitle; // 활성화된 자동 생성 키 제목 (UI 표시용)

  StreamSubscription? _discoverySubscription;
  Timer? _discoveryStatusTimer;
  bool _lockDiscoveryIpOverwrite = false;
  String? _autoFilledIp;
  bool _manualDiscoverySession = false;
  final Set<String> _discoverySeenIps = <String>{};
  String _discoveryStatus = '대기';
  String _backupLocationSummary = '확인 중...';

  bool get _hasActiveSshKey =>
      _currentPrivateKey != null && _currentPrivateKey!.isNotEmpty;
  bool get _isOpenpilotReady => _hasActiveSshKey;
  void _setStateSafe(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  SSHService _getSsh() {
    final cached = _sshRef;
    if (cached != null) return cached;
    if (!mounted) {
      throw StateError('SSHService unavailable after widget dispose');
    }
    final resolved = Provider.of<SSHService>(context, listen: false);
    _sshRef = resolved;
    return resolved;
  }

  bool _isManagedKeyTitle(String title) {
    final lower = title.toLowerCase();
    return lower.startsWith(_managedKeyPrefix) ||
        lower.startsWith('carrotlink');
  }

  String _newManagedKeyTitle() =>
      '${_managedKeyPrefix}_${DateTime.now().millisecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    _migrateAndLoadSettings();
    _checkGitHubLogin();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeAutoStartDiscovery();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sshRef ??= Provider.of<SSHService>(context, listen: false);
  }

  @override
  Widget build(BuildContext context) => _buildScreen(context);

  @override
  void dispose() {
    _discoverySubscription?.cancel();
    _discoveryStatusTimer?.cancel();
    final ssh = _sshRef;
    if (ssh != null &&
        (ssh.discoverySource == 'settings_manual' ||
            ssh.discoverySource == 'settings_auto')) {
      try {
        ssh.stopDiscovery();
      } catch (_) {}
    }
    _ipController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _portController.dispose();
    _manualKeyController.dispose();
    super.dispose();
  }
}
