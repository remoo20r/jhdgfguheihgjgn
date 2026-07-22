import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/ui_mode.dart';

/// Bright silver used for the focus outline + halo (a premium "chrome" edge).
const Color kFocusSilver = Color(0xFFF2F4F8);

/// Deep, saturated red for the focused-item fill — strong enough that white
/// text on top stays clearly readable (a light/washed red made text hard to
/// see).
const Color kFocusRed = Color(0xFFD01020);

/// Wraps a child so it works with pointer (mouse/touch) *and* D-pad input.
///
/// Focus indicator is STATIC (no animation): a thick silver outline, a red
/// translucent fill, and a soft red+silver glow. Animations were removed on
/// purpose — dozens of looping controllers (one per grid tile) crippled
/// performance on low-end Android TV boxes. A static highlight is instant and
/// costs nothing to keep on screen.
///
/// Focus rules:
/// - Focusable on any Android build ([dpadFocusEnabled]), never on Windows.
/// - Autofocus only where a D-pad is expected ([dpadAutofocusEnabled]).
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.borderRadius = 16,
    this.autofocus = false,
    this.focusNode,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double borderRadius;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Test hook: forces D-pad (TV) behaviour regardless of the host platform.
  @visibleForTesting
  static bool? debugDpadOverride;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _hovered = false;
  bool _selectDown = false;
  bool _longPressFired = false;

  static bool get _focusable => TvFocusable.debugDpadOverride ?? dpadFocusEnabled();
  static bool get _autofocusEnabled =>
      TvFocusable.debugDpadOverride ?? dpadAutofocusEnabled();
  static bool get _hoverEnabled => Platform.isWindows;

  static bool _isSelectKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    if (!_isSelectKey(event.logicalKey)) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _selectDown = true;
      _longPressFired = false;
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      if (widget.onLongPress != null && !_longPressFired) {
        _longPressFired = true;
        widget.onLongPress!();
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      final shouldTap = _selectDown && !_longPressFired;
      _selectDown = false;
      _longPressFired = false;
      if (shouldTap) widget.onTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus && _autofocusEnabled,
      canRequestFocus: _focusable,
      skipTraversal: !_focusable,
      onKeyEvent: _handleKey,
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasPrimaryFocus;
          final highlight = focused || (_hovered && _hoverEnabled);

          return MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: _hoverEnabled ? (_) => setState(() => _hovered = true) : null,
            onExit: _hoverEnabled ? (_) => setState(() => _hovered = false) : null,
            child: GestureDetector(
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  // Solid, saturated red fill behind the focused item so white
                  // text/icons on top stay clearly legible.
                  color: focused ? kFocusRed.withValues(alpha: 0.90) : null,
                  // Thick silver outline marks "you are here".
                  border: Border.all(
                    color: highlight
                        ? kFocusSilver
                        : Colors.transparent,
                    width: focused ? 3.0 : (highlight ? 2.0 : 0.0),
                  ),
                  boxShadow: focused
                      ? [
                          // Silver halo.
                          BoxShadow(
                            color: kFocusSilver.withValues(alpha: 0.55),
                            blurRadius: 16,
                            spreadRadius: 1,
                          ),
                          // Warm red bloom.
                          BoxShadow(
                            color: kFocusRed.withValues(alpha: 0.35),
                            blurRadius: 26,
                            spreadRadius: 0,
                          ),
                        ]
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  child: widget.child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
