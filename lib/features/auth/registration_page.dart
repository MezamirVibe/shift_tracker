import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/id.dart';
import '../../shared/widgets/responsive_form_body.dart';
import 'auth_service.dart';

class RegistrationPage extends StatefulWidget {
  const RegistrationPage({super.key});
  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

class _RegistrationPageState extends State<RegistrationPage> {
  final _name = TextEditingController();
  final _login = TextEditingController();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  final _form = GlobalKey<FormState>();
  Map<String, dynamic>? _ticket;
  Map<String, dynamic>? _result;
  String? _error;
  bool _busy = true;
  bool _polling = false;
  Timer? _timer;
  int _pollsRemaining = 60;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final ticket = await ApiClient.instance.pendingRegistration();
      if (!mounted) return;
      setState(() {
        _ticket = ticket;
        _busy = false;
      });
      if (ticket != null) await _check();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              'Не удалось прочитать состояние регистрации. Попробуйте снова.';
        });
      }
    }
  }

  Future<void> _create() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final random = Random.secure();
    _ticket ??= {
      'request_id': newUuidV4(),
      'claim_secret': List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    };
    try {
      // Save only the opaque recovery ticket, never the owner's password.
      await ApiClient.instance.savePendingRegistration(_ticket);
      final result = await ApiClient.instance.registerOrganization({
        ..._ticket!,
        'name': _name.text.trim(),
        'login': _login.text.trim(),
        'password': _password.text,
      });
      _password.clear();
      _repeat.clear();
      if (mounted) setState(() => _result = result);
      _schedule();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (mounted &&
        _result != null &&
        _pollsRemaining > 0 &&
        !['ready', 'failed'].contains(_result!['status'])) {
      _pollsRemaining--;
      _timer = Timer(const Duration(seconds: 5), _check);
    }
  }

  Future<void> _check() async {
    if (_polling || _ticket == null) return;
    _polling = true;
    try {
      final result = await ApiClient.instance.registerOrganization(
        _ticket!,
        status: true,
      );
      if (mounted) {
        setState(() {
          _result = result;
          _error = null;
        });
      }
    } on ApiException catch (error) {
      // A failed submission may not have reached the server. Keep the same ticket for retry.
      if (error.statusCode == 404) {
        await ApiClient.instance.savePendingRegistration(null);
        if (mounted) {
          setState(() {
            _result = null;
            _ticket = null;
          });
        }
      } else if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось проверить готовность. Нажмите «Проверить» после восстановления связи.',
        );
      }
    } finally {
      _polling = false;
      _schedule();
    }
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.selectOrganization(_result!['code'] as String);
      await ApiClient.instance.savePendingRegistration(null);
      if (mounted) context.go('/login');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _name.dispose();
    _login.dispose();
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _result?['status'] == 'ready';
    final failed = _result?['status'] == 'failed';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Создать организацию'),
        leading: BackButton(onPressed: () => context.go('/organization')),
      ),
      body: ResponsiveFormBody(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_result == null)
                  Form(
                    key: _form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Вы станете владельцем новой организации. Она будет пустой и отдельной от других. Одобрение не требуется.',
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _name,
                          enabled: !_busy,
                          maxLength: 200,
                          decoration: const InputDecoration(
                            labelText: 'Название организации',
                          ),
                          validator: (v) => (v?.trim().length ?? 0) < 2
                              ? 'Введите название'
                              : null,
                        ),
                        TextFormField(
                          controller: _login,
                          enabled: !_busy,
                          maxLength: 80,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Ваш логин',
                            helperText: 'Латинские буквы, цифры, точка, дефис',
                          ),
                          validator: (v) => RegExp(
                            r'^[a-zA-Z0-9_.-]{3,80}$',
                          ).hasMatch(v?.trim() ?? '')
                              ? null
                              : 'Не менее 3 символов латиницей',
                        ),
                        TextFormField(
                          controller: _password,
                          enabled: !_busy,
                          obscureText: true,
                          maxLength: 128,
                          decoration: const InputDecoration(
                            labelText: 'Пароль владельца',
                          ),
                          validator: (v) => (v?.length ?? 0) < 12
                              ? 'Не менее 12 символов'
                              : null,
                        ),
                        TextFormField(
                          controller: _repeat,
                          enabled: !_busy,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Повторите пароль',
                          ),
                          validator: (v) => v != _password.text
                              ? 'Пароли не совпадают'
                              : null,
                        ),
                      ],
                    ),
                  )
                else ...[
                  Icon(
                    ready
                        ? Icons.check_circle_outline
                        : failed
                            ? Icons.error_outline
                            : Icons.hourglass_empty,
                    size: 40,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    ready
                        ? 'Организация готова'
                        : failed
                            ? 'Не удалось завершить создание'
                            : 'Создаём вашу организацию',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text('${_result!['name']}'),
                  const SizedBox(height: 8),
                  Text(
                    ready
                        ? 'Ваш логин: ${_result!['login']}. Войдите с заданным при регистрации паролем.'
                        : failed
                            ? 'Ваши данные не попали в другую организацию. Сообщите поддержке номер регистрации: ${_result!['request_id']}'
                            : 'Обычно это занимает около минуты. Можно закрыть приложение и вернуться через «Создать организацию».',
                  ),
                  if (ready) ...[
                    const SizedBox(height: 12),
                    SelectableText('Код подключения: ${_result!['code']}'),
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(
                          text: 'chereda://organization/${_result!['code']}',
                        ),
                      ),
                      icon: const Icon(Icons.copy),
                      label: const Text('Скопировать ссылку организации'),
                    ),
                  ],
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                if (_result == null)
                  FilledButton(
                    onPressed: _busy ? null : _create,
                    child: Text(
                      _busy ? 'Подождите…' : 'Зарегистрировать организацию',
                    ),
                  )
                else if (ready)
                  FilledButton(
                    onPressed: _busy ? null : _open,
                    child: const Text('Войти в свою организацию'),
                  )
                else if (!failed)
                  OutlinedButton(
                    onPressed: _check,
                    child: const Text('Проверить готовность'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
