import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart' as zx;
import 'package:shift_tracker/core/organization.dart';
import 'package:shift_tracker/features/auth/qr_connection.dart';

void main() {
  test('QR connection never changes server or authenticates a user', () {
    expect(Organization.parseConnection(' company-a '), 'company-a');
    expect(Organization.parseConnection('chereda://organization/company-a'),
        'company-a');
    for (final input in [
      'https://evil.invalid/company-a',
      'chereda://organization/company-a?token=secret',
      'chereda://organization@evil.invalid/company-a',
      'chereda://organization:443/company-a',
      'chereda://organization/../company-a',
      'chereda://organization/%63ompany-a',
      'a',
      ''
    ]) {
      expect(() => Organization.parseConnection(input), throwsFormatException,
          reason: input);
    }
  });
  test('locally generated QR image decodes with whitespace border', () {
    const link = 'chereda://organization/company-a';
    final matrix = zx.Encoder.encode(link, zx.ErrorCorrectionLevel.m).matrix!;
    final picture = img.Image(
        width: (matrix.width + 8) * 8, height: (matrix.height + 8) * 8);
    img.fill(picture, color: img.ColorRgb8(255, 255, 255));
    for (int x = 0; x < matrix.width; x++) {
      for (int y = 0; y < matrix.height; y++) {
        if (matrix.get(x, y) == 1) {
          img.fillRect(picture,
              x1: (x + 4) * 8,
              y1: (y + 4) * 8,
              x2: (x + 5) * 8 - 1,
              y2: (y + 5) * 8 - 1,
              color: img.ColorRgb8(0, 0, 0));
        }
      }
    }
    expect(decodeConnectionImage(img.encodePng(picture)), link);
    expect(() => decodeConnectionImage(Uint8List.fromList([1, 2, 3])),
        throwsFormatException);
  });
}
