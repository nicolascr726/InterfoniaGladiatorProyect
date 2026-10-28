import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config.dart';
import '../screens/citofono_audio_screen.dart';
import 'mensajes_modal.dart';

class DirectorioModal extends StatefulWidget {
  final String miRut;
  final http.Client? client;
  final Set<String> rutosOcupados;
  final Function(String rut, String tipo) onLlamar;
  // --- NUEVO: Recibe el mapa con los mensajes sin leer por remitente ---
  final Map<String, int> mensajesSinLeerPorUsuario;

  const DirectorioModal({
    super.key,
    required this.miRut,
    this.client,
    required this.rutosOcupados,
    required this.onLlamar,
    this.mensajesSinLeerPorUsuario = const {}, // Por defecto vacío por si acaso
  });

  @override
  State<DirectorioModal> createState() => _DirectorioModalState();
}

class _DirectorioModalState extends State<DirectorioModal> {
  static const _intervaloActualizacion = Duration(seconds: 5);
  static const _tiempoLimite = Duration(seconds: 8);

  late final http.Client _client;
  Timer? _timer;
  final _searchCtrl = TextEditingController();
  Map<String, dynamic> _ultimosMensajesPorRut = {};
  List<Map<String, dynamic>> _contactosUsuarios = [];
  List<Map<String, dynamic>> _citofonos = [];
  List<Map<String, dynamic>> _usuarios = [];
  List<Map<String, dynamic>> _filtrados = [];
  Set<String>? _ocupadosServidor;
  String? _citofonoActivo;
  String? _iniciandoLlamada;
  String _nombreSesion = '';
  String? _errorUsuarios;
  String? _errorCitofonos;
  String? _errorLlamada;
  String? _errorMensajes;
  bool _loading = true;
  bool _cargandoUsuarios = false;
  bool _actualizandoCitofonos = false;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? http.Client();
    _cargarUsuarios();
    _timer = Timer.periodic(_intervaloActualizacion, (_) {
      if (!_loading && _iniciandoLlamada == null) _actualizarCitofonos();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchCtrl.dispose();
    // Una petición de llamada pendiente debe poder cancelarse en el servidor.
    if (widget.client == null && _iniciandoLlamada == null) _client.close();
    super.dispose();
  }

  String _normalizarRut(dynamic value) =>
      (value ?? '').toString().replaceAll(RegExp(r'[.\s-]'), '').toUpperCase();

  String _textoBusqueda(dynamic value) => (value ?? '')
      .toString()
      .toLowerCase()
      .replaceAll('á', 'a')
      .replaceAll('é', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .trim();

  Future<dynamic> _consultarJson(String path) async {
    final respuesta =
    await _client.get(Uri.parse('$kBaseUrl$path')).timeout(_tiempoLimite);
    if (respuesta.statusCode != 200) {
      throw StateError('Consulta no disponible');
    }
    return jsonDecode(utf8.decode(respuesta.bodyBytes));
  }

  List<Map<String, dynamic>> _leerUsuarios(dynamic data) {
    if (data is! List) {
      throw const FormatException('Lista de usuarios inválida');
    }
    return data
        .whereType<Map>()
        .map((u) => Map<String, dynamic>.from(u))
        .toList();
  }

  Future<void> _cargarNombreSesion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_normalizarRut(prefs.getString('rut')) !=
          _normalizarRut(widget.miRut)) {
        return;
      }
      _nombreSesion = (prefs.getString('nombre') ?? '').trim();
    } catch (_) {
      // Los nombres del servidor siguen siendo la fuente principal.
    }
  }

  Future<void> _cargarUsuarios() async {
    if (_cargandoUsuarios || _iniciandoLlamada != null) return;
    _cargandoUsuarios = true;
    try {
      await _cargarNombreSesion();
      final data = await _consultarJson(
          '/usuarios-todos?rut=${Uri.encodeQueryComponent(widget.miRut)}');
      final usuarios = _leerUsuarios(data);
      if (!mounted) return;
      setState(() {
        _contactosUsuarios = usuarios;
        _errorUsuarios = null;
      });
    } catch (_) {
      if (mounted) {
        setState(
                () => _errorUsuarios = 'No se pudieron actualizar los contactos.');
      }
    } finally {
      _cargandoUsuarios = false;
      if (mounted) {
        await _actualizarCitofonos();
        if (mounted) {
          setState(() {
            _loading = false;
            _reconstruirContactos();
          });
        }
      }
    }
  }

  Future<Set<String>> _consultarOcupados() async {
    try {
      final data = await _consultarJson('/usuarios-en-llamada');
      if (data is! List) throw const FormatException('Estado inválido');
      return data.map(_normalizarRut).toSet();
    } catch (_) {
      return _ocupadosServidor ??
          widget.rutosOcupados.map(_normalizarRut).toSet();
    }
  }

  Future<void> _actualizarMensajes() async {
    try {
      // Obtener las vistas previas sin consultar ni marcar el historial leído.
      final data = await _consultarJson(
          '/api/chat/contactos?rut=${Uri.encodeQueryComponent(widget.miRut)}');
      if (data is! Map ||
          data['success'] != true ||
          data['contactos'] is! List) {
        throw const FormatException('Lista de mensajes inválida');
      }
      final contactos = _leerUsuarios(data['contactos']);
      final mensajes = <String, dynamic>{
        for (final contacto in contactos)
          if (_normalizarRut(contacto['rut_usuario']).isNotEmpty)
            _normalizarRut(contacto['rut_usuario']): contacto['last_message'],
      };
      if (!mounted) return;
      setState(() {
        _ultimosMensajesPorRut = mensajes;
        _errorMensajes = null;
        _reconstruirContactos();
      });
    } catch (_) {
      if (mounted) {
        setState(() =>
        _errorMensajes = 'No se pudieron actualizar los últimos mensajes.');
      }
    }
  }

  Map<String, dynamic> _crearCitofono(Map<String, dynamic> dispositivo) {
    final deviceId = dispositivo['device_id'].toString();
    final titulo = (dispositivo['display_name'] ?? '').toString().trim();
    return {
      'rut_usuario': (dispositivo['rut_usuario'] ?? '').toString(),
      'nombres': titulo.isEmpty ? 'Citofono $deviceId' : titulo,
      'apellido_1': '',
      'id_dpto': dispositivo['id_dpto'] ?? '',
      'es_citofono': true,
      'device_id': deviceId,
    };
  }

  Future<void> _actualizarCitofonos() async {
    if (_actualizandoCitofonos || !mounted) return;
    _actualizandoCitofonos = true;
    try {
      final resultados = await Future.wait<dynamic>([
        _consultarJson('/api/esp32/audio-status'),
        _consultarOcupados(),
        _actualizarMensajes(),
      ]);
      final estado = resultados[0];
      if (estado is! Map ||
          estado['esp32_tx_devices'] is! List ||
          estado['esp32_rx_devices'] is! List) {
        throw const FormatException(
            'El servidor no entrega los equipos conectados');
      }
      Set<String> leerIds(dynamic values) => (values as List)
          .whereType<String>()
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      // Una tarjeta requiere los dos canales del equipo conectados.
      final conectados = leerIds(estado['esp32_tx_devices'])
          .intersection(leerIds(estado['esp32_rx_devices']));
      final dispositivos = <String, Map<String, dynamic>>{};
      final citofonos = estado['citofonos'];
      if (citofonos is List) {
        for (final dispositivo in citofonos.whereType<Map>()) {
          final id = (dispositivo['device_id'] ?? '').toString().trim();
          if (id.isNotEmpty) {
            dispositivos[id] = Map<String, dynamic>.from(dispositivo);
          }
        }
      }
      if (!mounted) return;
      final ids = conectados.toList()..sort();
      final activo = estado['active_citofono_device_id']?.toString().trim();
      setState(() {
        _citofonos = ids
            .map((id) => _crearCitofono(dispositivos[id] ?? {'device_id': id}))
            .toList();
        _citofonoActivo = activo == null || activo.isEmpty ? null : activo;
        _ocupadosServidor = resultados[1] as Set<String>;
        _errorCitofonos = null;
        _reconstruirContactos();
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          // Sin comprobación válida, no afirmar que el equipo está conectado.
          _citofonos = [];
          _errorCitofonos =
          'No se pudieron comprobar los citofonos conectados.';
          _reconstruirContactos();
        });
      }
    } finally {
      _actualizandoCitofonos = false;
    }
  }

  void _reconstruirContactos() {
    _usuarios = [..._citofonos, ..._contactosUsuarios];
    _filtrados = _buscar(_searchCtrl.text);
  }

  List<Map<String, dynamic>> _buscar(String query) {
    final q = _textoBusqueda(query);
    if (q.isEmpty) return _usuarios;
    return _usuarios.where((u) {
      final dpto = (u['id_dpto'] ?? '').toString();
      return _textoBusqueda([
        u['nombres'] ?? '',
        u['apellido_1'] ?? '',
        u['apellido_2'] ?? '',
        u['rut_usuario'] ?? '',
        u['device_id'] ?? '',
        'depto departamento $dpto',
        u['es_citofono'] == true ? 'citofono porteria acceso' : '',
      ].join(' '))
          .contains(q);
    }).toList();
  }

  void _filtrar(String query) => setState(() => _filtrados = _buscar(query));

  Future<void> _abrirMensajes(Map<String, dynamic> contacto) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MensajesModal(
        miRut: widget.miRut,
        contactoInicial: contacto,
        // El directorio de residentes solo contiene contactos de conserjería.
        soloConserjes:
        contacto['es_admin'] == true || contacto['es_admin'] == 1,
      ),
    );
    if (mounted && _iniciandoLlamada == null) await _actualizarCitofonos();
  }

  bool _estaOcupado(Map<String, dynamic> usuario) {
    final ocupados =
        _ocupadosServidor ?? widget.rutosOcupados.map(_normalizarRut).toSet();
    if (usuario['es_citofono'] == true) {
      return _citofonoActivo != null || ocupados.contains('CITOFONO');
    }
    return ocupados.contains(_normalizarRut(usuario['rut_usuario']));
  }

  Future<void> _cancelarLlamada(String callId, String deviceId) async {
    try {
      await _client
          .post(Uri.parse('$kBaseUrl/api/esp32/end-call'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'call_id': callId,
            'device_id': deviceId,
            'room': widget.miRut,
            'rut_emisor': widget.miRut,
            'rut_receptor': 'CITOFONO',
            'reason': 'canceled',
            'estado': 'cancelada',
          }))
          .timeout(_tiempoLimite);
    } catch (_) {}
  }

  Future<void> _llamarCitofono(Map<String, dynamic> usuario) async {
    if (_iniciandoLlamada != null) return;
    final deviceId = usuario['device_id'].toString();
    final navigator = Navigator.of(context);
    final rutaDirectorio = ModalRoute.of(context);
    String? callId;
    io.Socket? socketLlamada;
    setState(() {
      _iniciandoLlamada = deviceId;
      _errorLlamada = null;
    });
    try {
      final respuesta = await _client
          .post(Uri.parse('$kBaseUrl/llamar'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'rut': 'CITOFONO',
            'tipo': 'audio',
            'caller_rut': widget.miRut,
            'caller_dpto': _nombreSesion.isEmpty ? 'App' : _nombreSesion,
            'device_id': deviceId,
          }))
          .timeout(_tiempoLimite);
      if (respuesta.statusCode == 409) {
        if (mounted) setState(() => _errorLlamada = 'Conserjería ocupada');
        return;
      }
      final data = jsonDecode(utf8.decode(respuesta.bodyBytes));
      if (respuesta.statusCode < 200 ||
          respuesta.statusCode >= 300 ||
          data is! Map ||
          data['success'] != true ||
          (data['call_id'] ?? '').toString().isEmpty) {
        throw StateError('No se pudo iniciar la llamada');
      }
      callId = data['call_id'].toString();
      if (!mounted || !navigator.mounted || rutaDirectorio?.isCurrent != true) {
        return;
      }
      // Socket propio: conservar intacto el de la pantalla principal.
      socketLlamada = io.io(kBaseUrl, {
        'transports': ['websocket'],
        'autoConnect': false,
        'forceNew': true,
        'multiplex': false,
      });
      socketLlamada.onConnect((_) {
        socketLlamada?.emit('register', {'room': widget.miRut});
      });
      socketLlamada.connect();
      navigator.pop();
      await navigator.push(MaterialPageRoute<void>(
        builder: (_) => CitofonoAudioScreen(
          miRut: widget.miRut,
          rutDestino: 'CITOFONO',
          room: widget.miRut,
          isCaller: true,
          socket: socketLlamada,
          callId: callId,
        ),
      ));
    } catch (_) {
      if (mounted) {
        setState(
                () => _errorLlamada = 'No se pudo iniciar la llamada al citofono.');
      }
    } finally {
      // También liberar el canal al salir de audio con el botón Atrás.
      // El call_id evita finalizar una llamada posterior de otro equipo.
      if (callId != null) {
        await _cancelarLlamada(callId, deviceId);
      }
      socketLlamada?.dispose();
      if (mounted) {
        setState(() => _iniciandoLlamada = null);
      } else if (widget.client == null) {
        _client.close();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0F172A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[700],
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Directorio de Contactos',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Actualizar directorio',
                    onPressed: _loading ||
                        _cargandoUsuarios ||
                        _actualizandoCitofonos ||
                        _iniciandoLlamada != null
                        ? null
                        : _cargarUsuarios,
                    icon: const Icon(Icons.refresh, color: Colors.grey),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: _filtrar,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Buscar por nombre, RUT o Depto...',
                  hintStyle: const TextStyle(color: Colors.grey),
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF222233),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF444444)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF444444)),
                  ),
                ),
              ),
            ),
            if (_errorUsuarios != null ||
                _errorCitofonos != null ||
                _errorLlamada != null ||
                _errorMensajes != null)
              Padding(
                padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  [
                    _errorUsuarios,
                    _errorCitofonos,
                    _errorLlamada,
                    _errorMensajes
                  ].whereType<String>().join('\n'),
                  style: const TextStyle(color: Colors.orange),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(
                  child:
                  CircularProgressIndicator(color: Color(0xFF448AFF)))
                  : _filtrados.isEmpty
                  ? const Center(
                  child: Text(
                    'No hay contactos para mostrar.',
                    style: TextStyle(color: Colors.grey),
                  ))
                  : ListView.builder(
                controller: scrollCtrl,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _filtrados.length,
                itemBuilder: (_, i) {
                  final u = _filtrados[i];
                  final rut = (u['rut_usuario'] ?? '').toString();
                  final ocupado =
                      _estaOcupado(u) || _iniciandoLlamada != null;

                  // --- NUEVO: Obtener la cantidad de mensajes sin leer de este usuario específico ---
                  final unreadCount =
                      widget.mensajesSinLeerPorUsuario[rut] ?? 0;

                  return _UserCard(
                    usuario: u,
                    ocupado: ocupado,
                    unreadCount: unreadCount,
                    ultimoMensaje:
                    _ultimosMensajesPorRut[_normalizarRut(rut)],
                    enviando: _iniciandoLlamada != null &&
                        _iniciandoLlamada == u['device_id'],
                    onMensajes: () => _abrirMensajes(u),
                    onLlamar: (tipo) async {
                      if (u['es_citofono'] == true) {
                        await _llamarCitofono(u);
                        return;
                      }
                      Navigator.pop(context);
                      await Future.delayed(
                          const Duration(milliseconds: 300));
                      widget.onLlamar(rut, tipo);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  final Map usuario;
  final bool ocupado;
  final int unreadCount;
  final dynamic ultimoMensaje;
  final bool enviando;
  final VoidCallback onMensajes;
  final Function(String tipo) onLlamar;

  const _UserCard({
    required this.usuario,
    required this.ocupado,
    required this.unreadCount,
    this.ultimoMensaje,
    this.enviando = false,
    required this.onMensajes,
    required this.onLlamar,
  });

  String _vistaPreviaMensaje() {
    final mensaje = ultimoMensaje;
    if (mensaje is! Map) return 'Sin mensajes recibidos';
    if (mensaje['es_imagen'] == true || mensaje['es_imagen'] == 1) {
      return '📷 Imagen';
    }
    final texto = (mensaje['mensaje'] ?? '').toString().trim();
    if (texto.isEmpty) return 'Sin mensajes recibidos';
    return '${mensaje['is_mine'] == true ? 'Tú: ' : ''}$texto';
  }

  @override
  Widget build(BuildContext context) {
    final bool esCitofono =
        usuario['es_citofono'] == true || usuario['rut_usuario'] == 'CITOFONO';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF222233),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF333344)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Usamos Flexible para que nombres muy largos no rompan el diseño con los badges
              Flexible(
                child: Text(
                  '${usuario['nombres'] ?? ''} ${usuario['apellido_1'] ?? ''}'
                      .trim(),
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              // --- NUEVO: Badge indicador de mensajes no leídos enviados por este usuario ---
              if (unreadCount > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(
                        0xFFFF9800), // Color naranjo/advertencia llamativo
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.mail_rounded,
                          color: Colors.white, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        '$unreadCount',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ],

              if (ocupado) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFff5252),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('🔴 Ocupado',
                      style: TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            esCitofono
                ? 'Conectado · ${usuario['device_id']} | RUT: ${usuario['rut_usuario'].toString().isEmpty ? 'Sin asociación' : usuario['rut_usuario']}'
                : 'Depto/Casa: ${usuario['id_dpto'] ?? 'N/A'} | RUT: ${usuario['rut_usuario']}',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          if (!esCitofono) ...[
            const SizedBox(height: 6),
            Text(
              _vistaPreviaMensaje(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: unreadCount > 0 ? Colors.white70 : Colors.white54,
                fontWeight:
                unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              if (!esCitofono) ...[
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onMensajes,
                    icon: const Icon(Icons.chat_bubble_rounded, size: 18),
                    label: const Text('Mensajes'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF448AFF),
                      foregroundColor: Colors.white,
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: ocupado ? null : () => onLlamar('audio'),
                  icon: Icon(
                      esCitofono ? Icons.doorbell_rounded : Icons.call_rounded,
                      size: 18),
                  label: Text(enviando
                      ? 'Llamando...'
                      : esCitofono
                      ? 'Llamar al citófono'
                      : 'Llamar'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                    ocupado ? Colors.grey[800] : const Color(0xFF4CAF50),
                    foregroundColor: Colors.white,
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
