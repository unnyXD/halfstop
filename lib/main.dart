import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'editor_page.dart';

void main() {
  // A darkroom app should not hand the status bar a bright surface.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0A0908),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const HalfstopApp());
}

/// 半档 / Halfstop.
///
/// Palette: a darkroom at night — warm black, paper white, safelight amber.
/// The accent is the only saturated colour in the app; everything else is a
/// neutral so the photograph stays the loudest thing on screen.
class HalfstopApp extends StatelessWidget {
  const HalfstopApp({super.key});

  static const Color ink = Color(0xFFEDE6DA);
  static const Color dim = Color(0xFF8C857A);
  static const Color amber = Color(0xFFE3A35C);

  @override
  Widget build(BuildContext context) {
    final base = ColorScheme.fromSeed(
      seedColor: amber,
      brightness: Brightness.dark,
    ).copyWith(
      primary: amber,
      onPrimary: const Color(0xFF1A1108),
      surface: const Color(0xFF14120F),
      onSurface: ink,
      surfaceContainerHighest: const Color(0xFF1C1916),
      outline: const Color(0xFF2A2621),
      outlineVariant: const Color(0xFF221F1B),
    );

    return MaterialApp(
      title: '半档',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: base,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0A0908),
        splashFactory: InkSparkle.splashFactory,
        textTheme: _textTheme(base),
        dividerTheme: const DividerThemeData(
          color: Color(0xFF221F1B),
          thickness: 1,
          space: 1,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: amber,
            foregroundColor: const Color(0xFF1A1108),
            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: ink,
            side: const BorderSide(color: Color(0xFF3A342C)),
            textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xFF1C1916),
          contentTextStyle: TextStyle(color: ink),
          behavior: SnackBarBehavior.floating,
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xFF14120F),
          surfaceTintColor: Colors.transparent,
          dragHandleColor: Color(0xFF3A342C),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xFF15130F),
          surfaceTintColor: Colors.transparent,
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: Color(0xFF1C1916),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const EditorPage(),
    );
  }

  /// One scale, tuned for a dark surface: slightly tighter tracking on the
  /// large sizes, tabular figures everywhere a number is compared.
  TextTheme _textTheme(ColorScheme scheme) {
    return TextTheme(
      titleLarge: const TextStyle(
        fontFamilyFallback: ['serif'],
        fontSize: 26,
        fontWeight: FontWeight.w600,
        letterSpacing: 4,
        color: ink,
        height: 1.1,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: ink,
        letterSpacing: 0.2,
      ),
      bodyMedium: TextStyle(fontSize: 14, color: ink, height: 1.35),
      bodySmall: TextStyle(fontSize: 12.5, color: dim, height: 1.4),
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: ink,
      ),
      labelMedium: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.4,
        color: dim,
      ),
      labelSmall: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: dim,
      ),
    );
  }
}
