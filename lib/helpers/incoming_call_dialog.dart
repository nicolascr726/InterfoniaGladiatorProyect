import 'dart:async';

import 'package:flutter/material.dart';

enum IncomingCallDecision { accept, acceptWithHandset, reject, timeout, ended }

/// Owns one dialog, so delayed events never pop an unrelated screen.
class IncomingCallDialog {
  IncomingCallDialog({
    required this.payload,
    required this.isCitofono,
    required this.onStopRinging,
    this.resetHandset,
    this.isHandsetLifted,
  });

  final Map<dynamic, dynamic> payload;
  final bool isCitofono;
  final VoidCallback onStopRinging;
  final Future<void> Function()? resetHandset;
  final Future<bool> Function()? isHandsetLifted;

  DialogRoute<IncomingCallDecision>? _route;
  Timer? _timeoutTimer;
  Timer? _handsetTimer;
  DateTime? _expiresAt;
  bool _closed = false;
  bool _checkingHandset = false;

  static Duration remainingTime(
    Map<dynamic, dynamic> payload, {
    required bool isCitofono,
    DateTime? now,
  }) {
    final expiresAt =
        DateTime.tryParse(payload['expires_at']?.toString() ?? '');
    if (expiresAt != null) {
      final remaining = expiresAt.difference(now ?? DateTime.now());
      return remaining.isNegative ? Duration.zero : remaining;
    }
    final seconds =
        int.tryParse(payload['ring_timeout_seconds']?.toString() ?? '');
    return Duration(
        seconds:
            seconds != null && seconds > 0 ? seconds : (isCitofono ? 60 : 45));
  }

  bool matches(dynamic event) {
    if (event is! Map) return true;
    final callId = payload['call_id']?.toString();
    final eventId = event['call_id']?.toString();
    return callId == null ||
        callId.isEmpty ||
        eventId == null ||
        eventId.isEmpty ||
        callId == eventId;
  }

  Future<IncomingCallDecision?> show(BuildContext context) {
    final remaining = remainingTime(payload, isCitofono: isCitofono);
    _expiresAt = DateTime.now().add(remaining);
    if (remaining == Duration.zero) {
      _cleanup();
      return Future.value(IncomingCallDecision.timeout);
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<IncomingCallDecision>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF222233),
          title: const Text('📞 Llamada entrante',
              style: TextStyle(color: Colors.white)),
          content: Text(
            'De: ${payload['caller_dpto'] ?? payload['caller_rut']}',
            style: const TextStyle(color: Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () => close(IncomingCallDecision.reject),
              child:
                  const Text('Rechazar', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF448AFF)),
              onPressed: () => close(IncomingCallDecision.accept),
              child: const Text('Aceptar'),
            ),
          ],
        ),
      ),
    );
    _route = route;
    final result = navigator.push(route);
    _timeoutTimer = Timer(
      remaining,
      () => close(IncomingCallDecision.timeout),
    );
    if (isCitofono && isHandsetLifted != null) unawaited(_monitorHandset());
    return result.whenComplete(_cleanup);
  }

  Future<void> _monitorHandset() async {
    await resetHandset?.call();
    if (_closed) return;
    _handsetTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_checkHandset()),
    );
    await _checkHandset();
  }

  Future<void> _checkHandset() async {
    if (_closed || _checkingHandset) return;
    _checkingHandset = true;
    try {
      final lifted = await isHandsetLifted!();
      if (!_closed && lifted) close(IncomingCallDecision.acceptWithHandset);
    } finally {
      _checkingHandset = false;
    }
  }

  void _cleanup() {
    if (_closed) return;
    _closed = true;
    _timeoutTimer?.cancel();
    _handsetTimer?.cancel();
    onStopRinging();
  }

  void close([IncomingCallDecision decision = IncomingCallDecision.ended]) {
    if (_closed) return;
    if ((decision == IncomingCallDecision.accept ||
            decision == IncomingCallDecision.acceptWithHandset) &&
        _expiresAt != null &&
        !DateTime.now().isBefore(_expiresAt!)) {
      decision = IncomingCallDecision.timeout;
    }
    _cleanup();
    final route = _route;
    final navigator = route?.navigator;
    if (route == null || navigator == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop(decision);
    } else {
      navigator.removeRoute(route, decision);
    }
  }

  void dispose() {
    _cleanup();
    // The owner can be removed while its dialog is still in the navigator.
    // Wait until navigation finishes, then remove only this dialog.
    final route = _route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = route?.navigator;
      if (route != null &&
          navigator != null &&
          navigator.mounted &&
          route.isActive) {
        navigator.removeRoute(route, IncomingCallDecision.ended);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}
