import 'dart:io';

import 'package:flutter/services.dart';

/// Customer-service contact details and the actions behind the Call / WhatsApp
/// buttons. The number lives here once so the login and home screens stay in
/// sync — change it in a single place.
class SupportContact {
  /// Human-readable number shown in the UI.
  static const String displayNumber = '+1 (682) 597-5255';

  /// Digits only, E.164 without the "+" — used for tel: and wa.me links.
  static const String dialNumber = '+16825975255';

  /// wa.me expects the number without "+" or any symbols.
  static const String whatsappNumber = '16825975255';

  /// Pre-filled WhatsApp message (optional).
  static const String whatsappMessage =
      'Hello, I need help with BellaTV.';
}

/// Thin wrapper over the native platform channel that opens the phone dialer
/// and WhatsApp. Reuses the existing `com.brokeniptv/device` channel handled
/// in MainActivity.kt — no extra Flutter plugin required.
class SupportContactService {
  static const _channel = MethodChannel('com.brokeniptv/device');

  /// Opens the system dialer pre-filled with the support number. Returns false
  /// if the platform can't handle it (e.g. Windows, or no dialer app).
  static Future<bool> call() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'dialPhone',
            {'number': SupportContact.dialNumber},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens a WhatsApp chat with the support number. Returns false if it can't
  /// be opened (WhatsApp not installed, unsupported platform, etc.).
  static Future<bool> whatsApp() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'openWhatsApp',
            {
              'number': SupportContact.whatsappNumber,
              'text': SupportContact.whatsappMessage,
            },
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
