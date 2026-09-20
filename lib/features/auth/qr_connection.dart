import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:zxing2/qrcode.dart' as zx;
import '../../core/organization.dart';

/// Decode locally, without uploading the invitation image to a service.
String decodeConnectionImage(Uint8List bytes) {
  try {
    return _decodeConnectionImage(bytes);
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException(
        'Не удалось прочитать изображение QR. Выберите другой файл.');
  }
}

String _decodeConnectionImage(Uint8List bytes) {
  if (bytes.length > 8 * 1024 * 1024) {
    throw const FormatException('Изображение должно быть не больше 8 МБ.');
  }
  if (bytes.length < 16 ||
      !((bytes[0] == 137 &&
              bytes[1] == 80 &&
              bytes[2] == 78 &&
              bytes[3] == 71) ||
          (bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255))) {
    throw const FormatException('Нужна картинка PNG или JPG.');
  }
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > 16000000) {
    throw const FormatException(
        'Нужна картинка PNG или JPG размером до 16 мегапикселей.');
  }
  var picture = decoder!.decodeFrame(0);
  if (picture == null) {
    throw const FormatException('Не удалось прочитать картинку.');
  }
  if (picture.width > 1600 || picture.height > 1600) {
    picture = img.copyResize(picture,
        width: picture.width >= picture.height ? 1600 : null,
        height: picture.height > picture.width ? 1600 : null);
  }
  final pixels =
      picture.convert(numChannels: 4).getBytes(order: img.ChannelOrder.abgr);
  final source = zx.RGBLuminanceSource(
      picture.width, picture.height, pixels.buffer.asInt32List());
  try {
    final result =
        zx.QRCodeReader().decode(zx.BinaryBitmap(zx.HybridBinarizer(source)));
    Organization.parseConnection(result.text);
    return result.text;
  } catch (_) {
    throw const FormatException(
        'QR Череды не найден. Выберите чёткую картинку с кодом целиком.');
  }
}

Future<String?> pickConnectionImage() async {
  final file = await openFile(acceptedTypeGroups: [
    const XTypeGroup(
        label: 'QR-код',
        extensions: ['png', 'jpg', 'jpeg'],
        mimeTypes: ['image/png', 'image/jpeg'])
  ]);
  if (file == null) return null;
  if (await file.length() > 8 * 1024 * 1024) {
    throw const FormatException('Изображение должно быть не больше 8 МБ.');
  }
  return compute(decodeConnectionImage, await file.readAsBytes());
}

class ConnectionScannerPage extends StatefulWidget {
  const ConnectionScannerPage({super.key});
  @override
  State<ConnectionScannerPage> createState() => _ConnectionScannerPageState();
}

class _ConnectionScannerPageState extends State<ConnectionScannerPage>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _done = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.hasCameraPermission || _done) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.start());
    } else {
      unawaited(_controller.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final text = barcode.rawValue;
      if (text == null) continue;
      try {
        Organization.parseConnection(text);
        _done = true;
        Navigator.pop(context, text);
        return;
      } on FormatException {
        setState(() =>
            _error = 'Это не QR Череды. Наведите камеру на код организации.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Сканировать QR')),
        body: SafeArea(
            child: Column(children: [
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error ??
                  'Наведите камеру на QR-код, полученный у администратора.')),
          Expanded(
              child: MobileScanner(
            controller: _controller,
            onDetect: _detected,
            errorBuilder: (context, error) => const Center(
                child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                  'Камера недоступна. Разрешите доступ к ней в настройках телефона или вернитесь и выберите картинку с QR-кодом.'),
            )),
          )),
          Padding(
              padding: const EdgeInsets.all(12),
              child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Вставить код вместо сканирования'))),
        ])),
      );
}

Future<void> showOrganizationConnection(
    BuildContext context, Organization organization) async {
  await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
            scrollable: true,
            title: const Text('Подключение к организации'),
            content: SizedBox(
                width: 360,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(organization.name, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  Semantics(
                      label: 'QR-код подключения к организации',
                      child: QrImageView(
                        data: organization.connectionLink,
                        size: 220,
                        backgroundColor: Colors.white,
                      )),
                  const SizedBox(height: 12),
                  const Text(
                      'Отсканируйте QR в Череде или вставьте ссылку. После подключения потребуются личные логин и пароль.'),
                  const SizedBox(height: 12),
                  SelectableText(organization.connectionLink),
                ])),
            actions: [
              TextButton(
                  onPressed: () async {
                    await Clipboard.setData(
                        ClipboardData(text: organization.connectionLink));
                    if (dialogContext.mounted) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(content: Text('Ссылка скопирована')));
                    }
                  },
                  child: const Text('Копировать ссылку')),
              TextButton(
                  onPressed: () async {
                    try {
                      final painter = QrPainter(
                          data: organization.connectionLink,
                          version: QrVersions.auto,
                          gapless: false,
                          eyeStyle: const QrEyeStyle(color: Colors.black),
                          dataModuleStyle:
                              const QrDataModuleStyle(color: Colors.black));
                      final recorder = ui.PictureRecorder();
                      final canvas = Canvas(recorder);
                      canvas.drawRect(const Rect.fromLTWH(0, 0, 720, 720),
                          Paint()..color = Colors.white);
                      canvas.translate(40, 40);
                      painter.paint(canvas, const Size(640, 640));
                      final picture = recorder.endRecording();
                      final image = await picture.toImage(720, 720);
                      final data = await image.toByteData(
                          format: ui.ImageByteFormat.png);
                      image.dispose();
                      picture.dispose();
                      if (data == null || !dialogContext.mounted) return;
                      final bytes = data.buffer.asUint8List();
                      final file = XFile.fromData(bytes,
                          name: 'chereda-qr.png', mimeType: 'image/png');
                      if (Platform.isAndroid || Platform.isIOS) {
                        final box =
                            dialogContext.findRenderObject() as RenderBox?;
                        await Share.shareXFiles([file],
                            fileNameOverrides: ['chereda-qr.png'],
                            text:
                                '${organization.name}\n${organization.connectionLink}',
                            sharePositionOrigin: box == null
                                ? null
                                : box.localToGlobal(Offset.zero) & box.size);
                      } else {
                        final target = await getSaveLocation(
                            suggestedName: 'chereda-qr.png',
                            acceptedTypeGroups: [
                              const XTypeGroup(
                                  label: 'QR-код', extensions: ['png'])
                            ]);
                        if (target != null) await file.saveTo(target.path);
                      }
                    } catch (_) {
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Не удалось сохранить QR. Можно скопировать ссылку.')));
                      }
                    }
                  },
                  child: const Text('Сохранить QR')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Готово')),
            ],
          ));
}
