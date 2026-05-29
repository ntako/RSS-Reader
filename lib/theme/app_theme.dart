import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Palette calda e editoriale
  static const Color background   = Color(0xFF0F0E0C);
  static const Color surface      = Color(0xFF1A1917);
  static const Color surfaceHigh  = Color(0xFF242220);
  static const Color accent       = Color(0xFFD4A853);   // ambra calda
  static const Color accentSoft   = Color(0xFFE8C98A);
  static const Color textPrimary  = Color(0xFFF0EDE6);
  static const Color textSecondary = Color(0xFF9A9589);
  static const Color textMuted    = Color(0xFF5C5852);
  static const Color divider      = Color(0xFF2A2825);
  static const Color error        = Color(0xFFB85C38);
  static const Color success      = Color(0xFF6B9E6B);

  static ThemeData get dark {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: accentSoft,
        surface: surface,
        error: error,
        onPrimary: background,
        onSecondary: background,
        onSurface: textPrimary,
      ),
      textTheme: GoogleFonts.loraTextTheme(ThemeData.dark().textTheme).copyWith(
        displayLarge: GoogleFonts.playfairDisplay(
          fontSize: 32, fontWeight: FontWeight.w700,
          color: textPrimary, letterSpacing: -0.5,
        ),
        displayMedium: GoogleFonts.playfairDisplay(
          fontSize: 26, fontWeight: FontWeight.w600,
          color: textPrimary, letterSpacing: -0.3,
        ),
        headlineLarge: GoogleFonts.playfairDisplay(
          fontSize: 22, fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        headlineMedium: GoogleFonts.playfairDisplay(
          fontSize: 18, fontWeight: FontWeight.w500,
          color: textPrimary,
        ),
        titleLarge: GoogleFonts.lora(
          fontSize: 16, fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        titleMedium: GoogleFonts.lora(
          fontSize: 14, fontWeight: FontWeight.w500,
          color: textPrimary,
        ),
        bodyLarge: GoogleFonts.lora(
          fontSize: 16, fontWeight: FontWeight.w400,
          color: textPrimary, height: 1.75,
        ),
        bodyMedium: GoogleFonts.lora(
          fontSize: 14, fontWeight: FontWeight.w400,
          color: textSecondary, height: 1.6,
        ),
        bodySmall: GoogleFonts.spaceGrotesk(
          fontSize: 12, fontWeight: FontWeight.w400,
          color: textMuted, letterSpacing: 0.3,
        ),
        labelLarge: GoogleFonts.spaceGrotesk(
          fontSize: 13, fontWeight: FontWeight.w600,
          color: accent, letterSpacing: 0.8,
        ),
        labelMedium: GoogleFonts.spaceGrotesk(
          fontSize: 11, fontWeight: FontWeight.w500,
          color: textMuted, letterSpacing: 0.5,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.playfairDisplay(
          fontSize: 20, fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        iconTheme: const IconThemeData(color: textSecondary),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: divider, width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: divider, thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        hintStyle: GoogleFonts.spaceGrotesk(color: textMuted, fontSize: 13),
        labelStyle: GoogleFonts.spaceGrotesk(color: textSecondary, fontSize: 13),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: background,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600, fontSize: 14),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: textSecondary),
      ),
    );
  }
}
