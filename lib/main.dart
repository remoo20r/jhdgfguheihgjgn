import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/fullscreen.dart';
import 'core/ui_mode.dart';
import 'data/services/device_mode_service.dart';
import 'data/services/storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await StorageService.init();

  // On Android TV / Google TV the app is driven by a D-pad remote, so it must
  // come up in TV mode (focusable UI, autofocus) from the very first launch.
  // Ask the platform whether this is a television and, if the user hasn't
  // already picked a mode, save "tv" so the remote works immediately.
  if (Platform.isAndroid) {
    final deviceService = DeviceModeService();
    if (deviceService.getSaved() == null && await deviceService.detectIsTv()) {
      await deviceService.save(DeviceMode.tv);
    }
  }
  // Cache the native TV check so the (synchronous) focus policies can fall
  // back to it — guarantees a working remote even if the saved mode is wrong.
  await initTvDetection();

  // Android is fullscreen for good: no toggle anywhere, re-asserted on every
  // resume (see BrokenIptvApp).
  await applyAndroidImmersive();

  // Orientation is free everywhere on Android (portrait + landscape); only
  // the player pins landscape, see PlayerScreen.initState/dispose.

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      title: 'BellaTV',
      minimumSize: Size(640, 420),
      titleBarStyle: TitleBarStyle.normal,
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ProviderScope(child: BrokenIptvApp()));
}
