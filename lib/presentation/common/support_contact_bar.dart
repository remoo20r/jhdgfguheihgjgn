import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui_mode.dart';
import '../../data/services/support_contact_service.dart';
import 'tv_focusable.dart';

/// Customer-service strip: the support number with a Call button and a
/// WhatsApp button next to it. Shown on the login screen and the home screen.
///
/// Both buttons are [TvFocusable] so a TV remote can reach them. The actions
/// only work on Android (dialer / WhatsApp); on Windows they no-op and show a
/// small note, so the bar can be dropped on any screen safely.
class SupportContactBar extends StatelessWidget {
  const SupportContactBar({super.key, this.compact = false, this.numberOnly = false});

  /// Tighter spacing/sizes for cramped layouts (e.g. phone landscape).
  final bool compact;

  /// Show only the number label (no "Customer service" caption, no buttons).
  /// Used in the home bottom-bar's left slot.
  final bool numberOnly;

  Future<void> _call(BuildContext context) async {
    final ok = await SupportContactService.call();
    if (!ok && context.mounted) _showUnavailable(context);
  }

  Future<void> _whatsApp(BuildContext context) async {
    final ok = await SupportContactService.whatsApp();
    if (!ok && context.mounted) _showUnavailable(context);
  }

  void _showUnavailable(BuildContext context) {
    final msg = Platform.isAndroid
        ? 'Could not open the app. Please dial ${SupportContact.displayNumber} manually.'
        : 'Call ${SupportContact.displayNumber} for support.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final numberStyle = TextStyle(
      color: AppColors.textPrimary,
      fontSize: compact ? 15 : 17,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
    );

    // Compact "number only" variant for the home bottom-bar left slot: a small
    // pill with the headset icon + the number, no caption and no buttons.
    if (numberOnly) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.glassTint,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.headset_mic_outlined, size: 18, color: AppColors.gold),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                SupportContact.displayNumber,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: numberStyle,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 16,
        vertical: compact ? 10 : 14,
      ),
      decoration: BoxDecoration(
        color: AppColors.glassTint,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.headset_mic_outlined,
                  size: compact ? 16 : 18, color: AppColors.gold),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Customer Service',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 6 : 8),
          Text(SupportContact.displayNumber, style: numberStyle),
          // Call / WhatsApp only make sense on a phone/tablet — a TV can't dial
          // or open WhatsApp, so hide the buttons in TV mode and just show the
          // number for the viewer to call from their phone.
          if (!isTvMode()) ...[
            SizedBox(height: compact ? 10 : 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ContactButton(
                  icon: Icons.call,
                  label: 'Call',
                  background: AppColors.gold,
                  foreground: Colors.black,
                  onTap: () => _call(context),
                  compact: compact,
                ),
                SizedBox(width: compact ? 10 : 14),
                _ContactButton(
                  icon: Icons.chat,
                  label: 'WhatsApp',
                  background: const Color(0xFF25D366),
                  foreground: Colors.white,
                  onTap: () => _whatsApp(context),
                  compact: compact,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ContactButton extends StatelessWidget {
  const _ContactButton({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
    required this.compact,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      borderRadius: 12,
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 20,
          vertical: compact ? 9 : 11,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 16 : 18, color: foreground),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: compact ? 14 : 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
