class AppRelease {
  final String version;
  final int build;
  final Uri url;
  final String sha256;
  final int size;
  final List<String> notes;

  const AppRelease(
      {required this.version,
      required this.build,
      required this.url,
      required this.sha256,
      required this.size,
      required this.notes});

  static const maxSize = 250 * 1024 * 1024;
  static final metadataUrl =
      Uri.parse('https://api.mezamir.com/updates/stable.json');

  static bool trustedUrl(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'api.mezamir.com' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty &&
      uri.path.startsWith('/updates/') &&
      !uri.pathSegments.any((part) =>
          part == '..' ||
          part == '.' ||
          part.contains('\\') ||
          part.contains('/') ||
          part.contains('%'));

  factory AppRelease.fromManifest(Object? data, String platform) {
    if (data is! Map ||
        data['schema'] != 1 ||
        !const ['android', 'windows'].contains(platform)) {
      throw const FormatException('Неподдерживаемый формат обновления.');
    }
    final item = data[platform];
    if (item is! Map) {
      throw const FormatException('Нет сборки для этой платформы.');
    }
    final version = item['version'];
    final build = item['build'];
    final hash = item['sha256'];
    final size = item['size'];
    final notes = item['notes'];
    final url =
        Uri.tryParse(item['url'] is String ? item['url'] as String : '');
    if (version is! String ||
        !RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$').hasMatch(version) ||
        build is! int ||
        build < 1 ||
        build > 2147483647 ||
        hash is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash) ||
        size is! int ||
        size < 1 ||
        size > maxSize ||
        notes is! List ||
        notes.length > 20 ||
        notes.any((n) => n is! String || n.length > 1000) ||
        url == null ||
        !trustedUrl(url) ||
        !url.path.endsWith(platform == 'android' ? '.apk' : '.zip')) {
      throw const FormatException('Некорректные данные обновления.');
    }
    return AppRelease(
        version: version,
        build: build,
        url: url,
        sha256: hash.toLowerCase(),
        size: size,
        notes: List<String>.from(notes));
  }
}
