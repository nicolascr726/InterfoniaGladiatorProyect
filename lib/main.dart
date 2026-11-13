import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'config.dart';
import 'firebase_options.dart'; // 🔥 NUEVO: Importamos el archivo de configuración
import 'screens/conserje_screen.dart';
import 'screens/login_screen.dart';
import 'screens/residente_screen.dart';
import 'screens/llamada_screen.dart';
import 'screens/citofono_audio_screen.dart';
import 'helpers/citofono_call_utils.dart';
import 'helpers/call_notifications.dart';
import 'helpers/incoming_call_dialog.dart';
import 'helpers/message_navigation.dart';
import 'widgets/mensajes_modal.dart';
import 'services/notification_history_service.dart';
import 'services/emergency_service.dart';
import 'screens/emergencia_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:ui';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
const _duracionSesion = Duration(hours: 4);
const _vencimientoSesionKey = 'sesion_vence_en_ms';
final _respuestasNotificaciones = StreamController<NotificationResponse>.broadcast();
final _respuestasPendientes = <NotificationResponse>[];
const _accionesLlamadaAndroid = MethodChannel('gladiator/call_notification_actions');

void _recibirRespuestaLocal(NotificationResponse respuesta) {
  if (_respuestasNotificaciones.hasListener) {
    _respuestasNotificaciones.add(respuesta);
  } else {
    _respuestasPendientes.add(respuesta);
  }
}

Future<String?> _rutSesionPush(Map<String, dynamic> data) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final rut = prefs.getString('rut');
  final vence = prefs.getInt(_vencimientoSesionKey) ?? 0;
  final destino = data['rut'] ?? data['target_rut'];
  if (rut == null || rut.isEmpty || rut == data['caller_rut'] ||
      (destino != null && destino != rut) ||
      vence <= DateTime.now().millisecondsSinceEpoch) {
    return null;
  }
  return rut;
}

Future<bool> _responderLlamadaPush(String callId, String rut, String accion) async {
  try {
    final respuesta = await http.post(
      Uri.parse('$kBaseUrl/api/llamadas/${Uri.encodeComponent(callId)}/notificacion'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'rut': rut, 'accion': accion}),
    ).timeout(const Duration(seconds: 6));
    if (respuesta.statusCode == 200) {
      final data = jsonDecode(respuesta.body);
      return data is Map && data['success'] == true;
    }
    debugPrint('El servidor respondió HTTP ${respuesta.statusCode} al $accion la llamada.');
    return false;
  } catch (e) {
    debugPrint('No se pudo responder a la llamada: $e');
    return false;
  }
}

Future<void> _rechazarLlamadaPush(Map<String, dynamic> data) async {
  final callId = data['call_id']?.toString() ?? '';
  if (callId.isEmpty) return;
  final cerrarAviso = CallNotifications.markEnded(callId).catchError((Object error) {
    debugPrint('No se pudo cerrar el aviso de llamada: $error');
  });
  final rut = await _rutSesionPush(data);
  if (rut != null) await _responderLlamadaPush(callId, rut, 'rechazar');
  await cerrarAviso;
}

@pragma('vm:entry-point')
void _respuestaNotificacionEnSegundoPlano(NotificationResponse respuesta) async {
  if (respuesta.actionId != CallNotifications.rejectAction) return;
  try {
    final data = CallNotifications.readCallPayload(respuesta.payload);
    if (data != null) await _rechazarLlamadaPush(data);
  } catch (error) {
    debugPrint('No se pudo rechazar la llamada desde Android: $error');
  }
}

Future<void> _cerrarLlamadaPush(Map<String, dynamic> data) async {
  final callId = data['call_id']?.toString() ?? '';
  if (callId.isEmpty) return;
  IncomingCallDialog.resolve(callId, IncomingCallDecision.ended);
  if (Platform.isAndroid) await CallNotifications.markEnded(callId);
}

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

// ─── HANDLER DE SEGUNDO PLANO ──────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  
  // Inicializamos con las opciones de plataforma también en segundo plano
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  final type = message.data['type'];
  if (type == 'emergency') return;
  if (type == 'call_ended') {
    if (Platform.isAndroid) await _cerrarLlamadaPush(message.data);
    return;
  }
  if (type == 'call') {
    if (Platform.isAndroid && await _rutSesionPush(message.data) != null) {
      await CallNotifications.ensureInitialized(
        onBackgroundResponse: _respuestaNotificacionEnSegundoPlano,
      );
      await CallNotifications.showIncomingCall(message.data, silent: false);
    }
    await NotificationHistoryService.recordPush(message, confirmDelivery: true);
    return;
  }
  await NotificationHistoryService.recordPush(message, confirmDelivery: true);
  if (type == 'notification_record') return;

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
  NotificationResponse? respuestaInicial;
  try {
    await CallNotifications.ensureInitialized(
      onResponse: _recibirRespuestaLocal,
      onBackgroundResponse: _respuestaNotificacionEnSegundoPlano,
    );
    final inicio = await callNotificationsPlugin.getNotificationAppLaunchDetails();
    if (inicio?.didNotificationLaunchApp == true) respuestaInicial = inicio?.notificationResponse;
  } catch (e) {
    debugPrint('Error crítico evitado en CallNotifications: $e');
  }

  // 4. ¡Garantizar que la interfaz gráfica siempre arranque!
  runApp(CitofonoApp(respuestaInicial: respuestaInicial));
}

class CitofonoApp extends StatefulWidget {
  final EmergencyService? emergencyService;
  final NotificationResponse? respuestaInicial;

  const CitofonoApp({super.key, this.emergencyService, this.respuestaInicial});

  @override
  State<CitofonoApp> createState() => _CitofonoAppState();
}

class _ObservadorSesion extends NavigatorObserver {
  _ObservadorSesion(this.alReemplazarRuta);

  final VoidCallback alReemplazarRuta;

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    alReemplazarRuta();
  }
}

class _CitofonoAppState extends State<CitofonoApp>
    with WidgetsBindingObserver {
  late final _emergency = widget.emergencyService ?? EmergencyService.instance;
  final _cambiosEmergencia = ValueNotifier(0);
  late final Future<Widget> _pantallaInicial = _restaurarSesion();
  late final _observadorSesion = _ObservadorSesion(() {
    unawaited(_actualizarSesion());
  });
  Timer? _temporizadorSesion;
  DateTime? _vencimientoSesion;
  bool _cerrandoSesionVencida = false;
  StreamSubscription<NotificationResponse>? _respuestasLocales;
  final _llamadasPushEnCurso = <String>{};
  bool get _usaAccionesAndroid => defaultTargetPlatform == TargetPlatform.android;

  Future<Widget> _restaurarSesion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rut = prefs.get('rut');
      final esAdmin = prefs.get('es_admin');
      if (rut is String &&
          rut.trim().isNotEmpty &&
          esAdmin is int &&
          (esAdmin == 0 || esAdmin == 1)) {
        final guardado = prefs.get(_vencimientoSesionKey);
        if (guardado is int) {
          final vencimiento = DateTime.fromMillisecondsSinceEpoch(guardado);
          final restante = vencimiento.difference(DateTime.now());
          if (restante > Duration.zero && restante <= _duracionSesion) {
            if (mounted) _vigilarSesion(vencimiento);
            return esAdmin == 1 ? const ConserjeScreen() : const ResidenteScreen();
          }
        }
        await NotificationHistoryService.clearSession();
      }
    } catch (e) {
      debugPrint('No se pudo leer la sesión guardada: $e');
    }
    return const LoginScreen();
  }

  Future<void> _actualizarSesion() async {
    // Ingresar y cerrar sesión son los únicos flujos que reemplazan la ruta.
    final nuevoVencimiento = DateTime.now().add(_duracionSesion);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _cerrandoSesionVencida) return;
      final rut = prefs.getString('rut') ?? '';
      if (rut.isEmpty) {
        _temporizadorSesion?.cancel();
        _vencimientoSesion = null;
      } else if (_vencimientoSesion == null) {
        _vigilarSesion(nuevoVencimiento);
        final guardado = await prefs.setInt(
          _vencimientoSesionKey,
          nuevoVencimiento.millisecondsSinceEpoch,
        );
        if (!guardado) throw StateError('No se pudo guardar el vencimiento');
      }
    } catch (e) {
      debugPrint('No se pudo actualizar la sesión: $e');
      await _cerrarSesionVencida();
    }
  }

  void _vigilarSesion(DateTime vencimiento) {
    _vencimientoSesion = vencimiento;
    _temporizadorSesion?.cancel();
    _temporizadorSesion = Timer(vencimiento.difference(DateTime.now()), () {
      unawaited(_cerrarSesionVencida());
    });
  }

  Future<void> _cerrarSesionVencida() async {
    if (!mounted || _cerrandoSesionVencida) return;
    _cerrandoSesionVencida = true;
    _temporizadorSesion?.cancel();
    _vencimientoSesion = null;
    try {
      await NotificationHistoryService.clearSession();
    } catch (e) {
      debugPrint('No se pudo limpiar la sesión vencida: $e');
    } finally {
      _cerrandoSesionVencida = false;
      if (mounted) {
        navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (_) => false,
        );
      }
    }
  }

  void _actualizarCapaEmergencia() {
    // Al retirar una pantalla, su socket se desconecta mientras Flutter
    // todavía está cerrando el árbol de widgets de esa ruta.
    scheduleMicrotask(() {
      if (mounted) _cambiosEmergencia.value++;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _emergency.addListener(_actualizarCapaEmergencia);
    _respuestasLocales = _respuestasNotificaciones.stream.listen((respuesta) {
      unawaited(_procesarRespuestaLocal(respuesta));
    });
    if (_usaAccionesAndroid) {
      _accionesLlamadaAndroid.setMethodCallHandler((llamada) async {
        if (llamada.method == 'acceptedCallAvailable') {
          unawaited(_recuperarAceptacionAndroid());
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_recuperarAceptacionAndroid());
      });
    }
    final iniciales = [
      if (widget.respuestaInicial case final respuesta?) respuesta,
      ..._respuestasPendientes,
    ];
    _respuestasPendientes.clear();
    if (iniciales.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final respuesta in iniciales) {
          unawaited(_procesarRespuestaLocal(respuesta));
        }
      });
    }
    unawaited(_pantallaInicial.then((_) {
      if (mounted) _setupInteractions();
    }));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isAndroid && state == AppLifecycleState.hidden) {
      FlutterRingtonePlayer().stop();
    }
    if (state == AppLifecycleState.resumed) {
      final vencimiento = _vencimientoSesion;
      if (vencimiento != null && !DateTime.now().isBefore(vencimiento)) {
        unawaited(_cerrarSesionVencida());
        return;
      }
      if (_usaAccionesAndroid) unawaited(_recuperarAceptacionAndroid());
      unawaited(_emergency.sync());
    }
  }

  @override
  Future<bool> didPopRoute() async => _emergency.current != null;

  @override
  void dispose() {
    _temporizadorSesion?.cancel();
    unawaited(_respuestasLocales?.cancel());
    if (_usaAccionesAndroid) _accionesLlamadaAndroid.setMethodCallHandler(null);
    _emergency.removeListener(_actualizarCapaEmergencia);
    _cambiosEmergencia.dispose();
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
        if (message.data['type'] == 'call_ended') {
          await _cerrarLlamadaPush(message.data);
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
          if (Platform.isAndroid && await _rutSesionPush(message.data) != null) {
            await CallNotifications.showIncomingCall(message.data, silent: true);
          }
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
    if (message.data['type'] == 'call') {
      unawaited(_abrirLlamadaPush(message.data, confirmar: false));
    }
  }

  Future<void> _procesarRespuestaLocal(NotificationResponse respuesta) async {
    if (respuesta.payload?.startsWith('chat_message') == true) {
      await openMessagesFromNotification();
      return;
    }
    final data = CallNotifications.readCallPayload(respuesta.payload);
    if (data == null) return;
    if (respuesta.actionId == CallNotifications.rejectAction) {
      await _rechazarLlamadaPush(data);
    } else if (_usaAccionesAndroid &&
        respuesta.actionId == CallNotifications.acceptAction) {
      await _recuperarAceptacionAndroid(respaldo: data);
    } else {
      await _abrirLlamadaPush(
        data,
        confirmar: respuesta.actionId != CallNotifications.acceptAction,
      );
    }
  }

  Future<void> _recuperarAceptacionAndroid({Map<String, dynamic>? respaldo}) async {
    Map<String, dynamic>? data;
    try {
      final payload = await _accionesLlamadaAndroid.invokeMethod<String>('takeAcceptedCall');
      data = CallNotifications.readCallPayload(payload);
    } catch (error) {
      debugPrint('[Aceptar push] No se pudo leer la acción de Android: $error');
    }
    data ??= respaldo;
    if (!mounted || data == null) return;
    debugPrint('[Aceptar push] Acción recibida en Flutter');
    await _abrirLlamadaPush(data, confirmar: false);
  }

  void _limpiarAvisoAlAceptar(String callId, {bool finalizado = false}) {
    if (!_usaAccionesAndroid || callId.isEmpty) return;
    final limpiar = finalizado
        ? CallNotifications.markEnded(callId)
        : CallNotifications.cancelIncoming(callId);
    unawaited(limpiar.catchError((Object error) {
      debugPrint('[Aceptar push] No se pudo retirar el aviso local: $error');
    }));
  }

  Future<void> _abrirLlamadaPush(Map<String, dynamic> data, {required bool confirmar}) async {
    final callerRut = data['caller_rut']?.toString() ?? '';
    final callId = data['call_id']?.toString() ?? '';
    if (callerRut.isEmpty || !_llamadasPushEnCurso.add(callId)) return;
    try {
      await _pantallaInicial;
      if (navigatorKey.currentState == null) {
        await WidgetsBinding.instance.endOfFrame;
      }
      final rut = await _rutSesionPush(data);
      final context = navigatorKey.currentContext;
      if (!mounted || _cerrandoSesionVencida || rut == null || context == null) {
        debugPrint('[Aceptar push] Sesión o navegación indisponible');
        return;
      }
      final esCitofono = isCitofonoAudioCall(data);
      final restante = IncomingCallDialog.remainingTime(data, isCitofono: esCitofono);
      if (restante == Duration.zero) {
        debugPrint('[Aceptar push] La llamada superó su plazo para contestar');
        return;
      }
      _limpiarAvisoAlAceptar(callId);
      if (!context.mounted) return;
      if (confirmar) {
        if (IncomingCallDialog.isShowing(callId)) return;
        final decision = await IncomingCallDialog(
          payload: data, isCitofono: esCitofono, onStopRinging: () {},
        ).show(context);
        if (decision == IncomingCallDecision.reject) {
          await _rechazarLlamadaPush(data);
          return;
        }
        if (decision != IncomingCallDecision.accept) return;
      }
      if (callId.isNotEmpty) {
        // La marca local también se guarda al retirar un diálogo. La vigencia
        // de la llamada la confirma el servidor.
        if (!await _responderLlamadaPush(callId, rut, 'aceptar')) {
          IncomingCallDialog.resolve(callId, IncomingCallDecision.ended);
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(content: Text('La llamada ya no está disponible.')),
            );
          }
          return;
        }
        debugPrint('[Aceptar push] El servidor confirmó que la llamada sigue vigente');
        if (!mounted || _cerrandoSesionVencida) return;
        if (IncomingCallDialog.resolve(callId, IncomingCallDecision.accept)) return;
        _limpiarAvisoAlAceptar(callId, finalizado: true);
      }
      if (!mounted || _cerrandoSesionVencida || await _rutSesionPush(data) != rut) return;
      debugPrint('[Aceptar push] Abriendo pantalla de llamada');
      await navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => esCitofono
              ? CitofonoAudioScreen(
                  room: callerRut, isCaller: false, miRut: rut,
                  rutDestino: callerRut, callId: callId,
                )
              : LlamadaScreen(
                  room: callerRut, isCaller: false, miRut: rut,
                  tipo: data['tipo']?.toString() ?? 'video',
                  rutDestino: callerRut, callId: callId,
                ),
        ),
      );
    } catch (e) {
      debugPrint('[Aceptar push] No se pudo abrir la llamada: $e');
    } finally {
      _llamadasPushEnCurso.remove(callId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gladiator Interfonia',
      navigatorKey: navigatorKey,
      navigatorObservers: [_observadorSesion],
      debugShowCheckedModeBanner: false,
      builder: (context, child) => AnimatedBuilder(
        animation: _cambiosEmergencia,
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
      home: FutureBuilder<Widget>(
        future: _pantallaInicial,
        builder: (context, snapshot) =>
            snapshot.data ??
            const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
    );
  }
}
