import '../../core/api_client.dart';

class PositionModel {
  final String id;
  final String name;

  const PositionModel({
    required this.id,
    required this.name,
  });

  PositionModel copyWith({
    String? name,
  }) {
    return PositionModel(
      id: id,
      name: name ?? this.name,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
      };

  static PositionModel fromJson(Map json) {
    return PositionModel(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
    );
  }
}

class PositionsStorage {
  Future<List<PositionModel>> loadPositions() async {
    final data =
        await ApiClient.instance.request('GET', '/api/v1/positions') as List;
    final items = data.whereType<Map>().map((item) {
      final json = Map<String, dynamic>.from(item);
      return PositionModel(
          id: json['id'] as String, name: json['name'] as String);
    }).toList();
    items.sort((a, b) => a.name.compareTo(b.name));
    return items;
  }

  Future<void> savePositions(List<PositionModel> items) async {
    final existing = {for (final item in await loadPositions()) item.id: item};
    final wanted = {for (final item in items) item.id: item};
    for (final item in items) {
      await ApiClient.instance.request(
        existing.containsKey(item.id) ? 'PATCH' : 'POST',
        existing.containsKey(item.id)
            ? '/api/v1/positions/${item.id}'
            : '/api/v1/positions',
        body: {'id': item.id, 'name': item.name},
      );
    }
    for (final id in existing.keys.where((id) => !wanted.containsKey(id))) {
      await ApiClient.instance.request('DELETE', '/api/v1/positions/$id');
    }
  }
}
