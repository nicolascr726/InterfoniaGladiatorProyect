import 'dart:async';

import 'package:flutter/material.dart';

import '../services/emergency_alarm_player.dart';

class EmergenciaScreen extends StatefulWidget {
  final String message;
  final DateTime expiresAt;
  final bool isConserje;
  final VoidCallback onCancel;
  final bool cancelling;
  final String? error;
  final Future<bool> Function()? canResumeAlarm;
  final EmergencyAlarmPlayer? alarmPlayer;

  const EmergenciaScreen({
    super.key,
    required this.message,
    required this.expiresAt,
    required this.isConserje,
    required this.onCancel,
    this.cancelling = false,
    this.error,
    this.canResumeAlarm,
    this.alarmPlayer,
  });

  @override
  State<EmergenciaScreen> createState() => _EmergenciaScreenState();
}

class _EmergenciaScreenState extends State<EmergenciaScreen>
    with WidgetsBindingObserver {
  late final EmergencyAlarmPlayer _alarm;
  Timer? _countdown;
  int _secondsRemaining = 0;
  bool _foreground = false;
  bool _audioError = false;
  bool _disposing = false;
  bool _resumePending = false;
  int _lifecycleGeneration = 0;
  int? _resumeCheckGeneration;

  @override
  void initState() {
    super.initState();
    _alarm = widget.alarmPlayer ??
        EmergencyAlarmPlayer(onError: (_) {
          if (mounted && !_disposing && !_audioError) {
            setState(() => _audioError = true);
          }
        });
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _startCountdown();
    if (_foreground) unawaited(_alarm.playUntil(widget.expiresAt));
  }

  @override
  void didUpdateWidget(covariant EmergenciaScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expiresAt != widget.expiresAt) {
      _startCountdown();
      if (_foreground && !_resumePending) {
        unawaited(_alarm.playUntil(widget.expiresAt));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_disposing || _foreground == foreground) return;
    _foreground = foreground;
    _lifecycleGeneration++;
    _resumePending = _foreground;
    if (_foreground) {
      unawaited(_confirmResumeAlarm());
    } else {
      unawaited(_alarm.stop());
    }
  }

  Future<void> _confirmResumeAlarm() async {
    final generation = _lifecycleGeneration;
    if (!mounted ||
        _disposing ||
        !_foreground ||
        !_resumePending ||
        _remainingSeconds() == 0 ||
        _resumeCheckGeneration == generation) {
      return;
    }
    _resumeCheckGeneration = generation;
    try {
      final authorize = widget.canResumeAlarm;
      final allowed = authorize == null || await authorize();
      if (!mounted ||
          _disposing ||
          !_foreground ||
          generation != _lifecycleGeneration ||
          !allowed ||
          _remainingSeconds() == 0) {
        return;
      }
      _resumePending = false;
      unawaited(_alarm.playUntil(widget.expiresAt));
    } catch (_) {
      // Reintentar sin reproducir una alerta cuya vigencia no se confirmó.
    } finally {
      if (_resumeCheckGeneration == generation) _resumeCheckGeneration = null;
    }
  }

  void _startCountdown() {
    _countdown?.cancel();
    _secondsRemaining = _remainingSeconds();
    if (_secondsRemaining == 0) return;
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = _remainingSeconds();
      if (remaining != _secondsRemaining && mounted) {
        setState(() => _secondsRemaining = remaining);
      }
      if (remaining > 0 && _resumePending) unawaited(_confirmResumeAlarm());
      if (remaining == 0) timer.cancel();
    });
  }

  int _remainingSeconds() =>
      (widget.expiresAt.difference(DateTime.now()).inMilliseconds / 1000)
          .ceil()
          .clamp(0, 60)
          .toInt();

  @override
  void dispose() {
    _disposing = true;
    _foreground = false;
    _lifecycleGeneration++;
    _resumePending = false;
    WidgetsBinding.instance.removeObserver(this);
    _countdown?.cancel();
    unawaited(_alarm.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _secondsRemaining ~/ 60;
    final seconds = (_secondsRemaining % 60).toString().padLeft(2, '0');

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFFB71C1C),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 48)
                      .clamp(0, double.infinity)
                      .toDouble(),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.white,
                          size: 88,
                          semanticLabel: 'Alerta de emergencia',
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'EMERGENCIA',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Alerta de Conserjería',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          widget.message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Mantén la calma y sigue las indicaciones de Conserjería.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          'Cierre automático en $minutes:$seconds',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Esta pantalla se cerrará automáticamente en un máximo de 1 minuto.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                        if (_audioError) ...[
                          const SizedBox(height: 12),
                          const Text(
                            'No se pudo reproducir la alarma de emergencia.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white, fontSize: 14),
                          ),
                        ],
                        if (widget.isConserje) ...[
                          const SizedBox(height: 32),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFFB71C1C),
                                disabledBackgroundColor: Colors.white70,
                                disabledForegroundColor:
                                    const Color(0xFFB71C1C),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 18,
                                ),
                              ),
                              onPressed:
                                  widget.cancelling ? null : widget.onCancel,
                              child: widget.cancelling
                                  ? const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Color(0xFFB71C1C),
                                          ),
                                        ),
                                        SizedBox(width: 12),
                                        Flexible(
                                            child:
                                                Text('Cancelando emergencia…')),
                                      ],
                                    )
                                  : const Text(
                                      'Cancelar emergencia',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold),
                                    ),
                            ),
                          ),
                          if (widget.error != null &&
                              widget.error!.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                widget.error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
