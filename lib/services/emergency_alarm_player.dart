import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';

abstract class EmergencyAlarmPlayback {
  Future<void> open();
  Future<void> play(Uint8List audio, void Function() whenFinished);
  Future<void> stop();
  Future<void> close();
}

class _FlutterSoundEmergencyAlarmPlayback implements EmergencyAlarmPlayback {
  final _player = FlutterSoundPlayer();

  @override
  Future<void> open() async {
    await _player.openPlayer();
  }

  @override
  Future<void> play(Uint8List audio, void Function() whenFinished) async {
    await _player.startPlayer(
      fromDataBuffer: audio,
      codec: Codec.mp3,
      whenFinished: whenFinished,
    );
  }

  @override
  Future<void> stop() => _player.stopPlayer();

  @override
  Future<void> close() => _player.closePlayer();
}

/// Plays one bundled alarm while the emergency screen is visible.
class EmergencyAlarmPlayer {
  static const assetPath = 'assets/audio/alarma.mp3';

  final EmergencyAlarmPlayback _playback;
  final Future<Uint8List> Function() _loadAudio;
  final DateTime Function() _now;
  final void Function(Object error)? _onError;
  Future<void> _pending = Future<void>.value();
  Uint8List? _audio;
  DateTime? _deadline;
  Timer? _expiryTimer;
  bool _opened = false;
  bool _wanted = false;
  bool _failed = false;
  bool _disposed = false;
  int _generation = 0;

  EmergencyAlarmPlayer({
    EmergencyAlarmPlayback? playback,
    Future<Uint8List> Function()? loadAudio,
    DateTime Function()? now,
    void Function(Object error)? onError,
  })  : _playback = playback ?? _FlutterSoundEmergencyAlarmPlayback(),
        _loadAudio = loadAudio ?? _loadBundledAlarm,
        _now = now ?? DateTime.now,
        _onError = onError;

  static Future<Uint8List> _loadBundledAlarm() async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// Repeated updates and resuming never extend the original deadline.
  Future<void> playUntil(DateTime expiresAt) {
    if (_disposed || _failed) return _pending;
    final now = _now();
    final maximum = now.add(const Duration(seconds: 60));
    var deadline = expiresAt.isBefore(maximum) ? expiresAt : maximum;
    if (_deadline != null && _deadline!.isBefore(deadline)) {
      deadline = _deadline!;
    }
    _deadline = deadline;
    _expiryTimer?.cancel();
    if (!deadline.isAfter(now)) return stop();

    // Start the limit before loading audio or opening the native player.
    _expiryTimer = Timer(deadline.difference(now), () => unawaited(stop()));
    if (_wanted) return _pending;
    _wanted = true;
    final generation = ++_generation;
    return _enqueue(() async {
      if (!_canPlay(generation)) return;
      if (_audio == null) {
        final audio = await _loadAudio();
        if (!_canPlay(generation)) return;
        _audio = audio;
      }
      if (!_opened) {
        await _playback.open();
        _opened = true;
      }
      if (!_canPlay(generation)) return;
      await _playOnce(generation);
    });
  }

  bool _canPlay(int generation) =>
      !_disposed &&
      !_failed &&
      _wanted &&
      _generation == generation &&
      _deadline != null &&
      _deadline!.isAfter(_now());

  Future<void> _playOnce(int generation) async {
    if (!_canPlay(generation)) return;
    await _playback.play(_audio!, () {
      if (_canPlay(generation)) {
        unawaited(_enqueue(() => _playOnce(generation)));
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _pending = _pending.then((_) async {
      try {
        await action();
      } catch (error) {
        _failed = true;
        _invalidate();
        // Opening can fail after allocating native resources.
        try {
          await _playback.close();
        } catch (closeError) {
          debugPrint('No se pudo liberar el audio de emergencia: $closeError');
        }
        _opened = false;
        debugPrint('No se pudo reproducir la alarma de emergencia: $error');
        if (!_disposed) _onError?.call(error);
      }
    });
    return _pending;
  }

  void _invalidate() {
    _wanted = false;
    _generation++;
    _expiryTimer?.cancel();
    _expiryTimer = null;
  }

  Future<void> _closeOpenedPlayer() async {
    if (!_opened) return;
    try {
      await _playback.stop();
    } finally {
      try {
        await _playback.close();
      } finally {
        _opened = false;
      }
    }
  }

  /// Pauses playback while preserving the emergency's original deadline.
  Future<void> stop() {
    if (_disposed) return _pending;
    _invalidate();
    return _enqueue(_closeOpenedPlayer);
  }

  Future<void> dispose() {
    if (_disposed) return _pending;
    _disposed = true;
    _invalidate();
    return _enqueue(() async {
      await _closeOpenedPlayer();
      _audio = null;
    });
  }
}
