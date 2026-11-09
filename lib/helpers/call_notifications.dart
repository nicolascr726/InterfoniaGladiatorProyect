import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

final FlutterLocalNotificationsPlugin callNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const _phoneRingtone = UriAndroidNotificationSound(
  'content://settings/system/ringtone',
);

const AndroidNotificationChannel callsChannel = AndroidNotificationChannel(
  'calls_channel_v6',
  'Llamadas entrantes',
  description: 'Canal prioritario con tono de llamada',
  importance: Importance.max,
  playSound: true,
  sound: _phoneRingtone,
  enableVibration: true,
  audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
);

// Canal predeterminado de Firebase para los avisos que ya lo usaban.
const _firebaseDefaultChannel = AndroidNotificationChannel(
  'calls_channel_v5',
  'Llamadas Citófono',
  description: 'Canal prioritario con tono de llamada',
  importance: Importance.max,
  enableVibration: true,
  audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
);

const AndroidNotificationChannel missedCallsChannel =
    AndroidNotificationChannel(
  'missed_calls_channel',
  'Llamadas perdidas',
  description: 'Avisos de llamadas no contestadas u ocupadas',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

const AndroidNotificationChannel messagesChannel = AndroidNotificationChannel(
  'messages_channel',
  'Mensajes',
  description: 'Notificaciones de mensajes entre Depto/Casa y conserjería',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

class CallNotifications {
  static const acceptAction = 'accept_call';
  static const rejectAction = 'reject_call';
  static const _endedPrefix = 'ended_call_';
  static final _endedCalls = SharedPreferencesAsync();
  static bool _initialized = false;

  static Future<void> ensureInitialized({
    DidReceiveNotificationResponseCallback? onResponse,
    DidReceiveBackgroundNotificationResponseCallback? onBackgroundResponse,
  }) async {
    if (!_initialized) {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidSettings);
      await callNotificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: onResponse,
        onDidReceiveBackgroundNotificationResponse: onBackgroundResponse,
      );
      _initialized = true;
    }

    final android =
        callNotificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await android?.createNotificationChannel(callsChannel);
    await android?.createNotificationChannel(_firebaseDefaultChannel);
    await android?.createNotificationChannel(missedCallsChannel);
    await android?.createNotificationChannel(messagesChannel);
  }

  static int _notificationId(String callId) {
    var hash = 0;
    for (final unit in callId.codeUnits) {
      hash = (hash * 31 + unit) & 0x3fffffff;
    }
    return 0x40000000 | hash;
  }

  static Map<String, dynamic>? readCallPayload(String? payload) {
    if (payload == null || !payload.startsWith('{')) return null;
    try {
      final data = jsonDecode(payload);
      return data is Map<String, dynamic> && data['type'] == 'call'
          ? data
          : null;
    } on FormatException {
      return null;
    }
  }

  static Future<bool> hasEnded(String callId) async {
    final until = await _endedCalls.getInt('$_endedPrefix$callId') ?? 0;
    return until > DateTime.now().millisecondsSinceEpoch;
  }

  static Future<void> showIncomingCall(Map<String, dynamic> data,
      {required bool silent}) async {
    final callId = data['call_id']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(data['expires_at']?.toString() ?? '');
    if (callId.isEmpty || expiresAt == null || await hasEnded(callId)) return;
    await ensureInitialized();
    final timeout = expiresAt.difference(DateTime.now()).inMilliseconds;
    if (timeout <= 0) return;
    final caller = data['caller_dpto'] ?? data['caller_rut'] ?? 'Conserjería';
    await callNotificationsPlugin.show(
      _notificationId(callId),
      data['tipo'] == 'video'
          ? 'Videollamada entrante'
          : 'Llamada de audio entrante',
      'De: $caller',
      NotificationDetails(
        android: AndroidNotificationDetails(
          callsChannel.id,
          callsChannel.name,
          channelDescription: callsChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          visibility: NotificationVisibility.public,
          ongoing: true,
          autoCancel: false,
          sound: _phoneRingtone,
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          silent: silent,
          timeoutAfter: timeout,
          // FLAG_INSISTENT: Android detiene el tono al cancelar la notificación.
          additionalFlags: silent ? null : Int32List.fromList([4]),
          actions: const [
            AndroidNotificationAction(acceptAction, 'Aceptar',
                showsUserInterface: true),
            AndroidNotificationAction(rejectAction, 'Rechazar'),
          ],
          color: const Color(0xFF448AFF),
          icon: '@mipmap/ic_launcher',
        ),
      ),
      payload: jsonEncode(data),
    );
    if (await hasEnded(callId)) await cancelIncoming(callId);
  }

  static Future<void> showMissedCall({
    required String caller,
    String? reason,
    int? id,
  }) async {
    await ensureInitialized();
    final notificationId =
        id ?? (2000 + DateTime.now().millisecondsSinceEpoch.remainder(700000));
    final detail = (reason == null || reason.isEmpty || reason == 'ocupado')
        ? 'No fue contestada porque la línea estaba ocupada.'
        : reason;

    await callNotificationsPlugin.show(
      notificationId,
      '☎️ Llamada perdida',
      '$caller · $detail',
      NotificationDetails(
        android: AndroidNotificationDetails(
          missedCallsChannel.id,
          missedCallsChannel.name,
          channelDescription: missedCallsChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.status,
          visibility: NotificationVisibility.public,
          autoCancel: true,
          color: const Color(0xFFFF5252),
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }

  static Future<void> showChatMessage({
    required String sender,
    required String body,
    String? peerRut,
    int? id,
  }) async {
    await ensureInitialized();
    final notificationId =
        id ?? (3000 + DateTime.now().millisecondsSinceEpoch.remainder(700000));
    final cleanBody = body.trim().isEmpty ? 'Nuevo mensaje' : body.trim();

    await callNotificationsPlugin.show(
      notificationId,
      'Nuevo mensaje de $sender',
      cleanBody,
      NotificationDetails(
        android: AndroidNotificationDetails(
          messagesChannel.id,
          messagesChannel.name,
          channelDescription: messagesChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          autoCancel: true,
          color: const Color(0xFF448AFF),
          icon: '@mipmap/ic_launcher',
        ),
      ),
      payload: peerRut == null || peerRut.isEmpty
          ? 'chat_message'
          : 'chat_message:$peerRut',
    );
  }

  static Future<void> markEnded(String callId) async {
    final now = DateTime.now();
    try {
      await _endedCalls.setInt('$_endedPrefix$callId',
          now.add(const Duration(minutes: 2)).millisecondsSinceEpoch);
    } finally {
      await cancelIncoming(callId);
    }
    final entries = await _endedCalls.getAll();
    for (final entry in entries.entries) {
      final value = entry.value;
      if (entry.key.startsWith(_endedPrefix) &&
          value is int &&
          value <= now.millisecondsSinceEpoch) {
        await _endedCalls.remove(entry.key);
      }
    }
  }

  static Future<void> cancelIncoming(String callId) =>
      callNotificationsPlugin.cancel(_notificationId(callId));
}
