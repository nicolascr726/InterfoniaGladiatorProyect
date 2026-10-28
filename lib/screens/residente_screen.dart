import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import '../config.dart';
import 'llamada_screen.dart';
import 'citofono_audio_screen.dart';
import '../helpers/citofono_call_utils.dart';
import '../helpers/call_notifications.dart';
import 'login_screen.dart';
import '../widgets/directorio_modal.dart';
import '../widgets/mensajes_modal.dart';
import '../widgets/recados_modal.dart';
import '../widgets/puertas_modal.dart';
import '../helpers/message_navigation.dart';
import '../services/esp32_audio_bridge.dart';
import '../services/notification_history_service.dart';
import '../services/emergency_service.dart';
import 'package:url_launcher/url_launcher.dart';

class ResidenteScreen extends StatefulWidget {
  const ResidenteScreen({super.key});

  @override
  State<ResidenteScreen> createState() => _ResidenteScreenState();
}

class _ResidenteScreenState extends State<ResidenteScreen> {
  String miRut = '';
  String miNombre = '';
  String miDpto = '';
  late IO.Socket socket;
  Set<String> rutosOcupados = {};
  bool _socketConectado = false;
  bool _socketReconectando = false;
  bool _cerrandoSesion = false;
  final _ringtonePlayer = FlutterRingtonePlayer();
  bool _dialogoEntranteAbierto = false;

  void _tocarTono() => _ringtonePlayer.playRingtone();
  void _detenerTono() => _ringtonePlayer.stop();

  // Función para registrar y actualizar el Token FCM

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
    _cargarSesion();
  }

  Future<void> _cargarSesion() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      miRut = prefs.getString('rut') ?? '';
      miNombre = prefs.getString('nombre') ?? '';
      miDpto = prefs.getString('dpto') ?? '';
    });
    
    // NUEVO: Ejecutar el registro del token si el RUT existe
    if (miRut.isNotEmpty) {
      _registrarTokenFCM(miRut);
    }

    _conectarSocket();
    _abrirMensajesSiPendiente();
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
    EmergencyService.instance.attachSocket(
      socket,
      rut: miRut,
      isConserje: false,
    );

    socket.onConnect((_) {
      if (!mounted || _cerrandoSesion) return;
      setState(() {
        _socketConectado = true;
        _socketReconectando = false;
      });
      socket.emit('register', {'room': miRut});
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
      debugPrint('Reconectando Socket: $e');
    });

    socket.connect(); // Conectar explícitamente

    // Llamada entrante al residente
    socket.on('incoming-call', (data) {
      if (!mounted) return;
      if (data is Map && data['caller_rut'] == miRut) return;
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔴 Línea ocupada. El conserje está en otra llamada.'),
          backgroundColor: Color(0xFFff5252),
        ),
      );
    });

    socket.on('chat-message', (data) {
      if (!mounted || data is! Map) return;
      final receptor = (data['rut_receptor'] ?? '').toString();
      final emisor = (data['rut_emisor'] ?? '').toString();
      if (receptor == miRut && emisor != miRut) {
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
      final String targetDpto = (rut == '99999999' || rut.toUpperCase() == 'CONSERJERÍA' || rut == '000') ? '000' : rut;
      final res = await http.post(
        Uri.parse('$kBaseUrl/llamar'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rut': rut,
          'id_dpto': targetDpto,
          'tipo': tipo,
          'caller_rut': miRut,
          'caller_dpto': miDpto.isNotEmpty ? miDpto : 'Depto',
        }),
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      Navigator.pop(context); // Cerrar loading

      final data = jsonDecode(res.body);
      debugPrint('📡 /llamar: ${res.statusCode} - ${res.body}');

      if (data['success'] == true || data['warning'] != null) {
        final bool esCitofono = isCitofonoTarget(rut);
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => esCitofono
              ? CitofonoAudioScreen(
                  room: miRut,
                  isCaller: true,
                  socket: socket,
                  miRut: miRut,
                  rutDestino: rut, // A quien estoy llamando
                  callId: data['call_id']?.toString(),
                )
              : LlamadaScreen(
                  room: miRut,
                  isCaller: true,
                  tipo: tipo,
                  socket: socket,
                  miRut: miRut,
                  rutDestino: rut, // A quien estoy llamando
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
      debugPrint('❌ Error _llamar residente: $e');
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

  void _abrirConfigWifiEsp32() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF222233),
        title: const Row(
          children: [
            Icon(Icons.wifi_find_rounded, color: Color(0xFF448AFF)),
            SizedBox(width: 10),
            Text('Configurar Wi-Fi Citófono', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '1. Mantén presionado el botón de tu citófono por 5 segundos hasta que parpadee.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            SizedBox(height: 8),
            Text(
              '2. Conecta tu celular a la red Wi-Fi "Citofono-Config".',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            SizedBox(height: 8),
            Text(
              '3. Presiona "Abrir Portal" para guardar tu nueva clave de internet.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF448AFF)),
            onPressed: () async {
              Navigator.pop(context);
              final uri = Uri.parse('http://192.168.4.1');
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } else {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Abre tu navegador e ingresa a http://192.168.4.1')),
                  );
                }
              }
            },
            icon: const Icon(Icons.open_in_browser_rounded, color: Colors.white),
            label: const Text('Abrir Portal (192.168.4.1)', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
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
      ),
    );
  }

  void _abrirPuertas() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PuertasModal(miRut: miRut),
    );
  }

  void _abrirRecados() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RecadosModal(miRut: miRut),
    );
  }

  void _abrirMensajes() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MensajesModal(
        miRut: miRut,
        soloConserjes: true,
      ),
    );
  }

  void _cerrarSesion() async {
    _cerrandoSesion = true;
    EmergencyService.instance.detachSocket(socket);
    socket.disconnect();
    await NotificationHistoryService.clearSession();
    if (!mounted) return;
    Navigator.pushReplacement(context,
        MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  void dispose() {
    EmergencyService.instance.detachSocket(socket);
    socket.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      body: Stack(
        children: [
          // Background ambient glows
          Positioned(
            top: -80,
            left: -40,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF6366F1).withOpacity(0.18),
                    blurRadius: 120,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 40,
            right: -60,
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF06B6D4).withOpacity(0.15),
                    blurRadius: 120,
                  ),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                // TOP HEADER BAR
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.apartment_rounded, color: Color(0xFF6366F1), size: 28),
                          SizedBox(width: 10),
                          Text(
                            'Gladiator Interfonia',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFF151C2C),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.white.withOpacity(0.08)),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: _socketConectado ? const Color(0xFF10B981) : const Color(0xFFFF5252),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _socketConectado
                                      ? 'En línea'
                                      : _socketReconectando
                                          ? 'Reconectando'
                                          : 'Desconectado',
                                  style: TextStyle(
                                    color: _socketConectado ? const Color(0xFF10B981) : Colors.white54,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.logout_rounded, color: Colors.white54),
                            onPressed: _cerrarSesion,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // PROFILE HERO CARD
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF1A2338), Color(0xFF151C2C)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white.withOpacity(0.08)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 28,
                                backgroundColor: const Color(0xFF6366F1).withOpacity(0.2),
                                child: const Icon(Icons.home_work_rounded, color: Color(0xFF6366F1), size: 30),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      miNombre.isNotEmpty ? miNombre : 'Residente',
                                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                                    ),
                                    const SizedBox(height: 4),
                                    Text('RUT: $miRut', style: const TextStyle(fontSize: 12, color: Colors.white54)),
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF6366F1).withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        miDpto.isNotEmpty ? 'Departamento $miDpto' : 'Residencia Activa',
                                        style: const TextStyle(color: Color(0xFF818CF8), fontSize: 12, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Acciones Rápida',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.5),
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _abrirRecados,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF151C2C),
                              foregroundColor: const Color(0xFF20CDFF),
                              padding: const EdgeInsets.all(18),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                            icon: const Icon(Icons.sticky_note_2_rounded),
                            label: const Text('Recados'),
                          ),
                        ),
                        const SizedBox(height: 14),
                        // FEATURE CARDS GRID
                        GridView.count(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisCount: 2,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                          childAspectRatio: 1.2,
                          children: [
                            // CARD 1: PUERTAS
                            InkWell(
                              onTap: _abrirPuertas,
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF6366F1).withOpacity(0.35),
                                      blurRadius: 14,
                                      offset: const Offset(0, 6),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.2),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.door_front_door_rounded, color: Colors.white, size: 24),
                                    ),
                                    const Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('Puertas', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                                        SizedBox(height: 2),
                                        Text('Acceso a puertas', style: TextStyle(fontSize: 11, color: Colors.white70)),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // CARD 2: LLAMAR CONSERJERÍA
                            InkWell(
                              onTap: () => _llamar('11111111', 'audio'),
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF151C2C),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: const Color(0xFF10B981).withOpacity(0.4)),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF10B981).withOpacity(0.2),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.support_agent_rounded, color: Color(0xFF10B981), size: 24),
                                    ),
                                    const Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('Conserjería', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                                        SizedBox(height: 2),
                                        Text('Llamada Directa', style: TextStyle(fontSize: 11, color: Colors.white54)),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // CARD 3: CHAT MENSAJES
                            InkWell(
                              onTap: _abrirMensajes,
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF151C2C),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF8B5CF6).withOpacity(0.2),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.chat_bubble_rounded, color: Color(0xFF8B5CF6), size: 24),
                                    ),
                                    const Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('Mensajes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                                        SizedBox(height: 2),
                                        Text('Chat Residencial', style: TextStyle(fontSize: 11, color: Colors.white54)),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // CARD 4: WI-FI ESP32
                            InkWell(
                              onTap: _abrirConfigWifiEsp32,
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF151C2C),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF0EA5E9).withOpacity(0.2),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.wifi_rounded, color: Color(0xFF0EA5E9), size: 24),
                                    ),
                                    const Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('Config Wi-Fi', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                                        SizedBox(height: 2),
                                        Text('Soporte Citófono', style: TextStyle(fontSize: 11, color: Colors.white54)),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        // QUICK NAV FOOTER BAR
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: Colors.white.withOpacity(0.12)),
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                ),
                                onPressed: _abrirDirectorio,
                                icon: const Icon(Icons.contacts_rounded, color: Colors.white70),
                                label: const Text('Directorio', style: TextStyle(color: Colors.white70)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
