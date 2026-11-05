import 'package:flutter/material.dart';

import 'editor_page.dart';

void main() {
  runApp(const SpektraApp());
}

class SpektraApp extends StatelessWidget {
  const SpektraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spektrafilm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE0A458),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0C0F),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B0C0F),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE0A458),
            foregroundColor: const Color(0xFF20160A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xFF2A2E37),
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const EditorPage(),
    );
  }
}
