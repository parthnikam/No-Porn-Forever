import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/app_theme.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: AppColors.skyDeep,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const NoPornForeverApp());
}

class NoPornForeverApp extends StatelessWidget {
  const NoPornForeverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NoPornForever',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomeScreen(),
    );
  }
}
