import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../config.dart';

class PushNotificationService {
  static final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;

  static Future<void> initAndRegisterToken(String rut) async {
    try {
      // 1. Pedir permisos al usuario (Aquí sale la alerta en iOS)
      NotificationSettings settings = await _firebaseMessaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        debugPrint('Permiso concedido para notificaciones');

        // 🔥 ESPERA INTELIGENTE (AHORA SÍ EN EL LUGAR CORRECTO) 🔥
        // Apple empieza a generar el token justo después de dar el permiso.
        if (!kIsWeb && Platform.isIOS) {
          String? apnsToken = await _firebaseMessaging.getAPNSToken();
          int reintentos = 0;
          
          // Esperamos hasta 5 segundos a que Apple nos entregue la llave
          while (apnsToken == null && reintentos < 5) {
            await Future.delayed(const Duration(seconds: 1));
            apnsToken = await _firebaseMessaging.getAPNSToken();
            reintentos++;
          }
          
          if (apnsToken == null) {
            debugPrint('⚠️ Advertencia: No se obtuvo el APNs token tras 5 segundos.');
          } else {
            debugPrint('✅ Token APNs de Apple listo: $apnsToken');
          }
        }

        // 2. Obtener el token general (FCM)
        String? token = await _firebaseMessaging.getToken();

        if (token != null) {
          debugPrint('Token FCM obtenido: $token');
          // 3. Enviar el token al backend
          await _enviarTokenAlBackend(rut, token);
        }
      } else {
        debugPrint('Permiso denegado por el usuario');
      }
    } catch (e) {
      debugPrint('Error al inicializar notificaciones: $e');
    }
  }

  static Future<void> _enviarTokenAlBackend(String rut, String token) async {
    try {
      final url = Uri.parse('$kBaseUrl/update-fcm-token');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rut': rut,
          'fcm_token': token,
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('Token FCM actualizado en la base de datos correctamente.');
      } else {
        debugPrint('Error al actualizar token: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error de red al enviar el token al backend: $e');
    }
  }
}