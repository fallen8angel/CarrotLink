import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static const Color carrotOrange = Color(0xFFFF6D00);
  static const Color carrotOrangeLight = Color(0xFFFF9E40);
  static const Color carrotOrangeDark = Color(0xFFC43C00);
  static const Color darkBackground = Color(0xFF1E1E1E);
  static const Color lightBackground = Color(0xFFFFF8E1); // Creamy background

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: carrotOrange,
        brightness: Brightness.light,
        background: lightBackground,
        primary: carrotOrange,
        secondary: carrotOrangeDark,
      ),
      textTheme: GoogleFonts.notoSansTextTheme(),
      appBarTheme: const AppBarTheme(
        backgroundColor: carrotOrange,
        foregroundColor: Colors.white,
        centerTitle: true,
        scrolledUnderElevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: carrotOrange,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: carrotOrange,
        foregroundColor: Colors.white,
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: carrotOrange,
        brightness: Brightness.dark,
        background: darkBackground,
        primary: carrotOrange,
        secondary: carrotOrangeLight,
      ),
      textTheme: GoogleFonts.notoSansTextTheme(ThemeData.dark().textTheme),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: carrotOrange,
        centerTitle: true,
        scrolledUnderElevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: carrotOrange,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: carrotOrange,
        foregroundColor: Colors.white,
      ),
    );
  }
}
