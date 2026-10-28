import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config.dart';

class EmergencyState {
  final String id;
  final String message;

  /// Deadline adjusted to the device clock using the server's remaining time.
  final DateTime expiresAt;
  final DateTime Function() _now;

  EmergencyState({
    required this.id,
    required this.message,
    required this.expiresAt,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  Duration get remaining {
    final value = expiresAt.difference(_now());
    return value.isNegative ? Duration.zero : value;
  }
}

class EmergencyService extends ChangeNotifier {
  static final EmergencyService instance = EmergencyService();
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;
  final Duration _pollInterval;
  final Duration _requestTimeout;
  io.Socket? _socket;
  void Function(dynamic)? _stateListener;
  void Function(dynamic)? _connectListener;
  String? _rut;
  bool _isConserje = false;
  EmergencyState? _current;
  String? _error;
  bool _cancelling = false;
  Future<void>? _syncInFlight;
  bool _disposed = false;
  int _generation = 0;
  int _revision = -1;
  bool? _serverActive;
  String? _eventId;
  DateTime? _deadline;
  Timer? _pollTimer;
  Timer? _expiryTimer;
  Timer? _countdownTimer;

  EmergencyService({
    http.Client? client,
    DateTime Function()? now,
    Duration pollInterval = const Duration(seconds: 2),
    Duration requestTimeout = const Duration(seconds: 10),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _now = now ?? DateTime.now,
        _pollInterval = pollInterval,
        _requestTimeout = requestTimeout;

  EmergencyState? get current => _current;
  bool get isConserje => _isConserje;
  String? get error => _error;
  bool get cancelling => _cancelling;
  bool get _attached => !_disposed && _socket != null && _rut != null;

  void attachSocket(io.Socket socket,
      {required String rut, required bool isConserje}) {
    if (_disposed) return;
    final account = rut.trim();
    if (account.isEmpty) return;
    if (identical(_socket, socket) &&
        _rut == account &&
        _isConserje == isConserje) {
      return;
    }
    _clearSession();
    _socket = socket;
    _rut = account;
    _isConserje = isConserje;
    final generation = _generation;
    _stateListener = (payload) {
      if (_isCurrentSession(generation)) applyServerState(payload);
    };
    _connectListener = (_) {
      if (_isCurrentSession(generation)) unawaited(sync());
    };
    socket.on('emergency-state', _stateListener!);
    socket.on('connect', _connectListener!);
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(sync()));
    notifyListeners();
    unawaited(sync());
  }

  void detachSocket(io.Socket socket) {
    if (!identical(_socket, socket)) return;
    _clearSession();
    if (!_disposed) notifyListeners();
  }

  bool _isCurrentSession(int generation) =>
      _attached && generation == _generation;

  void _clearSession() {
    if (_stateListener != null) {
      _socket?.off('emergency-state', _stateListener);
    }
    if (_connectListener != null) _socket?.off('connect', _connectListener);
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    _countdownTimer?.cancel();
    _pollTimer = null;
    _expiryTimer = null;
    _countdownTimer = null;
    _socket = null;
    _stateListener = null;
    _connectListener = null;
    _rut = null;
    _isConserje = false;
    _current = null;
    _error = null;
    _cancelling = false;
    _syncInFlight = null;
    _revision = -1;
    _serverActive = null;
    _eventId = null;
    _deadline = null;
    _generation++;
  }

  Future<void> sync() {
    if (!_attached) return Future<void>.value();
    if (_syncInFlight != null) return _syncInFlight!;
    final generation = _generation;
    late final Future<void> request;
    request = _syncState(generation).whenComplete(() {
      if (_isCurrentSession(generation) && identical(_syncInFlight, request)) {
        _syncInFlight = null;
      }
    });
    _syncInFlight = request;
    return request;
  }

  Future<void> _syncState(int generation) async {
    try {
      final response = await _client
          .get(Uri.parse('$kBaseUrl/api/emergencias/estado'))
          .timeout(_requestTimeout);
      if (!_isCurrentSession(generation)) return;
      final payload = _responsePayload(response);
      applyServerState(payload['emergencia']);
    } catch (_) {
      if (_isCurrentSession(generation)) {
        _error = 'No se pudo actualizar el estado de emergencia. '
            'Se volverá a intentar.';
        notifyListeners();
      }
    }
  }

  /// Accepts either the state itself or the HTTP response's `emergencia` field.
  /// Only a state belonging to an attached session can affect the overlay.
  void applyServerState(dynamic payload) {
    if (!_attached) return;
    try {
      if (payload is Map && payload.containsKey('emergencia')) {
        payload = payload['emergencia'];
      }
      final state = _ServerEmergency.parse(payload);
      if (state.revision < _revision) return;
      if (state.revision == _revision &&
          (_serverActive != state.active ||
              (state.active && _eventId != state.id))) {
        return;
      }
      _revision = state.revision;
      _serverActive = state.active;
      _error = null;
      if (!state.active) {
        _hideCurrent();
        notifyListeners();
        return;
      }

      var remaining = state.expiresAt!.difference(state.serverTime);
      if (remaining > const Duration(seconds: 60)) {
        remaining = const Duration(seconds: 60);
      }
      if (remaining.isNegative) remaining = Duration.zero;
      var deadline = _now().add(remaining);
      if (_eventId == state.id &&
          _deadline != null &&
          _deadline!.isBefore(deadline)) {
        deadline = _deadline!;
      }
      _eventId = state.id;
      _deadline = deadline;
      if (!deadline.isAfter(_now())) {
        _hideCurrent();
        notifyListeners();
        return;
      }
      _current = EmergencyState(
        id: state.id!,
        message: state.message,
        expiresAt: deadline,
        now: _now,
      );
      _expiryTimer?.cancel();
      final generation = _generation;
      _expiryTimer = Timer(deadline.difference(_now()), () {
        if (!_isCurrentSession(generation)) return;
        _hideCurrent();
        notifyListeners();
      });
      _countdownTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (_current != null) notifyListeners();
      });
      notifyListeners();
    } on FormatException {
      _error = 'El servidor devolvió un estado de emergencia no válido.';
      notifyListeners();
    }
  }

  void _hideCurrent() {
    _expiryTimer?.cancel();
    _countdownTimer?.cancel();
    _expiryTimer = null;
    _countdownTimer = null;
    _current = null;
  }

  Future<bool> cancel() async {
    if (!_attached || _cancelling || _current == null) return false;
    if (!_isConserje) {
      _error = 'Solo Conserjería puede cancelar la emergencia.';
      notifyListeners();
      return false;
    }
    final generation = _generation;
    final emergencyId = _current!.id;
    _cancelling = true;
    _error = null;
    notifyListeners();
    try {
      final response = await _client
          .post(Uri.parse('$kBaseUrl/api/emergencias/cancelar'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'rut': _rut, 'emergency_id': emergencyId}))
          .timeout(_requestTimeout);
      if (!_isCurrentSession(generation)) return false;
      final payload = _responsePayload(response);
      final state = _ServerEmergency.parse(payload['emergencia']);
      if (state.active) {
        throw const FormatException('La emergencia sigue activa.');
      }
      applyServerState(payload['emergencia']);
      return true;
    } catch (_) {
      if (_isCurrentSession(generation)) {
        _error = 'No se pudo confirmar la cancelación. '
            'La alerta seguirá activa hasta que termine o se confirme su cancelación.';
        notifyListeners();
      }
      return false;
    } finally {
      if (_isCurrentSession(generation)) {
        _cancelling = false;
        notifyListeners();
      }
    }
  }

  Map<String, dynamic> _responsePayload(http.Response response) {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200 ||
        decoded is! Map<String, dynamic> ||
        decoded['success'] != true ||
        !decoded.containsKey('emergencia')) {
      throw const FormatException('Respuesta de emergencia no válida.');
    }
    return decoded;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _clearSession();
    _disposed = true;
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

class _ServerEmergency {
  final String? id;
  final bool active;
  final String message;
  final DateTime? expiresAt;
  final DateTime serverTime;
  final int revision;

  _ServerEmergency(this.id, this.active, this.message, this.expiresAt,
      this.serverTime, this.revision);

  static _ServerEmergency parse(dynamic payload) {
    if (payload is! Map ||
        payload['active'] is! bool ||
        payload['message'] is! String ||
        payload['revision'] is! int ||
        (payload['revision'] as int) < 0 ||
        payload['server_time'] is! String) {
      throw const FormatException('Estado de emergencia no válido.');
    }
    final serverTime = DateTime.tryParse(payload['server_time'] as String);
    final active = payload['active'] as bool;
    final id = payload['id'];
    final expiresAt = payload['expires_at'] is String
        ? DateTime.tryParse(payload['expires_at'] as String)
        : null;
    if (serverTime == null ||
        !serverTime.isUtc ||
        (active &&
            (id is! String ||
                id.isEmpty ||
                expiresAt == null ||
                !expiresAt.isUtc))) {
      throw const FormatException('Fechas de emergencia no válidas.');
    }
    return _ServerEmergency(
        id is String ? id : null,
        active,
        payload['message'] as String,
        expiresAt,
        serverTime,
        payload['revision'] as int);
  }
}
