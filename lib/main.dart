import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'app/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Инициализируем русскую локаль для DateFormat (yMMMM и т.п.)
  Intl.defaultLocale = 'ru_RU';
  await initializeDateFormatting('ru_RU', null);

  runApp(const ShiftTrackerApp());
}
