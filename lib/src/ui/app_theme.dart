// lib/src/ui/app_theme.dart
// v2.22 (saneamiento): paleta unica de la app. Sustituye las copias del
// class _C que cada pantalla definia por su cuenta. Miembros: los 7 basicos
// + cardAlt y border que algunas pantallas tenian en su tema local.

import 'package:flutter/material.dart';

class AppColors {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const cardAlt = Color(0xFF3A3A3C);
  static const border = Color(0xFF48484A);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const ok = Color(0xFF30D158);
  static const warn = Color(0xFFFFD60A);
  static const err = Color(0xFFFF453A);
}
