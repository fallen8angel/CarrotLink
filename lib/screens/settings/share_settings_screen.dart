import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ShareSettingsScreen extends StatefulWidget {
  const ShareSettingsScreen({super.key});

  @override
  State<ShareSettingsScreen> createState() => _ShareSettingsScreenState();
}

class _ShareSettingsScreenState extends State<ShareSettingsScreen> {
  bool _convertToMp4 = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _convertToMp4 = prefs.getBool('share_convert_mp4') ?? false;
    });
  }

  Future<void> _toggleConvert(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('share_convert_mp4', value);
    setState(() {
      _convertToMp4 = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('공유 설정')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('MP4로 변환하여 공유'),
            subtitle:
                const Text('공유 시 .ts 파일을 .mp4로 변환합니다. (시간이 더 소요될 수 있습니다)'),
            value: _convertToMp4,
            onChanged: _toggleConvert,
          ),
        ],
      ),
    );
  }
}
