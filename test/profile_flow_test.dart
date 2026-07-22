import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broken_iptv/app.dart';
import 'package:broken_iptv/data/services/secure_credentials_service.dart';
import 'package:broken_iptv/data/services/storage_service.dart';
import 'package:broken_iptv/state/profile_providers.dart';

/// Real credential storage touches platform channels/FFI (Windows DPAPI via
/// path_provider) that aren't wired up in a widget-test host, so tests use
/// an in-memory stand-in instead.
class FakeSecureCredentialsService extends SecureCredentialsService {
  FakeSecureCredentialsService() : super(const FlutterSecureStorage());

  final Map<String, String> _store = {};

  @override
  Future<void> savePassword(String profileId, String password) async {
    _store[profileId] = password;
  }

  @override
  Future<String?> getPassword(String profileId) async => _store[profileId];

  @override
  Future<void> deletePassword(String profileId) async {
    _store.remove(profileId);
  }
}

void main() {
  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('broken_iptv_test');
    await StorageService.init(testPath: dir.path);
  });

  testWidgets('Signing in on the login screen lands on the home screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureCredentialsServiceProvider
              .overrideWithValue(FakeSecureCredentialsService()),
        ],
        child: const BrokenIptvApp(),
      ),
    );
    await tester.pumpAndSettle();

    // With no playlist yet, the app boots straight to the login screen.
    expect(find.text('Sign In'), findsWidgets);

    // A server is pre-selected by default; just fill username + password.
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Enter your username'), 'user1');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Enter your password'), 'secret');

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
      await Future.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    // First saved playlist selects itself and enters the app directly.
    expect(find.text('Live TV'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
  });
}
