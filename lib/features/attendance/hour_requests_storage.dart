import '../../core/api_client.dart';
import '../../shared/formatters/work_duration_formatter.dart';

String requestDateLabel(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.${day.year}';

class HourRequest {
  final String id;
  final String employeeId;
  final String fullName;
  final DateTime day;
  final int additionalMinutes;
  final int baseMinutes;
  final int? appliedMinutes;
  final String reason;
  final String status;
  final String? reviewComment;
  final DateTime? createdAt;
  final DateTime? reviewedAt;

  HourRequest.fromJson(Map data)
      : id = data['id'] as String,
        employeeId = data['employee_id'] as String,
        fullName = data['full_name'] as String? ?? '',
        day = DateTime.parse(data['day'] as String),
        additionalMinutes = (data['additional_minutes'] as num).toInt(),
        baseMinutes = (data['base_minutes'] as num).toInt(),
        appliedMinutes = (data['applied_minutes'] as num?)?.toInt(),
        reason = data['reason'] as String? ?? '',
        status = data['status'] as String,
        reviewComment = data['review_comment'] as String?,
        createdAt = DateTime.tryParse(data['created_at'] as String? ?? ''),
        reviewedAt = DateTime.tryParse(data['reviewed_at'] as String? ?? '');

  bool get pending => status == 'pending';
  String get dayLabel => requestDateLabel(day);
  String get statusLabel => switch (status) {
        'approved' => 'Одобрено · часы добавлены',
        'rejected' => 'Отклонено',
        'cancelled' => 'Отменено',
        _ => 'Ожидает решения',
      };
  String get daySummary =>
      'Запрошено +${formatWorkDuration(additionalMinutes)} — ${statusLabel.toLowerCase()}';
}

class HourRequestPage {
  final List<HourRequest> items;
  final String? nextCursor;
  final int pendingCount;
  const HourRequestPage(this.items, this.nextCursor, this.pendingCount);
}

class HourRequestPreview {
  final HourRequest request;
  final Map<String, dynamic> baseline;
  final Map<String, dynamic> current;
  final int proposedMinutes;
  final bool hoursChanged;
  final List<Map<String, dynamic>> changes;
  final String revision;

  HourRequestPreview.fromJson(Map data)
      : request = HourRequest.fromJson(data['request'] as Map),
        baseline = Map<String, dynamic>.from(data['baseline'] as Map),
        current = Map<String, dynamic>.from(data['current'] as Map),
        proposedMinutes = (data['proposed_minutes'] as num).toInt(),
        hoursChanged = data['hours_changed'] == true,
        changes = (data['changes'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        revision = data['revision'] as String;
}

/// No cross-account cache: every read is checked by the scoped API.
class HourRequestsStorage {
  static Future<HourRequestPage> load({
    String status = 'all',
    DateTime? day,
    DateTime? from,
    DateTime? to,
    String? cursor,
    int pageSize = 30,
  }) async {
    String iso(DateTime value) => value.toIso8601String().split('T').first;
    final query = Uri(queryParameters: {
      'status': status,
      'page_size': '$pageSize',
      if (day != null) 'day': iso(day),
      if (from != null) 'date_from': iso(from),
      if (to != null) 'date_to': iso(to),
      if (cursor != null) 'cursor': cursor,
    }).query;
    final data = await ApiClient.instance
        .request('GET', '/api/v1/hour-requests/page?$query') as Map;
    return HourRequestPage(
      (data['items'] as List)
          .map((e) => HourRequest.fromJson(e as Map))
          .toList(),
      data['next_cursor'] as String?,
      (data['pending_count'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<List<HourRequest>> forDay(DateTime day) async {
    final items = <HourRequest>[];
    String? cursor;
    do {
      final page = await load(day: day, cursor: cursor);
      items.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null);
    return items;
  }

  static Future<HourRequestPreview> preview(String id) async =>
      HourRequestPreview.fromJson(await ApiClient.instance
          .request('GET', '/api/v1/hour-requests/$id/preview') as Map);
}
