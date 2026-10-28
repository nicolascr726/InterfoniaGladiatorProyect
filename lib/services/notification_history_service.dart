import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class NotificationHistoryEntry {
  final String id;
  final String type;
  final String title;
  final String body;
  final DateTime receivedAt;
  final String? peerRut;
  final List<String> sources;
  final List<String> remoteIds;
  final String? fingerprint;

  const NotificationHistoryEntry({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.receivedAt,
    this.peerRut,
    this.sources = const [],
    this.remoteIds = const [],
    this.fingerprint,
  });

  factory NotificationHistoryEntry.fromJson(Map<String, dynamic> json) {
    return NotificationHistoryEntry(
      id: json['id'] as String,
      type: json['type'] as String,
      title: json['title'] as String,
      body: json['body'] as String,
      receivedAt: DateTime.parse(json['received_at'] as String),
      peerRut: json['peer_rut'] as String?,
      sources: List<String>.from(json['sources'] as List? ?? const []),
      remoteIds: List<String>.from(json['remote_ids'] as List? ?? const []),
      fingerprint: json['fingerprint'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'title': title,
        'body': body,
        'received_at': receivedAt.toUtc().toIso8601String(),
        'peer_rut': peerRut,
        'sources': sources,
        'remote_ids': remoteIds,
        'fingerprint': fingerprint,
      };
}

class _NotificationRecovery {
  late final Future<void> future;
  bool running = true;
  bool repeatRequested = false;
}

class NotificationHistoryService {
  static const storageKeyPrefix = 'conserje_notification_history_';
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static Future<void> _pendingWrites = Future<void>.value();
  static final Map<String, _NotificationRecovery> _pendingRecoveries = {};
  static int _sessionGeneration = 0;
  static int _sequence = 0;

  static String _rut(dynamic value) => (value ?? '')
      .toString()
      .replaceAll('.', '')
      .replaceAll('-', '')
      .trim()
      .toUpperCase();

  static String _text(dynamic value) => (value ?? '').toString().trim();

  static String _first(Iterable<dynamic> values) => values
      .map(_text)
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');

  static String _userPrefix(String rut) =>
      '$storageKeyPrefix${base64Url.encode(utf8.encode(_rut(rut)))}_';

  static String _key(String rut, String id) =>
      '${_userPrefix(rut)}${base64Url.encode(utf8.encode(id))}';

  static String _dismissedKey(String rut, String id) =>
      '${storageKeyPrefix}dismissed_'
      '${base64Url.encode(utf8.encode(_rut(rut)))}_'
      '${base64Url.encode(utf8.encode(id))}';

  static DateTime? _date(dynamic value) {
    final text = _text(value);
    if (text.isEmpty) return null;
    final hasZone =
        RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(text);
    return DateTime.tryParse(hasZone ? text : '${text}Z');
  }

  static List<NotificationHistoryEntry> _read(
    SharedPreferences prefs,
    String rut,
  ) {
    final prefix = _userPrefix(rut);
    final entries = <NotificationHistoryEntry>[];
    for (final key in prefs.getKeys().where((key) => key.startsWith(prefix))) {
      try {
        final json = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
        entries.add(NotificationHistoryEntry.fromJson(json));
      } catch (error) {
        debugPrint('No se pudo leer una notificación guardada: $error');
      }
    }
    entries.sort((a, b) {
      final byDate = b.receivedAt.compareTo(a.receivedAt);
      return byDate == 0 ? b.id.compareTo(a.id) : byDate;
    });
    return entries;
  }

  static Future<List<NotificationHistoryEntry>> load(String rut) async {
    if (_rut(rut).isEmpty) return [];
    await _pendingWrites;
    final prefs = await SharedPreferences.getInstance();
    // El isolate que recibe FCM en segundo plano tiene otra caché.
    await prefs.reload();
    return _read(prefs, rut)
        .where((entry) =>
            // La versión anterior importaba registros históricos del servidor.
            // Solo se muestran avisos que llegaron realmente por un evento.
            !(entry.sources.length == 1 && entry.sources.single == 'server') &&
            prefs.getBool(_dismissedKey(rut, entry.id)) != true)
        .toList();
  }

  /// Oculta únicamente el aviso local; conserva el registro para deduplicarlo.
  static Future<void> dismiss(String rut, String notificationId) async {
    final normalizedRut = _rut(rut);
    if (normalizedRut.isEmpty || notificationId.trim().isEmpty) {
      throw ArgumentError('Se necesita una cuenta y una notificación válida.');
    }
    final write = _pendingWrites.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final key = _dismissedKey(normalizedRut, notificationId);
      if (prefs.getBool(key) == true) return;
      final saved = await prefs.setBool(key, true);
      if (!saved) throw StateError('No se pudo descartar la notificación.');
      changes.value++;
    });
    // El panel recibe el fallo y los siguientes eventos pueden seguir guardándose.
    _pendingWrites = write.catchError((Object error, StackTrace stackTrace) {
      debugPrint('No se pudo descartar una notificación: $error');
    });
    await write;
  }

  /// Guarda un aviso recibido por Socket o FCM, sin consultar registros previos.
  static Future<void> receive(String rut, Map<String, dynamic> payload,
      {String source = 'event'}) async {
    final normalizedRut = _rut(rut);
    if (normalizedRut.isEmpty) {
      throw ArgumentError(
          'Se necesita una cuenta para recibir notificaciones.');
    }
    if (source != 'event' && source != 'event_push') {
      throw ArgumentError('La fuente de la notificación no es válida.');
    }
    final incoming = _eventEntry(payload);
    final write = _pendingWrites.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      NotificationHistoryEntry? previous;
      for (final entry in _read(prefs, normalizedRut)) {
        if (entry.id == incoming.id) {
          previous = entry;
          break;
        }
      }
      // FCM puede abreviar el cuerpo para respetar el límite de su payload.
      final keepCompleteEvent =
          previous?.sources.contains('event') == true && source == 'event_push';
      final entry = NotificationHistoryEntry(
        id: incoming.id,
        type: keepCompleteEvent ? previous!.type : incoming.type,
        title: keepCompleteEvent ? previous!.title : incoming.title,
        body: keepCompleteEvent ? previous!.body : incoming.body,
        receivedAt:
            keepCompleteEvent ? previous!.receivedAt : incoming.receivedAt,
        peerRut: keepCompleteEvent ? previous!.peerRut : incoming.peerRut,
        sources: {...?previous?.sources, source}.toList(),
        remoteIds: previous?.remoteIds ?? const [],
        fingerprint: previous?.fingerprint,
      );
      if (_sameEntry(previous, entry)) return;
      final saved = await prefs.setString(
          _key(normalizedRut, entry.id), jsonEncode(entry.toJson()));
      if (!saved) throw StateError('No se pudo guardar una notificación.');
      changes.value++;
    });
    _pendingWrites = write.catchError((Object error, StackTrace stackTrace) {
      debugPrint('No se pudo guardar una notificación recibida: $error');
    });
    await write;
  }

  /// Confirma la entrega solo después de persistir el aviso en este dispositivo.
  static Future<void> receiveAndConfirm(
      String rut, Map<String, dynamic> payload,
      {String source = 'event', http.Client? client}) async {
    final normalizedRut = _rut(rut);
    final generation = _sessionGeneration;
    final incoming = Map<String, dynamic>.from(payload);
    if (!await _isCurrentAccount(normalizedRut, generation)) return;
    await receive(normalizedRut, incoming, source: source);
    await _acknowledge(normalizedRut, [_eventEntry(incoming).id], generation,
        client: client);
  }

  /// Recibe únicamente avisos cuya entrega al dispositivo sigue pendiente.
  /// Se invoca al conectar; no consulta los historiales de las operaciones.
  static Future<void> recoverPending(String rut, {http.Client? client}) {
    final normalizedRut = _rut(rut);
    final previous = _pendingRecoveries[normalizedRut];
    if (previous != null && previous.running) {
      previous.repeatRequested = true;
      return previous.future;
    }
    final recovery = _NotificationRecovery();
    _pendingRecoveries[normalizedRut] = recovery;
    recovery.future = _runRecovery(normalizedRut, _sessionGeneration, recovery,
        client: client);
    return recovery.future;
  }

  static Future<void> _runRecovery(
      String rut, int generation, _NotificationRecovery recovery,
      {http.Client? client}) async {
    Object? failure;
    StackTrace? failureTrace;
    try {
      do {
        recovery.repeatRequested = false;
        try {
          await _recoverPending(rut, generation, client: client);
          failure = null;
          failureTrace = null;
        } catch (error, stackTrace) {
          failure = error;
          failureTrace = stackTrace;
        }
        // Solo una nueva solicitud de conexión permite otra pasada desde cero.
      } while (recovery.repeatRequested && generation == _sessionGeneration);
      if (failure != null) {
        Error.throwWithStackTrace(failure, failureTrace!);
      }
    } finally {
      recovery.running = false;
      if (identical(_pendingRecoveries[rut], recovery)) {
        _pendingRecoveries.remove(rut);
      }
    }
  }

  static Future<void> _recoverPending(String rut, int generation,
      {http.Client? client}) async {
    if (!await _isCurrentAccount(rut, generation)) return;
    final connection = client ?? http.Client();
    try {
      var afterId = 0;
      while (await _isCurrentAccount(rut, generation)) {
        final uri = Uri.parse('$kBaseUrl/api/notification-inbox/pending')
            .replace(queryParameters: {
          'rut': rut,
          'after_id': '$afterId',
          'limit': '100',
        });
        final response =
            await connection.get(uri).timeout(const Duration(seconds: 15));
        if (!await _isCurrentAccount(rut, generation)) return;
        if (response.statusCode != 200) {
          throw StateError('No se pudieron recibir los avisos pendientes '
              '(HTTP ${response.statusCode}).');
        }
        // Validar el lote completo antes de guardar o confirmar alguna entrega.
        final page = _pendingPage(response.bodyBytes, afterId);
        for (final payload in page.entries) {
          if (!await _isCurrentAccount(rut, generation)) return;
          await receive(rut, payload);
        }
        if (page.entries.isNotEmpty) {
          final confirmed = await _acknowledge(
            rut,
            page.entries.map((payload) => _eventEntry(payload).id).toList(),
            generation,
            client: connection,
          );
          // Dejar el lote pendiente ante un fallo permite reintentar al conectar.
          if (!confirmed) return;
        }
        if (!page.hasMore) return;
        afterId = page.nextAfterId;
      }
    } finally {
      if (client == null) connection.close();
    }
  }

  static Future<bool> _isCurrentAccount(String rut, int generation) async {
    if (rut.isEmpty || generation != _sessionGeneration) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return generation == _sessionGeneration &&
        _rut(prefs.getString('rut')) == rut &&
        prefs.getInt('es_admin') == 1;
  }

  static Future<bool> _acknowledge(String rut, List<String> ids, int generation,
      {http.Client? client}) async {
    http.Client? ownedConnection;
    try {
      if (!await _isCurrentAccount(rut, generation)) return false;
      final connection = client ?? (ownedConnection = http.Client());
      final response = await connection
          .post(
            Uri.parse('$kBaseUrl/api/notification-inbox/ack'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'rut': rut, 'ids': ids}),
          )
          .timeout(const Duration(seconds: 15));
      if (!await _isCurrentAccount(rut, generation)) return false;
      if (response.statusCode != 200) {
        throw StateError('No se pudo confirmar la entrega '
            '(HTTP ${response.statusCode}).');
      }
      final result = jsonDecode(utf8.decode(response.bodyBytes));
      if (result is! Map || result['success'] != true) {
        throw const FormatException('La confirmación recibida no es válida.');
      }
      return true;
    } catch (error) {
      // La entrega sigue pendiente en el servidor; el aviso local se conserva.
      debugPrint('No se pudo confirmar una notificación recibida: $error');
      return false;
    } finally {
      ownedConnection?.close();
    }
  }

  static ({List<Map<String, dynamic>> entries, int nextAfterId, bool hasMore})
      _pendingPage(List<int> bytes, int afterId) {
    final payload = jsonDecode(utf8.decode(bytes));
    if (payload is! Map ||
        payload['success'] != true ||
        payload['notificaciones'] is! List ||
        payload['next_after_id'] is! int ||
        payload['has_more'] is! bool) {
      throw const FormatException('El lote de avisos pendientes no es válido.');
    }
    final nextAfterId = payload['next_after_id'] as int;
    final hasMore = payload['has_more'] as bool;
    final values = payload['notificaciones'] as List;
    if (values.length > 100 ||
        nextAfterId < afterId ||
        ((hasMore || values.isNotEmpty) && nextAfterId <= afterId) ||
        (hasMore && values.isEmpty)) {
      throw const FormatException(
          'El cursor de avisos pendientes no es válido.');
    }
    final ids = <String>{};
    final entries = <Map<String, dynamic>>[];
    for (final value in values) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Un aviso pendiente no es válido.');
      }
      final entry = _eventEntry(value);
      final inboxId = value['inbox_id'];
      if (!ids.add(entry.id) ||
          (inboxId != null &&
              (inboxId is! int ||
                  inboxId <= afterId ||
                  inboxId > nextAfterId))) {
        throw const FormatException('Un aviso pendiente no es válido.');
      }
      entries.add(Map<String, dynamic>.from(value));
    }
    return (entries: entries, nextAfterId: nextAfterId, hasMore: hasMore);
  }

  static NotificationHistoryEntry _eventEntry(Map<String, dynamic> payload) {
    if (payload['id'] is! String ||
        payload['type'] is! String ||
        payload['title'] is! String ||
        payload['body'] is! String ||
        payload['fecha_hora'] is! String ||
        (payload['peer_rut'] != null && payload['peer_rut'] is! String)) {
      throw const FormatException(
          'La notificación recibida no tiene un formato válido.');
    }
    final id = (payload['id'] as String).trim();
    final type = (payload['type'] as String).trim();
    final title = (payload['title'] as String).trim();
    final date = _eventDate(payload['fecha_hora'] as String);
    if (id.isEmpty || type.isEmpty || title.isEmpty || date == null) {
      throw const FormatException(
          'La notificación recibida no tiene un formato válido.');
    }
    final peer = _rut(payload['peer_rut']);
    return NotificationHistoryEntry(
      id: id,
      type: type,
      title: title,
      body: payload['body'] as String,
      receivedAt: date,
      peerRut: peer.isEmpty ? null : peer,
      sources: const ['event'],
    );
  }

  static DateTime? _eventDate(String value) {
    final match = RegExp(
            r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|\+00:00)$')
        .firstMatch(value);
    if (match == null) return null;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > DateTime.utc(year, month + 1, 0).day ||
        int.parse(match[4]!) > 23 ||
        int.parse(match[5]!) > 59 ||
        int.parse(match[6]!) > 59) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  }

  static bool _sameEntry(
          NotificationHistoryEntry? previous, NotificationHistoryEntry entry) =>
      previous != null &&
      jsonEncode(previous.toJson()) == jsonEncode(entry.toJson());

  static Future<void> recordPush(RemoteMessage message,
      {bool confirmDelivery = false, http.Client? client}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final rut = _rut(prefs.getString('rut'));
      if (rut.isEmpty || prefs.getInt('es_admin') != 1) return;
      final data = message.data;
      final type = _text(data['type']);
      if (type == 'notification_record') {
        if (_rut(data['target_rut']) != rut) return;
        final encoded = data['notification_record'];
        if (encoded is! String) throw const FormatException();
        final payload = jsonDecode(encoded);
        if (payload is! Map<String, dynamic>) throw const FormatException();
        // Otro isolate podría estar guardando el evento completo por Socket.
        // El aviso abreviado queda pendiente para recuperarlo íntegro al volver.
        if (_text(data['notification_record_complete']) == '0') return;
        if (confirmDelivery &&
            _text(data['notification_record_complete']) == '1') {
          await receiveAndConfirm(rut, payload,
              source: 'event_push', client: client);
        } else {
          await receive(rut, payload, source: 'event_push');
        }
        return;
      }
      final recipient = _rut(_first([
        data['rut_receptor'],
        data['target_rut'],
        data['rut'],
      ]));
      if (recipient.isNotEmpty && recipient != rut) return;
      final sender = _rut(type == 'chat_message'
          ? data['rut_emisor']
          : data['caller_identity_rut'] ?? data['caller_rut']);
      if (sender.isNotEmpty && sender == rut) return;

      await recordEvent(
        rut: rut,
        type: type.isEmpty ? 'notification' : type,
        data: data,
        receivedAt: message.sentTime,
        title: message.notification?.title,
        body: message.notification?.body,
        remoteId: message.messageId,
        source: 'push',
      );
    } catch (error) {
      // Guardar el historial nunca debe impedir atender la notificación.
      debugPrint('No se pudo guardar la notificación recibida: $error');
    }
  }

  static Future<void> recordEvent({
    required String rut,
    required String type,
    required Map<String, dynamic> data,
    DateTime? receivedAt,
    String? title,
    String? body,
    String? remoteId,
    String source = 'socket',
  }) {
    final eventData = Map<String, dynamic>.from(data);
    final eventTime =
        _date(eventData['fecha_hora']) ?? receivedAt ?? DateTime.now();
    final write = _pendingWrites.then((_) async {
      try {
        if (_rut(rut).isEmpty) return;
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final entries = _read(prefs, rut);
        final normalizedType = type.replaceAll('-', '_');
        final eventType =
            normalizedType == 'incoming_call' ? 'call' : normalizedType;
        final isChat = eventType == 'chat_message';
        final isCall = eventType == 'call' || eventType == 'missed_call';
        final isRecord = const {
          'recado_created',
          'recado_resolved',
          'door_opening',
        }.contains(eventType);
        final peer = _rut(eventData['peer_rut'] ??
            (isChat
                ? eventData['rut_emisor']
                : eventData['caller_identity_rut'] ?? eventData['caller_rut']));
        final sender = _first([
          isChat ? eventData['sender_label'] : eventData['caller_dpto'],
          peer,
          isChat ? 'Depto/Casa' : 'Citófono',
        ]);
        final messageId = isChat
            ? _first([eventData['message_id'], eventData['id']])
            : _text(eventData['call_id']);
        final explicitId = _text(eventData['event_id']);
        final recordId = isRecord ? _text(eventData['id']) : '';
        final pushId = _text(remoteId);
        final fingerprint = isCall && messageId.isEmpty
            ? jsonEncode([eventType, peer, _text(eventData['tipo'])])
            : null;
        final id = explicitId.isNotEmpty
            ? explicitId
            : recordId.isNotEmpty
                ? '$eventType:$recordId'
                : messageId.isNotEmpty && (isChat || isCall)
                    ? '${isChat ? 'chat' : eventType}:$messageId'
                    : pushId.isNotEmpty
                        ? 'push:$pushId'
                        : '$eventType:${eventTime.microsecondsSinceEpoch}:${_sequence++}';

        NotificationHistoryEntry? previous;
        for (final entry in entries) {
          if (entry.id == id ||
              (pushId.isNotEmpty && entry.remoteIds.contains(pushId))) {
            previous = entry;
            break;
          }
        }
        if (previous == null && fingerprint != null) {
          Duration? closestDifference;
          for (final entry in entries) {
            if (entry.fingerprint != fingerprint ||
                entry.sources.contains(source)) {
              continue;
            }
            final difference = entry.receivedAt.difference(eventTime).abs();
            if (difference <= const Duration(seconds: 12) &&
                (closestDifference == null || difference < closestDifference)) {
              previous = entry;
              closestDifference = difference;
            }
          }
        }

        final rawBody = _first([body, eventData['mensaje'], eventData['body']]);
        final imageFlag = eventData['es_imagen'];
        final isImage = isChat &&
            (imageFlag == true ||
                imageFlag == 1 ||
                imageFlag == 'true' ||
                imageFlag == '1' ||
                rawBody.startsWith('/static/uploads/chat/'));
        final fallbackTitle = isChat
            ? 'Nuevo mensaje de $sender'
            : eventType == 'call'
                ? 'Llamada entrante'
                : eventType == 'missed_call'
                    ? 'Llamada perdida'
                    : eventType == 'recado_created'
                        ? 'Nuevo recado'
                        : eventType == 'recado_resolved'
                            ? 'Recado resuelto'
                            : eventType == 'door_opening'
                                ? 'Apertura de puerta'
                                : 'Notificación';
        final reason = _text(eventData['reason']);
        final missedDetail = reason.isEmpty || reason == 'ocupado'
            ? 'No fue contestada.'
            : reason;
        final fallbackBody = isChat
            ? (isImage ? 'Imagen recibida' : _first([rawBody, 'Nuevo mensaje']))
            : eventType == 'missed_call'
                ? _first([rawBody, '$sender · $missedDetail'])
                : isCall
                    ? _first([rawBody, 'De: $sender'])
                    : _first([rawBody, 'Nueva notificación recibida.']);
        final fromEvent = previous?.sources
                .any((value) => value == 'event' || value == 'event_push') ??
            false;
        final preferPrevious = previous != null &&
            (fromEvent ||
                (previous.sources.contains('socket') && source == 'push'));
        final entry = NotificationHistoryEntry(
          id: previous?.id ?? id,
          type: fromEvent ? previous!.type : eventType,
          title: preferPrevious
              ? previous.title
              : _first([title, eventData['title'], fallbackTitle]),
          body: preferPrevious ? previous.body : fallbackBody,
          receivedAt: previous != null &&
                  (fromEvent || previous.receivedAt.isBefore(eventTime))
              ? previous.receivedAt
              : eventTime,
          peerRut: fromEvent ? previous!.peerRut : (peer.isEmpty ? null : peer),
          sources: {...?previous?.sources, source}.toList(),
          remoteIds:
              {...?previous?.remoteIds, if (pushId.isNotEmpty) pushId}.toList(),
          fingerprint: fingerprint ?? previous?.fingerprint,
        );
        if (_sameEntry(previous, entry)) return;
        final saved = await prefs.setString(
            _key(rut, entry.id), jsonEncode(entry.toJson()));
        if (!saved) throw StateError('No se pudo persistir la notificación');
        changes.value++;
      } catch (error) {
        debugPrint('No se pudo guardar el historial de notificaciones: $error');
      }
    });
    _pendingWrites = write;
    return write;
  }

  static Future<void> clearSession() async {
    _sessionGeneration++;
    _pendingRecoveries.clear();
    await _pendingWrites;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    // Impedir que una nueva notificación se asocie a la cuenta que sale.
    await prefs.remove('rut');
    await prefs.remove('es_admin');
    final sessionKeys = prefs
        .getKeys()
        .where((key) => !key.startsWith(storageKeyPrefix))
        .toList();
    for (final key in sessionKeys) {
      await prefs.remove(key);
    }
  }
}
