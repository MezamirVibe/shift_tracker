import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
  static const _positionsFile = 'positions.json';

  Future<File> _file(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  Future<List<PositionModel>> loadPositions() async {
    try {
      final f = await _file(_positionsFile);
      if (!await f.exists()) return [];
      final text = await f.readAsString();
      if (text.trim().isEmpty) return [];
      final data = jsonDecode(text) as List;
      final items =
          data.map((e) => PositionModel.fromJson(e as Map)).toList();

      items.sort((a, b) => a.name.compareTo(b.name));
      return items;
    } catch (_) {
      return [];
    }
  }

  Future<void> savePositions(List<PositionModel> items) async {
    final f = await _file(_positionsFile);
    await f.writeAsString(
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }
}