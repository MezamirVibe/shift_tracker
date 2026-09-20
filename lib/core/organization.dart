class Organization {
  final String code;
  final String name;
  const Organization({required this.code, required this.name});

  static final codePattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,47}$');

  factory Organization.fromJson(Map<String, dynamic> json) {
    final code = json['code'];
    final name = json['name'];
    if (code is! String ||
        !codePattern.hasMatch(code) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 200) {
      throw const FormatException('Некорректные данные организации');
    }
    return Organization(code: code, name: name);
  }

  Map<String, String> toJson() => {'code': code, 'name': name};
}
