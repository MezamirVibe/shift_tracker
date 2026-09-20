import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../shared/widgets/responsive_form_body.dart';
import 'auth_service.dart';

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
                    'Введите код, полученный у администратора вашей организации. Выбрать организацию нужно только один раз.'),
                const SizedBox(height: 20),
                TextField(
                    controller: _code,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _select(),
                    decoration: const InputDecoration(
                        labelText: 'Код организации',
                        hintText: 'Например: tehnodor-sk')),
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
}
