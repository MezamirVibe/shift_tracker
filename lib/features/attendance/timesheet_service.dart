import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/api_client.dart';

class TimesheetService {
  Future<Map<String, dynamic>> load(int year, int month) async {
    final result = await ApiClient.instance
        .request('GET', '/api/v1/reports/month?year=$year&month=$month');
    return Map<String, dynamic>.from(result as Map);
  }

  Future<String?> save(
          {required int year,
          required int month,
          String? departmentId,
          String? groupId,
          required Rect shareOrigin}) =>
      _export(
          year: year,
          month: month,
          departmentId: departmentId,
          groupId: groupId,
          shareOrigin: shareOrigin,
          share: Platform.isAndroid || Platform.isIOS);

  Future<String?> share(
          {required int year,
          required int month,
          String? departmentId,
          String? groupId,
          required Rect shareOrigin}) =>
      _export(
          year: year,
          month: month,
          departmentId: departmentId,
          groupId: groupId,
          shareOrigin: shareOrigin,
          share: true);

  Future<String?> _export(
      {required int year,
      required int month,
      String? departmentId,
      String? groupId,
      required Rect shareOrigin,
      required bool share}) async {
    final query = Uri(queryParameters: {
      'year': '$year',
      'month': '$month',
      if (departmentId != null) 'department_id': departmentId,
      if (groupId != null) 'group_id': groupId
    }).query;
    final bytes = await ApiClient.instance
            .request('GET', '/api/v1/reports/month.xlsx?$query', binary: true)
        as Uint8List;
    final name = 'Табель_${year}_${month.toString().padLeft(2, '0')}.xlsx';
    const mime =
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    if (share && !Platform.isLinux) {
      final directory = await getTemporaryDirectory();
      final folder = await Directory('${directory.path}/timesheets')
          .create(recursive: true);
      final exportFolder = await folder.createTemp('share_');
      final file = File('${exportFolder.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      final result = await Share.shareXFiles([XFile(file.path, mimeType: mime)],
          fileNameOverrides: [name],
          subject: 'Табель ${month.toString().padLeft(2, '0')}.$year',
          sharePositionOrigin: shareOrigin);
      return result.status == ShareResultStatus.dismissed
          ? null
          : 'Открыто меню сохранения и отправки';
    }
    final destination =
        await getSaveLocation(suggestedName: name, acceptedTypeGroups: [
      const XTypeGroup(label: 'Excel', extensions: ['xlsx'])
    ]);
    if (destination == null) return null;
    // Save to the exact path confirmed by the system dialog (including overwrite confirmation).
    final path = destination.path;
    await XFile.fromData(bytes, name: name, mimeType: mime).saveTo(path);
    return 'Табель сохранён: $path';
  }
}
