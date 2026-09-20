import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../shared/widgets/responsive_form_body.dart';
import 'auth_service.dart';
import 'qr_connection.dart';
import 'dart:io';
import 'package:flutter/services.dart';

class OrganizationPage extends StatefulWidget {
  const OrganizationPage({super.key});
  @override
  State<OrganizationPage> createState() => _OrganizationPageState();
}

class _OrganizationPageState extends State<OrganizationPage> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _select() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.selectOrganization(_code.text);
      if (mounted) context.go('/login');
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _error = error.statusCode == 404
            ? 'Организация не найдена. Проверьте код у администратора.'
            : error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Не удалось подключиться. Проверьте интернет и попробуйте снова.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Ваша организация')),
        body: ResponsiveFormBody(
            child: Card(
                child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.apartment_outlined, size: 48),
                const SizedBox(height: 16),
                Text('Добро пожаловать в Череду',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text(
                    'Получите QR-код или ссылку у администратора. Подключение нужно только на новом устройстве. Для входа понадобятся ваши логин и пароль.'),
                const SizedBox(height: 20),
                if (Platform.isAndroid ||
                    Platform.isIOS ||
                    Platform.isMacOS) ...[
                  OutlinedButton.icon(
                      onPressed: _busy ? null : () => _readQr(camera: true),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Сканировать QR')),
                  const SizedBox(height: 8),
                ],
                TextButton.icon(
                    onPressed: _busy ? null : _readQr,
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('Выбрать картинку с QR')),
                const SizedBox(height: 12),
                TextField(
                    controller: _code,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _select(),
                    decoration: InputDecoration(
                        labelText: 'Ссылка или код',
                        suffixIcon: IconButton(
                            tooltip: 'Вставить из буфера',
                            onPressed: _busy
                                ? null
                                : () async {
                                    final data = await Clipboard.getData(
                                        Clipboard.kTextPlain);
                                    if (mounted && data?.text != null) {
                                      _code.text = data!.text!;
                                    }
                                  },
                            icon: const Icon(Icons.content_paste)))),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error))
                ],
                const SizedBox(height: 20),
                FilledButton(
                    onPressed: _busy ? null : _select,
                    child: Text(_busy ? 'Подключаемся…' : 'Продолжить')),
              ]),
        ))),
      );

  Future<void> _readQr({bool camera = false}) async {
    if (_busy) return;
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!mounted) return;
      final value = camera
          ? await navigator.push<String>(
              MaterialPageRoute(builder: (_) => const ConnectionScannerPage()))
          : await pickConnectionImage();
      if (value != null && mounted) _code.text = value;
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Не удалось прочитать QR. Вставьте ссылку или код вручную.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
