import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as path;

class GoogleDriveService extends ChangeNotifier {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [drive.DriveApi.driveFileScope],
  );

  GoogleSignInAccount? _currentUser;
  GoogleSignInAccount? get currentUser => _currentUser;

  GoogleDriveService() {
    _googleSignIn.onCurrentUserChanged.listen((account) {
      _currentUser = account;
      notifyListeners();
    });
    _googleSignIn.signInSilently();
  }

  Future<GoogleSignInAccount?> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      return account;
    } catch (e) {
      print('Google Sign In Error: $e');
      rethrow;
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.disconnect();
  }

  Future<drive.DriveApi?> getDriveApi() async {
    final account = _currentUser ?? await _googleSignIn.signInSilently();
    if (account == null) return null;

    final httpClient = await _googleSignIn.authenticatedClient();
    if (httpClient == null) return null;

    return drive.DriveApi(httpClient);
  }

  Future<String> _getOrCreateBackupFolder(drive.DriveApi api) async {
    const folderName = "CarrotLink_Backups";
    const q =
        "mimeType = 'application/vnd.google-apps.folder' and name = '$folderName' and trashed = false";
    final list = await api.files.list(q: q);

    if (list.files != null && list.files!.isNotEmpty) {
      return list.files!.first.id!;
    }

    final folder = drive.File()
      ..name = folderName
      ..mimeType = 'application/vnd.google-apps.folder';

    final created = await api.files.create(folder);
    return created.id!;
  }

  Future<void> uploadFile(File file) async {
    final api = await getDriveApi();
    if (api == null) throw Exception("Google Drive API unavailable");

    final folderId = await _getOrCreateBackupFolder(api);
    final fileName = path.basename(file.path);
    final media = drive.Media(file.openRead(), file.lengthSync());

    final driveFile = drive.File()
      ..name = fileName
      ..parents = [folderId];

    await api.files.create(driveFile, uploadMedia: media);
  }

  Future<List<drive.File>> listFiles() async {
    final api = await getDriveApi();
    if (api == null) throw Exception("Google Drive API unavailable");

    String? folderId;
    try {
      folderId = await _getOrCreateBackupFolder(api);
    } catch (e) {
      print("Error getting folder: $e");
      // If we can't find/create the folder, we shouldn't list random files from root.
      return [];
    }

    // Strictly search inside the folder
    final q = "'$folderId' in parents and trashed = false";

    final fileList = await api.files.list(
      q: q,
      $fields: 'files(id, name, createdTime, size)',
    );

    return fileList.files ?? [];
  }

  Future<void> downloadFile(String fileId, String savePath) async {
    final api = await getDriveApi();
    if (api == null) throw Exception("Google Drive API unavailable");

    final media = await api.files.get(fileId,
        downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
    final file = File(savePath);
    final sink = file.openWrite();

    await media.stream.pipe(sink);
    await sink.close();
  }

  Future<void> deleteFile(String fileId) async {
    final api = await getDriveApi();
    if (api == null) throw Exception("Google Drive API unavailable");

    await api.files.delete(fileId);
  }
}
