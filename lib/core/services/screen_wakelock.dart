import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the mobile screen awake while conversation generation is in flight.
///
/// Reference-counted: [acquire]/[release] track concurrent conversations.
/// The last release starts a 10s debounce before the platform lock is dropped.
class ScreenWakelock {
  ScreenWakelock._();

  static bool _enabled = false;
  static int _holders = 0;
  static bool _held = false;
  static Timer? _releaseTimer;
  static const Duration _releaseDelay = Duration(seconds: 10);

  static void setEnabled(bool v) {
    _enabled = v;
    if (!v) {
      _applyRelease();
    } else {
      _apply();
    }
  }

  static void acquire() {
    _holders++;
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _apply();
  }

  static void release() {
    if (_holders > 0) _holders--;
    if (_holders == 0) _scheduleRelease();
  }

  static void releaseNow() {
    _holders = 0;
    _applyRelease();
  }

  /// Re-apply after resume (window flags can be lost).
  static void reassert() {
    if (!_enabled || _holders <= 0) return;
    _applyPlatformHeld(true);
  }

  static void _apply() {
    if (_enabled && _holders > 0) _setPlatformHeld(true);
  }

  static void _applyRelease() {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _setPlatformHeld(false);
  }

  static void _scheduleRelease() {
    _releaseTimer?.cancel();
    _releaseTimer = Timer(_releaseDelay, _applyRelease);
  }

  static void _setPlatformHeld(bool held) {
    if (_held == held) return;
    _applyPlatformHeld(held);
  }

  static void _applyPlatformHeld(bool held) {
    final previous = _held;
    _held = held;
    if (!_isMobile) return;
    try {
      unawaited(
        (held ? WakelockPlus.enable() : WakelockPlus.disable())
            .catchError((Object _) {
          if (_held == held) _held = previous;
        }),
      );
    } catch (_) {
      _held = previous;
    }
  }

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _isMobile => _isIOS || _isAndroid;
}
