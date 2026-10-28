import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'firebase_options.dart'; // 🔥 NUEVO: Importamos el archivo de configuración
import 'screens/login_screen.dart';
import 'screens/llamada_screen.dart';
import 'screens/citofono_audio_screen.dart';
import 'helpers/citofono_call_utils.dart';
import 'helpers/call_notifications.dart';
import 'helpers/message_navigation.dart';
import 'widgets/mensajes_modal.dart';
import 'services/notification_history_service.dart';
import 'services/emergency_service.dart';
import 'screens/emergencia_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:ui';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> openMessagesFromNotification({String? peerRut}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kOpenMessagesPendingKey, true);

  final rut = prefs.getString('rut') ?? '';
  final context = navigatorKey.currentContext;
  if (rut.isEmpty || context == null) return;

  await prefs.setBool(kOpenMessagesPendingKey, false);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MensajesModal(miRut: rut),
    );
  });
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

// ─── HANDLER DE SEGUNDO PLANO ──────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  
  // Inicializamos con las opciones de plataforma también en segundo plano
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // El sistema muestra la notificación; la app consulta su vigencia al volver.
  if (message.data['type'] == 'emergency') return;

  await NotificationHistoryService.recordPush(message, confirmDelivery: true);
  final type = message.data['type'];
  if (type == 'notification_record') return;

  if (type == 'call') {
    final callerRut = message.data['caller_rut'];
    final prefs = await SharedPreferences.getInstance();
    final miRut = prefs.getString('rut') ?? '';
    if (callerRut == miRut && miRut.isNotEmpty) return;

    final caller = message.data['caller_dpto'] ?? message.data['caller_rut'] ?? 'Conserjería';

    try {
      FlutterRingtonePlayer().playRingtone();
    } catch (_) {}

    await CallNotifications.showIncomingCall(caller: caller);
    return;
  }

  if (type == 'missed_call') {
    final caller = message.data['caller_dpto'] ?? message.data['caller_rut'] ?? 'Citófono';
    await CallNotifications.showMissedCall(
      caller: caller,
      reason: message.data['reason']?.toString(),
    );
    return;
  }

  if (type == 'chat_message') {
    final sender = message.data['sender_label'] ?? message.data['rut_emisor'] ?? 'Depto/Casa';
    final body = message.data['mensaje'] ?? 'Nuevo mensaje';
    final peerRut = message.data['rut_emisor']?.toString();
    await CallNotifications.showChatMessage(
      sender: sender.toString(),
      body: body.toString(),
      peerRut: peerRut,
    );
  }
}

void main() async {
  // 1. Asegurar que el motor de Flutter esté listo
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = MyHttpOverrides();

  // 2. Inicializar Firebase de forma segura
  try {
    // Inicializamos con las opciones generadas por el CLI
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('🔴 ERROR CRÍTICO: Firebase falló al inicializarse: $e');
  }

  // 3. Inicializar Notificaciones de forma segura
  try {
    await CallNotifications.ensureInitialized(
      onResponse: (response) {
        final payload = response.payload ?? '';
        if (payload.startsWith('chat_message')) {
          openMessagesFromNotification();
          return;
        }
        FlutterRingtonePlayer().stop();
        CallNotifications.cancelIncoming();
      },
    );
  } catch (e) {
    debugPrint('Error crítico evitado en CallNotifications: $e');
  }

  // 4. ¡Garantizar que la interfaz gráfica siempre arranque!
  runApp(const CitofonoApp());
}

class CitofonoApp extends StatefulWidget {
  final EmergencyService? emergencyService;

  const CitofonoApp({super.key, this.emergencyService});

  @override
  State<CitofonoApp> createState() => _CitofonoAppState();
}

class _CitofonoAppState extends State<CitofonoApp>
    with WidgetsBindingObserver {
  late final _emergency = widget.emergencyService ?? EmergencyService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupInteractions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_emergency.sync());
    }
  }

  @override
  Future<bool> didPopRoute() async => _emergency.current != null;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _setupInteractions() async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
        debugPrint('🔔 Mensaje recibido en primer plano');
        if (message.data['type'] == 'emergency') {
          unawaited(_emergency.sync());
          return;
        }
        unawaited(NotificationHistoryService.recordPush(
          message,
          confirmDelivery: true,
        ));
        if (message.data['type'] == 'notification_record') return;
        
        final prefs = await SharedPreferences.getInstance();
        final miRut = prefs.getString('rut') ?? '';
        if (message.data['caller_rut'] == miRut && miRut.isNotEmpty) return;

        if (message.data['type'] == 'call') {
          FlutterRingtonePlayer().playRingtone();
        } else if (message.data['type'] == 'missed_call') {
          FlutterRingtonePlayer().stop();
          final caller = message.data['caller_dpto'] ?? message.data['caller_rut'] ?? 'Citófono';
          CallNotifications.showMissedCall(
            caller: caller,
            reason: message.data['reason']?.toString(),
          );
        } else if (message.data['type'] == 'chat_message') {
          final sender = message.data['sender_label'] ?? message.data['rut_emisor'] ?? 'Depto/Casa';
          final body = message.data['mensaje'] ?? 'Nuevo mensaje';
          final peerRut = message.data['rut_emisor']?.toString();
          CallNotifications.showChatMessage(
            sender: sender.toString(),
            body: body.toString(),
            peerRut: peerRut,
          );
        }
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('📩 Notificación clickeada (app en background)');
        _detenerTodoYEntrar(message);
      });

      FirebaseMessaging.instance.getInitialMessage().then((message) {
        if (message != null) {
          debugPrint('🚀 App abierta desde notificación muerta');
          _detenerTodoYEntrar(message);
        }
      });
    } catch (e) {
      debugPrint('⚠️ Error configurando FirebaseMessaging: $e');
    }
  }

  void _detenerTodoYEntrar(RemoteMessage message) {
    if (message.data['type'] == 'emergency') {
      unawaited(_emergency.sync());
      return;
    }
    unawaited(NotificationHistoryService.recordPush(
      message,
      confirmDelivery: true,
    ));
    if (message.data['type'] == 'notification_record') return;
    if (message.data['type'] == 'chat_message') {
      openMessagesFromNotification(peerRut: message.data['rut_emisor']?.toString());
      return;
    }
    FlutterRingtonePlayer().stop();
    CallNotifications.cancelIncoming();
    _handlePushCall(message);
  }

  void _handlePushCall(RemoteMessage message) async {
    if (message.data['type'] != 'call') {
      return;
    }

    if (message.data['type'] == 'call') {
      final String callerRut = message.data['caller_rut'] ?? 'desconocido';
      final String tipo = message.data['tipo'] ?? 'video';

      final prefs = await SharedPreferences.getInstance();
      final String miRut = prefs.getString('rut') ?? '';

      if (miRut.isEmpty) return;

      final bool esCitofono = isCitofonoAudioCall(message.data);

      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => esCitofono
              ? CitofonoAudioScreen(
                  room: callerRut,
                  isCaller: false,
                  socket: null,
                  miRut: miRut,
                  rutDestino: callerRut,
                  callId: message.data['call_id'],
                )
              : LlamadaScreen(
                  room: callerRut,
                  isCaller: false,
                  tipo: tipo,
                  socket: null,
                  miRut: miRut,
                  rutDestino: callerRut,
                ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gladiator Interfonia',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      builder: (context, child) => AnimatedBuilder(
        animation: _emergency,
        builder: (context, _) {
          final emergency = _emergency.current;
          return Stack(
            fit: StackFit.expand,
            children: [
              ExcludeFocus(
                excluding: emergency != null,
                child: ExcludeSemantics(
                  excluding: emergency != null,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
              if (emergency != null)
                Positioned.fill(
                  child: EmergenciaScreen(
                    key: ValueKey(emergency.id),
                    message: emergency.message,
                    expiresAt: emergency.expiresAt,
                    isConserje: _emergency.isConserje,
                    cancelling: _emergency.cancelling,
                    error: _emergency.error,
                    onCancel: () => unawaited(_emergency.cancel()),
                    canResumeAlarm: () async {
                      await _emergency.sync();
                      return _emergency.current?.id == emergency.id &&
                          _emergency.error == null;
                    },
                  ),
                ),
            ],
          );
        },
      ),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
          surface: const Color(0xFF151C2C),
          primary: const Color(0xFF6366F1),
          secondary: const Color(0xFF06B6D4),
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        fontFamily: 'Roboto',
        useMaterial3: true,
        cardTheme: CardThemeData(
          color: const Color(0xFF151C2C),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          elevation: 2,
        ),
      ),
      home: const LoginScreen(),
    );
  }
}
