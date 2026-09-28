class Organization {
  final String code;
  final String name;
  const Organization({required this.code, required this.name});

  static final codePattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,47}$');

  /// A QR selects a tenant, never a server, password or authenticated session.
  static String parseConnection(String input) {
    final text = input.trim();
    if (codePattern.hasMatch(text.toLowerCase())) return text.toLowerCase();
    final link = RegExp(r'^chereda://organization/([a-z0-9][a-z0-9-]{1,47})$')
        .firstMatch(text);
    if (link != null) return link.group(1)!;
    throw const FormatException(
        'Нужен QR Череды или код от администратора организации.');
  }

  String get connectionLink => 'chereda://organization/$code';

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
