import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import '../config.dart';
import 'llamada_screen.dart';
import 'citofono_audio_screen.dart';
import '../helpers/citofono_call_utils.dart';
import '../helpers/call_notifications.dart';
import 'login_screen.dart';
import '../widgets/directorio_modal.dart';
import '../widgets/reportes_modal.dart';
import '../widgets/mensajes_modal.dart';
import '../widgets/puertas_modal.dart';
import '../widgets/notificaciones_panel_modal.dart';
import '../helpers/message_navigation.dart';
import '../services/esp32_audio_bridge.dart';
import '../services/notification_history_service.dart';
import '../services/emergency_service.dart';

enum _OpcionMenuConserje { directorio, mensajes, puertas }

class ConserjeScreen extends StatefulWidget {
  const ConserjeScreen({super.key});

  @override
  State<ConserjeScreen> createState() => _ConserjeScreenState();
}

class _ConserjeScreenState extends State<ConserjeScreen>
    with WidgetsBindingObserver {
  String miRut = '';
  String miNombre = '';
  String miDpto = '';
  late IO.Socket socket;
  bool _socketInicializado = false;
  bool _cerrandoSesion = false;
  Set<String> rutosOcupados = {};
  bool _socketConectado = false;
  bool _socketReconectando = false;
  bool _enviandoAvisoEmergencia = false;
  String? _versionApp;
  final _ringtonePlayer = FlutterRingtonePlayer();
  bool _dialogoEntranteAbierto = false;
  List<NotificationHistoryEntry> _notificaciones = [];
  bool _loadingNotificaciones = true;
  String? _errorNotificaciones;
  int _consultaNotificaciones = 0;

  // Estados locales para mensajes sin leer
  int _mensajesSinLeerTotales = 0;
  Map<String, int> _mensajesSinLeerPorUsuario = {}; 

  void _tocarTono() => _ringtonePlayer.playRingtone();
  void _detenerTono() => _ringtonePlayer.stop();

  // NUEVO: Función para solicitar permisos y registrar el Token FCM

  Future<void> _registrarTokenFCM(String rut) async {
    try {
      // 1. Pedir permisos a iOS/Android (Obligatorio en iPhone)
      NotificationSettings settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      // 2. Si el usuario acepta, obtenemos el token
      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        String? token = await FirebaseMessaging.instance.getToken();
        
        if (token != null) {
          await http.post(
            Uri.parse('$kBaseUrl/registrar-token'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'rut': rut, 'token': token}),
          );
          debugPrint('✅ Token FCM enviado al servidor');
        }
      } else {
        debugPrint('❌ Permisos de notificación denegados por el usuario');
      }

      // 3. Manejo de renovación de tokens
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        await http.post(
          Uri.parse('$kBaseUrl/registrar-token'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'rut': rut, 'token': newToken}),
        );
        debugPrint('🔄 Token FCM renovado y enviado al servidor');
      });
    } catch (e) {
      debugPrint('❌ Error obteniendo token FCM: $e');
    }
  }
  // =========================================================
  // =========================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationHistoryService.changes.addListener(_actualizarNotificaciones);
    _cargarVersionApp();
    _cargarSesion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _actualizarNotificaciones();
      if (_socketInicializado && !_cerrandoSesion && !socket.connected) {
        socket.connect();
      }
      unawaited(_recuperarNotificacionesPendientes());
    }
  }

  Future<void> _recuperarNotificacionesPendientes() async {
    if (!mounted || _cerrandoSesion || miRut.isEmpty) return;
    final rut = miRut;
    try {
      await NotificationHistoryService.recoverPending(rut);
    } catch (error) {
      // La cola del servidor conserva los avisos hasta confirmar su guardado.
      debugPrint('No se pudieron recuperar las notificaciones pendientes: $error');
    }
  }

  Future<void> _recibirRegistroNotificacion(Map<String, dynamic> registro) async {
    if (!mounted || _cerrandoSesion || miRut.isEmpty) return;
    final rut = miRut;
    try {
      await NotificationHistoryService.receiveAndConfirm(rut, registro);
    } catch (error) {
      debugPrint('No se pudo guardar una notificación recibida: $error');
      if (mounted && !_cerrandoSesion && rut == miRut) {
        setState(() => _errorNotificaciones =
            'No se pudo guardar una notificación recibida.');
      }
    }
  }

  void _actualizarNotificaciones() {
    if (mounted && !_cerrandoSesion && miRut.isNotEmpty) {
      unawaited(_cargarNotificaciones());
    }
  }

  Future<void> _cargarNotificaciones() async {
    if (!mounted || _cerrandoSesion || miRut.isEmpty) return;
    final consulta = ++_consultaNotificaciones;
    final rut = miRut;
    try {
      final notificaciones = await NotificationHistoryService.load(rut);
      if (!mounted ||
          _cerrandoSesion ||
          consulta != _consultaNotificaciones ||
          rut != miRut) {
        return;
      }
      setState(() {
        _notificaciones = notificaciones;
        _loadingNotificaciones = false;
        _errorNotificaciones = null;
      });
    } catch (_) {
      if (!mounted || _cerrandoSesion ||
          consulta != _consultaNotificaciones || rut != miRut) {
        return;
      }
      setState(() {
        _loadingNotificaciones = false;
        _errorNotificaciones = 'No se pudieron cargar las notificaciones.';
      });
    }
  }

  Future<bool> _descartarNotificacion(
      NotificationHistoryEntry notificacion) async {
    if (!mounted || _cerrandoSesion || miRut.isEmpty) return false;
    final rut = miRut;
    try {
      await NotificationHistoryService.dismiss(rut, notificacion.id);
      return mounted && !_cerrandoSesion && miRut == rut;
    } catch (_) {
      if (mounted && !_cerrandoSesion) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo descartar la notificación. Inténtalo nuevamente.'),
          ),
        );
      }
      return false;
    }
  }

  void _registrarNotificacion(
    String type,
    dynamic data, {
    String? title,
    String? body,
  }) {
    if (_cerrandoSesion || miRut.isEmpty) return;
    unawaited(NotificationHistoryService.recordEvent(
      rut: miRut,
      type: type,
      data: data is Map ? Map<String, dynamic>.from(data) : {},
      title: title,
      body: body,
    ));
  }

  Future<void> _cargarVersionApp() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim();
      final compilacion = info.buildNumber.trim();
      if (!mounted) return;
      setState(() {
        _versionApp = version.isEmpty
            ? 'Versión no disponible'
            : 'v $version${compilacion.isEmpty ? '' : '+$compilacion'}';
      });
    } catch (e) {
      debugPrint('No se pudo consultar la versión de la aplicación: $e');
      if (mounted) setState(() => _versionApp = 'Versión no disponible');
    }
  }

  // --- MODIFICADO: Ahora también carga los contadores guardados al abrir la app ---
  Future<void> _cargarSesion() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Cargar datos de usuario
    final rutCargado = prefs.getString('rut') ?? '';
    final nombreCargado = prefs.getString('nombre') ?? '';
    final dptoCargado = prefs.getString('dpto') ?? '';

    // Cargar contadores persistentes
    final totalesGuardados = prefs.getInt('unread_msg_totales') ?? 0;
    final mapGuardadoStr = prefs.getString('unread_msg_por_usuario') ?? '{}';
    
    Map<String, int> mapCargado = {};
    try {
      final Map<String, dynamic> decoded = jsonDecode(mapGuardadoStr);
      mapCargado = decoded.map((key, value) => MapEntry(key, value as int));
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      miRut = rutCargado;
      miNombre = nombreCargado;
      miDpto = dptoCargado;
      _mensajesSinLeerTotales = totalesGuardados;
      _mensajesSinLeerPorUsuario = mapCargado;
    });
    _actualizarNotificaciones();

    // NUEVO: Ejecutar el registro del token si el RUT existe
    if (miRut.isNotEmpty) {
      _registrarTokenFCM(miRut);
    }

    _conectarSocket();
    unawaited(_recuperarNotificacionesPendientes());
    _abrirMensajesSiPendiente();
  }

  // --- NUEVO: Función auxiliar para guardar el estado actual en el disco ---
  Future<void> _guardarContadoresEnDisco() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('unread_msg_totales', _mensajesSinLeerTotales);
    await prefs.setString('unread_msg_por_usuario', jsonEncode(_mensajesSinLeerPorUsuario));
  }

  Future<void> _abrirMensajesSiPendiente() async {
    final prefs = await SharedPreferences.getInstance();
    final pendiente = prefs.getBool(kOpenMessagesPendingKey) ?? false;
    if (!pendiente || miRut.isEmpty) return;

    await prefs.setBool(kOpenMessagesPendingKey, false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _abrirMensajes();
    });
  }

  void _conectarSocket() {
    socket = IO.io(kBaseUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });
    _socketInicializado = true;
    EmergencyService.instance.attachSocket(
      socket,
      rut: miRut,
      isConserje: true,
    );

    socket.onConnect((_) {
      if (!mounted || _cerrandoSesion) return;
      setState(() {
        _socketConectado = true;
        _socketReconectando = false;
      });
      final rut = miRut;
      socket.emitWithAck('register', {'room': rut}, ack: (respuesta) {
        if (!mounted || _cerrandoSesion || rut != miRut || !socket.connected) {
          return;
        }
        if (respuesta is Map && respuesta['success'] == true) {
          unawaited(_recuperarNotificacionesPendientes());
        }
      });
    });

    socket.onDisconnect((_) {
      if (!mounted || _cerrandoSesion) return;
      setState(() {
        _socketConectado = false;
        _socketReconectando = true;
      });
    });

    socket.onConnectError((e) {
      if (!mounted || _cerrandoSesion) return;
      setState(() {
        _socketConectado = false;
        _socketReconectando = true;
      });
      debugPrint('Error de conexión (Socket): $e');
    });

    socket.on('notification-recorded', (data) {
      if (data is! Map) return;
      unawaited(_recibirRegistroNotificacion(Map<String, dynamic>.from(data)));
    });

    socket.on('incoming-call', (data) {
      if (!mounted) return;
      if (data is Map && data['caller_rut'] == miRut) return;
      _registrarNotificacion('call', data);
      _mostrarLlamadaEntrante(data);
    });

    socket.on('user-status', (data) {
      if (!mounted) return;
      setState(() {
        if (data['ocupado'] == true) {
          rutosOcupados.add(data['rut'].toString());
        } else {
          rutosOcupados.remove(data['rut'].toString());
        }
      });
    });

    socket.on('busy', (_) {
      if (!mounted) return;
      _registrarNotificacion(
        'busy',
        null,
        title: 'Línea ocupada',
        body: 'El usuario está en otra llamada.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔴 Línea ocupada. El usuario está en otra llamada.'),
          backgroundColor: Color(0xFFff5252),
        ),
      );
    });

    // --- MODIFICADO: Incrementa el contador y lo guarda inmediatamente en el disco ---
    socket.on('chat-message', (data) {
      if (!mounted || data is! Map) return;
      final receptor = (data['rut_receptor'] ?? '').toString();
      final emisor = (data['rut_emisor'] ?? '').toString();
      
      if (receptor == miRut && emisor != miRut) {
        _registrarNotificacion('chat_message', data);
        setState(() {
          _mensajesSinLeerTotales++;
          _mensajesSinLeerPorUsuario[emisor] = (_mensajesSinLeerPorUsuario[emisor] ?? 0) + 1;
        });
        
        // Guardar persistencia de manera asíncrona
        _guardarContadoresEnDisco();

        final sender = (data['sender_label'] ?? emisor).toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Nuevo mensaje de $sender'),
            backgroundColor: const Color(0xFF448AFF),
            action: SnackBarAction(
              label: 'Abrir',
              textColor: Colors.white,
              onPressed: _abrirMensajes,
            ),
          ),
        );
      }
    });

    socket.on('missed-call', (data) {
      if (!mounted) return;
      _registrarNotificacion('missed_call', data);
      _detenerTono();
      if (_dialogoEntranteAbierto) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      final caller = data is Map
          ? (data['caller_dpto'] ?? data['caller_rut'] ?? 'Citófono').toString()
          : 'Citófono';
      CallNotifications.showMissedCall(
        caller: caller,
        reason: data is Map ? data['reason']?.toString() : 'ocupado',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('☎️ Llamada perdida de $caller'),
          backgroundColor: const Color(0xFFFF5252),
        ),
      );
    });

    socket.on('end-call', (data) {
      if (!mounted) return;
      _detenerTono();
      if (_dialogoEntranteAbierto) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    });
    socket.connect();
  }

  void _mostrarLlamadaEntrante(dynamic data) {
    if (!mounted) return;

    final Map<dynamic, dynamic> payload = data is Map ? data : <dynamic, dynamic>{};
    final bool esCitofono = isCitofonoAudioCall(payload);
    Timer? handsetTimer;
    bool handled = false;

    void cancelHandsetTimer() {
      handsetTimer?.cancel();
      handsetTimer = null;
    }

    void aceptarEntrante({required bool desdeBanana}) {
      if (handled || !mounted) return;
      handled = true;
      cancelHandsetTimer();
      _detenerTono();
      Navigator.of(context, rootNavigator: true).pop();

      Navigator.push(context, MaterialPageRoute(
        builder: (_) => esCitofono
            ? CitofonoAudioScreen(
                room: payload['caller_rut']?.toString() ?? '',
                isCaller: false,
                socket: socket,
                miRut: miRut,
                rutDestino: payload['caller_rut']?.toString() ?? '',
                callId: payload['call_id']?.toString(),
                initialSpeakerOn: !desdeBanana,
              )
            : LlamadaScreen(
                room: payload['caller_rut']?.toString() ?? '',
                isCaller: false,
                tipo: payload['tipo']?.toString() ?? 'video',
                socket: socket,
                miRut: miRut,
                rutDestino: payload['caller_rut']?.toString() ?? '',
              ),
      ));
    }

    Future<void> revisarBanana() async {
      if (handled || !mounted) return;
      final state = await Esp32AudioBridge.getHandsetState();
      if (handled || !mounted) return;
      if (state['handsetLifted'] == true) {
        aceptarEntrante(desdeBanana: true);
      }
    }

    _tocarTono();

    if (esCitofono) {
      Esp32AudioBridge.resetHandsetState().then((_) {
        if (handled || !mounted) return;
        handsetTimer = Timer.periodic(
          const Duration(milliseconds: 250),
          (_) => revisarBanana(),
        );
        revisarBanana();
      });
    }

    _dialogoEntranteAbierto = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF222233),
        title: const Text('📞 Llamada entrante', style: TextStyle(color: Colors.white)),
        content: Text(
          'De: ${payload['caller_dpto'] ?? payload['caller_rut']}',
          style: const TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () {
              handled = true;
              cancelHandsetTimer();
              _rechazarEntrante(payload);
            },
            child: const Text('Rechazar', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF448AFF)),
            onPressed: () => aceptarEntrante(desdeBanana: false),
            child: const Text('Aceptar'),
          ),
        ],
      ),
    ).then((_) {
      cancelHandsetTimer();
      _dialogoEntranteAbierto = false;
    });
  }

  Future<void> _rechazarEntrante(dynamic data) async {
    _detenerTono();
    if (mounted) Navigator.pop(context);

    final Map<dynamic, dynamic> payload = data is Map ? data : <dynamic, dynamic>{};
    final bool esCitofono = isCitofonoAudioCall(payload);

    if (!esCitofono) {
      socket.emit('busy', {'room': payload['caller_rut']});
      return;
    }

    final callId = payload['call_id']?.toString();
    try {
      socket.emit('citofono-end-call', {
        'call_id': callId,
        'reason': 'rechazada',
        'estado': 'rechazada',
      });
      await http.post(
        Uri.parse('$kBaseUrl/api/esp32/end-call'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'call_id': callId,
          'room': payload['caller_rut']?.toString(),
          'rut_emisor': payload['caller_rut']?.toString(),
          'rut_receptor': miRut,
          'tipo_llamada': 'audio',
          'estado': 'rechazada',
          'reason': 'rechazada',
          'duracion_segundos': 0,
        }),
      );
    } catch (_) {}
  }

  Future<void> _llamar(String rut, String tipo) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFF222233),
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF448AFF)),
            SizedBox(width: 20),
            Text('📞 Llamando...', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );

    try {
      final res = await http.post(
        Uri.parse('$kBaseUrl/llamar'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rut': rut,
          'tipo': tipo,
          'caller_rut': miRut,
          'caller_dpto': 'Conserjería',
        }),
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      Navigator.pop(context);

      final data = jsonDecode(res.body);

      if (data['success'] == true || data['warning'] != null) {
        final bool esCitofono = isCitofonoTarget(rut);
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => esCitofono
              ? CitofonoAudioScreen(
                  room: miRut,
                  isCaller: true,
                  socket: socket,
                  miRut: miRut,
                  rutDestino: rut,
                  callId: data['call_id']?.toString(),
                )
              : LlamadaScreen(
                  room: miRut,
                  isCaller: true,
                  tipo: tipo,
                  socket: socket,
                  miRut: miRut,
                  rutDestino: rut,
                ),
        ));
      } else {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: const Color(0xFF222233),
            title: const Text('⚠️ Error', style: TextStyle(color: Colors.orange)),
            content: Text(res.body, style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK', style: TextStyle(color: Color(0xFF448AFF))),
              )
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF222233),
          title: const Text('❌ Sin conexión', style: TextStyle(color: Colors.red)),
          content: Text(e.toString(), style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK', style: TextStyle(color: Color(0xFF448AFF))),
            )
          ],
        ),
      );
    }
  }

  Future<void> _cargarOcupados() async {
    try {
      final res = await http.get(Uri.parse('$kBaseUrl/usuarios-en-llamada'));
      final List lista = jsonDecode(res.body);
      setState(() => rutosOcupados = Set<String>.from(lista));
    } catch (_) {}
  }

  Future<void> _abrirMenu() async {
    final opcion = await showModalBottomSheet<_OpcionMenuConserje>(
      context: context,
      backgroundColor: const Color(0xFF222233),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (menuContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.contacts_rounded,
                  color: Color(0xFF448AFF),
                ),
                title: const Text(
                  'Directorio de contactos',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.pop(
                  menuContext,
                  _OpcionMenuConserje.directorio,
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.chat_bubble_rounded,
                  color: Color(0xFF4CAF50),
                ),
                title: const Text(
                  'Mensajes',
                  style: TextStyle(color: Colors.white),
                ),
                trailing: _mensajesSinLeerTotales > 0
                    ? Badge(
                        label: Text('$_mensajesSinLeerTotales'),
                        backgroundColor: Colors.red,
                      )
                    : null,
                onTap: () => Navigator.pop(
                  menuContext,
                  _OpcionMenuConserje.mensajes,
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.lock_open_rounded,
                  color: Color(0xFF448AFF),
                ),
                title: const Text(
                  'Puertas',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.pop(
                  menuContext,
                  _OpcionMenuConserje.puertas,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!mounted || opcion == null) return;
    switch (opcion) {
      case _OpcionMenuConserje.directorio:
        _abrirDirectorio();
        break;
      case _OpcionMenuConserje.mensajes:
        _abrirMensajes();
        break;
      case _OpcionMenuConserje.puertas:
        _abrirPuertas();
        break;
    }
  }

  void _abrirDirectorio() async {
    await _cargarOcupados();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DirectorioModal(
        miRut: miRut,
        rutosOcupados: rutosOcupados,
        onLlamar: _llamar,
        mensajesSinLeerPorUsuario: _mensajesSinLeerPorUsuario,
      ),
    );
  }

  // --- MODIFICADO: Al abrir los mensajes, limpia los contadores locales y del disco ---
  void _abrirMensajes() {
    setState(() {
      _mensajesSinLeerTotales = 0;
      _mensajesSinLeerPorUsuario.clear();
    });
    
    // Limpiar en SharedPreferences
    _guardarContadoresEnDisco();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MensajesModal(miRut: miRut),
    );
  }

  void _abrirPuertas() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PuertasModal(miRut: miRut, soloApertura: true),
    );
  }

  void _abrirReportes() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ReportesModal(miRut: miRut),
    );
  }

  Future<void> _enviarAvisoEmergencia() async {
    if (_enviandoAvisoEmergencia || _cerrandoSesion ||
        !_socketInicializado || miRut.isEmpty) {
      return;
    }
    final rutEnvio = miRut;
    final socketEnvio = socket;
    setState(() => _enviandoAvisoEmergencia = true);

    String resultado;
    try {
      final response = await http.post(
        Uri.parse('$kBaseUrl/api/esp32/aviso-emergencia'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rut': rutEnvio,
          'mensaje': 'Aviso de emergencia desde Conserjería.',
        }),
      ).timeout(const Duration(seconds: 10));

      if (!mounted || _cerrandoSesion || miRut != rutEnvio ||
          !identical(socket, socketEnvio)) {
        return;
      }

      Map<String, dynamic> data = {};
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map<String, dynamic>) data = decoded;
      } on FormatException {
        // El servidor puede responder con HTML si la ruta aún no existe.
      }

      if (response.statusCode == 200 && data['success'] == true) {
        final emergencia = data['emergencia'];
        if (emergencia is! Map<String, dynamic> ||
            emergencia['active'] is! bool) {
          throw const FormatException('Estado de emergencia no válido.');
        }
        EmergencyService.instance.applyServerState(emergencia);
        final total = data['total'];
        final enviados = data['enviados'];
        final fallidos = data['fallidos'];
        if (emergencia['active'] == false) {
          resultado = 'La emergencia ya no está activa.';
        } else if (total is! int || enviados is! int || fallidos is! int ||
            total < 0 || enviados < 0 || fallidos < 0 ||
            enviados + fallidos != total) {
          resultado = 'Emergencia activada en las aplicaciones. No se pudo '
              'confirmar el envío a los citófonos.';
        } else if (total == 0) {
          resultado = 'Emergencia activada en las aplicaciones. '
              'No hay citófonos conectados.';
        } else if (fallidos > 0) {
          resultado = 'Emergencia activada en las aplicaciones y enviada a '
              '$enviados de $total citófonos. No se pudo enviar a $fallidos.';
        } else {
          resultado = 'Emergencia activada en las aplicaciones y enviada a $enviados '
              '${enviados == 1 ? 'citófono' : 'citófonos'}.';
        }
      } else if (response.statusCode == 404) {
        resultado = 'El servidor aún no tiene habilitado el envío de avisos '
            'de emergencia.';
      } else {
        resultado = data['error']?.toString() ??
            'No se pudo enviar el aviso de emergencia.';
      }
    } on FormatException {
      resultado = 'No se pudo confirmar el estado de la emergencia.';
    } on TimeoutException {
      resultado = 'El servidor no respondió a tiempo. No se pudo confirmar '
          'el envío del aviso de emergencia.';
    } catch (_) {
      resultado = 'No se pudo confirmar el envío del aviso de emergencia. '
          'Revisa la conexión.';
    } finally {
      if (mounted) setState(() => _enviandoAvisoEmergencia = false);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(resultado)));
  }

  void _cerrarSesion() async {
    _cerrandoSesion = true;
    if (_socketInicializado) EmergencyService.instance.detachSocket(socket);
    if (_socketInicializado) socket.disconnect();
    await NotificationHistoryService.clearSession();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationHistoryService.changes.removeListener(_actualizarNotificaciones);
    if (_socketInicializado) EmergencyService.instance.detachSocket(socket);
    if (_socketInicializado) socket.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF448AFF).withOpacity(0.3),
                  blurRadius: 80,
                  spreadRadius: 20,
                ),
              ],
            ),
          ),
          Positioned(
            top: 50,
            left: 20,
            right: 180,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Interfonía Gladiator', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w300, color: Colors.white)),
                if (_versionApp != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _versionApp!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            top: 40,
            right: 15,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: _socketConectado ? Colors.green : Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _socketConectado
                            ? 'Conectado'
                            : _socketReconectando
                                ? 'Reconectando'
                                : 'Desconectado',
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  icon: const Icon(Icons.logout, color: Colors.grey),
                  onPressed: _cerrarSesion,
                ),
              ],
            ),
          ),
          Positioned(
            top: 120,
            bottom: 110,
            left: 20,
            right: 20,
            child: Column(
              children: [
                Text('RUT: $miRut', style: const TextStyle(color: Colors.grey, fontSize: 16)),
                const SizedBox(height: 20),
                Expanded(
                  child: NotificacionesPanel(
                    notificaciones: _notificaciones,
                    loading: _loadingNotificaciones,
                    error: _errorNotificaciones,
                    onDismiss: _descartarNotificacion,
                    onTap: (notificacion) {
                      if (notificacion.type == 'chat_message') _abrirMensajes();
                    },
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 30,
            left: 30,
            child: FloatingActionButton(
              heroTag: 'fab_aviso_emergencia',
              tooltip: _enviandoAvisoEmergencia
                  ? 'Enviando aviso de emergencia...'
                  : 'Aviso de emergencia',
              backgroundColor: const Color(0xFFD32F2F),
              onPressed: _enviandoAvisoEmergencia ? null : _enviarAvisoEmergencia,
              child: const Icon(Icons.notifications_active_rounded, color: Colors.white),
            ),
          ),
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton.extended(
                heroTag: 'fab_reportes',
                backgroundColor: const Color(0x9720CDFF),
                onPressed: _abrirReportes,
                icon: const Icon(Icons.sticky_note_2_rounded, color: Colors.white),
                label: const Text('Reportes', style: TextStyle(color: Colors.white)),
              ),
            ),
          ),
          Positioned(
            bottom: 30,
            right: 30,
            child: Badge(
              isLabelVisible: _mensajesSinLeerTotales > 0,
              label: Text(
                '$_mensajesSinLeerTotales',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              backgroundColor: Colors.red,
              largeSize: 18,
              child: FloatingActionButton(
                heroTag: 'fab_menu',
                tooltip: 'Contactos, mensajes y puertas',
                backgroundColor: const Color(0xFF448AFF),
                onPressed: _abrirMenu,
                child: const Icon(Icons.menu_rounded, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
