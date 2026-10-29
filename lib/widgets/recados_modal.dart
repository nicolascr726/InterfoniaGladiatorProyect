import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config.dart';
import '../screens/citofono_audio_screen.dart';
import '../screens/llamada_screen.dart';
import '../services/recados_excel_service.dart';
import '../helpers/filtro_fecha_hora.dart';

class RecadosModal extends StatefulWidget {
  final String miRut;
  final http.Client? client;
  final bool mostrarComoMensajes;
  const RecadosModal({
    super.key,
    required this.miRut,
    this.client,
    this.mostrarComoMensajes = false,
  });

  @override
  State<RecadosModal> createState() => _RecadosModalState();
}

class _RecadosModalState extends State<RecadosModal> {
  late final http.Client _client;
  Timer? _timer;
  List<Map<String, dynamic>> _recados = [];
  bool _cargando = true;
  bool _consultando = false;
  bool _ocupado = false;
  bool _exportando = false;
  bool? _esAdmin;
  String? _error;
  io.Socket? _socketLlamada;
  _IntentoRecado? _intentoLlamada;
  final _busquedaPendientes = TextEditingController();
  final _busquedaResueltos = TextEditingController();
  FiltroFechaHora _filtroPendientes = const FiltroFechaHora();
  FiltroFechaHora _filtroResueltos = const FiltroFechaHora();

  String get _nombrePlural =>
      widget.mostrarComoMensajes ? 'mensajes' : 'recados';
  String get _nombreSingular =>
      widget.mostrarComoMensajes ? 'mensaje' : 'recado';
  String get _tituloModal =>
      widget.mostrarComoMensajes ? 'Mensajes' : 'Recados';

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? http.Client();
    _cargar();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_ocupado) _cargar(silencioso: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _busquedaPendientes.dispose();
    _busquedaResueltos.dispose();
    final intento = _intentoLlamada;
    if (intento != null) unawaited(intento.cancelar());
    _socketLlamada?.dispose();
    // Permitir que /resolver termine para cancelar también si el modal se cierra
    // antes de que el servidor devuelva el identificador de la llamada.
    if (widget.client == null && _socketLlamada == null) _client.close();
    super.dispose();
  }

  String _normalizarRut(String rut) => rut
      .replaceAll('.', '')
      .replaceAll('-', '')
      .trim()
      .toUpperCase()
      .replaceAll('Ó', 'O');

  Future<dynamic> _peticion(String metodo, String ruta,
      [Map<String, String>? datos]) async {
    final rut = widget.miRut.trim();
    if (rut.isEmpty) {
      throw Exception('No se encontró el RUT del usuario.');
    }
    final uri = Uri.parse('$kBaseUrl$ruta');
    const headers = {'Content-Type': 'application/json'};
    const timeout = Duration(seconds: 15);
    final bodyJson = jsonEncode({...?datos, 'rut': rut});
    final http.Response response;
    switch (metodo) {
      case 'GET':
        response = await _client
            .get(
              uri.replace(queryParameters: {'rut': rut}),
            )
            .timeout(timeout);
        break;
      case 'POST':
        response = await _client
            .post(uri, headers: headers, body: bodyJson)
            .timeout(timeout);
        break;
      case 'DELETE':
        response = await _client
            .delete(uri, headers: headers, body: bodyJson)
            .timeout(timeout);
        break;
      case 'PUT':
        response = await _client
            .put(uri, headers: headers, body: bodyJson)
            .timeout(timeout);
        break;
      default:
        throw Exception('Operación de $_nombrePlural no válida.');
    }
    final dynamic body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw Exception(
          'El servidor no devolvió una respuesta válida de $_tituloModal.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body is Map
          ? body['error'] ?? 'No se pudo completar la operación.'
          : 'No se pudo completar la operación.');
    }
    if (metodo == 'GET') {
      if (body is! List || body.any((r) => r is! Map)) {
        throw Exception(
            'El servidor no devolvió una respuesta válida de $_tituloModal.');
      }
    } else if (body is! Map || body['success'] != true) {
      throw Exception(body is Map
          ? body['error'] ?? 'No se pudo completar la operación.'
          : 'El servidor no devolvió una respuesta válida de $_tituloModal.');
    }
    return body;
  }

  String _mensajeError(Object error) {
    if (error is TimeoutException) {
      return 'El servidor tardó demasiado. Reintenta.';
    }
    if (error is http.ClientException) {
      return 'No se pudo conectar al servidor.';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  Future<void> _cargar({bool silencioso = false}) async {
    if (_consultando || !mounted) return;
    setState(() {
      _consultando = true;
      if (!silencioso) _cargando = true;
    });
    try {
      final data = await _peticion('GET', '/recados');
      final recados = (data as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      // GET /recados no incluye el rol; /login lo guarda en la sesión.
      final prefs = await SharedPreferences.getInstance();
      final rol = prefs.getInt('es_admin');
      if (_normalizarRut(prefs.getString('rut') ?? '') !=
              _normalizarRut(widget.miRut) ||
          (rol != 0 && rol != 1)) {
        throw Exception(
            'No se pudo identificar la sesión. Vuelve a iniciar sesión.');
      }
      if (!mounted) return;
      setState(() {
        _recados = recados;
        _esAdmin = rol == 1;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) {
        setState(() {
          _cargando = false;
          _consultando = false;
        });
      }
    }
  }

  Future<void> _crear() async {
    setState(() => _ocupado = true);
    try {
      final creado = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _NuevoRecadoDialog(onGuardar: (titulo, descripcion) async {
          await _peticion('POST', '/recados',
              {'titulo': titulo, 'descripcion': descripcion, 'origen': 'app'});
        }),
      );
      if (creado == true && mounted) await _cargar(silencioso: true);
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _accion(Map<String, dynamic> recado,
      {required bool eliminar}) async {
    if (_ocupado || _consultando) return;
    setState(() => _ocupado = true);
    try {
      if (eliminar) {
        final confirmar = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                  title: Text('Cancelar $_nombreSingular'),
                  content: Text(
                      '¿Cancelar "${recado['titulo']}"? Esta acción no se puede deshacer.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Volver')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Confirmar cancelación')),
                  ],
                ));
        if (confirmar != true || !mounted) return;
      }
      if (eliminar) {
        await _peticion('DELETE', '/recados/${recado['id']}');
      } else {
        await _llamarParaResolver(recado);
      }
      if (mounted) await _cargar(silencioso: true);
    } catch (e) {
      if (mounted) setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _llamarParaResolver(Map<String, dynamic> recado) async {
    final navigator = Navigator.of(context);
    final rutaRecados = ModalRoute.of(context);
    final conectado = Completer<void>();
    final finalizadas = <String>{};
    final socketLlamada = io.io(kBaseUrl, {
      'transports': ['websocket'],
      'autoConnect': false,
      'forceNew': true,
      'multiplex': false,
    });
    _socketLlamada = socketLlamada;
    _IntentoRecado? intento;
    String? socketId;
    socketLlamada.onConnect((_) {
      socketLlamada.emit('register', {'room': widget.miRut, 'recados': true});
    });
    socketLlamada.on('recado-socket-ready', (data) {
      if (data is! Map || data['socket_id'] is! String) return;
      final id = (data['socket_id'] as String).trim();
      if (id.isEmpty) return;
      socketId = id;
      if (!conectado.isCompleted) conectado.complete();
    });
    socketLlamada.onDisconnect((_) {
      socketId = null;
      if (!conectado.isCompleted) {
        conectado.completeError(
            Exception('Se perdió la conexión del canal de llamadas.'));
      }
    });
    socketLlamada.onConnectError((_) {
      if (!conectado.isCompleted) {
        conectado.completeError(
            Exception('No se pudo conectar el canal de llamadas.'));
      }
    });
    socketLlamada.on('end-call', (data) {
      if (data is Map && data['call_id'] != null) {
        finalizadas.add(data['call_id'].toString());
      }
    });

    try {
      socketLlamada.connect();
      await conectado.future.timeout(const Duration(seconds: 10));
      if (!mounted || !navigator.mounted || rutaRecados?.isCurrent == false) {
        return;
      }
      final socketIdIntento = socketId;
      if (!socketLlamada.connected || socketIdIntento == null) {
        throw Exception('Se perdió la conexión del canal de llamadas.');
      }
      final data = await _peticion('PUT', '/recados/${recado['id']}/resolver',
          {'socket_id': socketIdIntento});
      final callId = (data['call_id'] ?? '').toString();
      if (callId.isEmpty) {
        throw Exception('El servidor no identificó la llamada del recado.');
      }
      intento = _IntentoRecado(
        recadoId: recado['id'].toString(),
        callId: callId,
        rut: widget.miRut,
      );
      _intentoLlamada = intento;
      final room = (data['room'] ?? '').toString();
      final origen = (data['origen'] ?? '').toString();
      final destino = (data['target_rut'] ?? '').toString();
      final deviceId = (data['device_id'] ?? '').toString();
      if (room.isEmpty ||
          destino.isEmpty ||
          (origen != 'app' && origen != 'citofono') ||
          (origen == 'citofono' &&
              (destino != 'CITOFONO' || deviceId.isEmpty))) {
        throw Exception('El servidor no devolvió el destino de la llamada.');
      }
      if (!mounted || !navigator.mounted || rutaRecados?.isCurrent == false) {
        return;
      }
      if (!socketLlamada.connected ||
          socketId != socketIdIntento ||
          data['state'] == 'ended' ||
          finalizadas.contains(callId)) {
        throw Exception('La llamada terminó antes de abrirse. Reintenta.');
      }
      await navigator.push<void>(MaterialPageRoute(
        builder: (_) => origen == 'citofono'
            ? CitofonoAudioScreen(
                room: room,
                isCaller: true,
                socket: socketLlamada,
                miRut: widget.miRut,
                rutDestino: destino,
                callId: callId,
              )
            : LlamadaScreen(
                room: room,
                isCaller: true,
                tipo: 'audio',
                socket: socketLlamada,
                miRut: widget.miRut,
                rutDestino: destino,
              ),
      ));
    } finally {
      // Cerrar el intento no resuelve el recado: el servidor solo lo hace
      // cuando confirma que contestó el destinatario de esta llamada.
      if (intento != null) await intento.cancelar();
      if (identical(_intentoLlamada, intento)) _intentoLlamada = null;
      socketLlamada.dispose();
      if (identical(_socketLlamada, socketLlamada)) _socketLlamada = null;
      if (!mounted && widget.client == null) _client.close();
    }
  }

  DateTime? _fechaLocal(dynamic valor) => RecadosExcelService.fechaLocal(valor);

  String _dia(DateTime? fecha) {
    if (fecha == null) return 'Fecha no registrada';
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${dos(fecha.day)}/${dos(fecha.month)}/${fecha.year}';
  }

  String _fecha(dynamic valor) {
    final fecha = _fechaLocal(valor);
    if (fecha == null) return 'No registrada';
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${dos(fecha.day)}/${dos(fecha.month)}/${fecha.year} ${dos(fecha.hour)}:${dos(fecha.minute)}';
  }

  String _normalizarBusqueda(String valor) => valor
      .toLowerCase()
      .trim()
      .replaceFirst(RegExp(r'^(departamento|depto|dpto|rut)[.:]?\s*'), '')
      .replaceAll(RegExp(r'[\s\-\.#°º]'), '');

  List<Map<String, dynamic>> _recadosVisibles({required bool resueltos}) {
    final estado = resueltos ? 'resuelto' : 'pendiente';
    final filtro = resueltos ? _filtroResueltos : _filtroPendientes;
    final consulta = _esAdmin == true
        ? _normalizarBusqueda(
            (resueltos ? _busquedaResueltos : _busquedaPendientes).text)
        : '';
    DateTime? fechaGrupo(Map<String, dynamic> r) =>
        (resueltos ? _fechaLocal(r['fecha_resolucion']) : null) ??
        _fechaLocal(r['fecha_creacion']);
    return _recados
        .where((r) =>
            r['estado'] == estado &&
            filtro.incluye(fechaGrupo(r)) &&
            (_normalizarBusqueda(r['id_dpto']?.toString() ?? '')
                    .contains(consulta) ||
                _normalizarBusqueda(r['rut_emisor']?.toString() ?? '')
                    .contains(consulta)))
        .toList()
      ..sort((a, b) {
        final fechaA = fechaGrupo(a);
        final fechaB = fechaGrupo(b);
        if (fechaA == null) return fechaB == null ? 0 : 1;
        if (fechaB == null) return -1;
        return fechaB.compareTo(fechaA);
      });
  }

  Future<void> _exportarExcel({required bool resueltos}) async {
    if (_ocupado || _consultando || _esAdmin != true || _error != null) return;
    final recados = _recadosVisibles(resueltos: resueltos);
    if (recados.isEmpty) return;
    setState(() {
      _ocupado = true;
      _exportando = true;
    });
    try {
      final guardado = await RecadosExcelService.exportar(
        recados,
        resueltos: resueltos,
        mostrarComoMensajes: widget.mostrarComoMensajes,
      );
      if (guardado && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Excel guardado con ${recados.length} $_nombrePlural.'),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No se pudo guardar el Excel. Inténtalo nuevamente.'),
        ));
      }
    } finally {
      if (mounted) {
        setState(() {
          _ocupado = false;
          _exportando = false;
        });
      }
    }
  }

  Widget _buildRecados({required bool resueltos}) {
    final controller = resueltos ? _busquedaResueltos : _busquedaPendientes;
    final cantidad = _recadosVisibles(resueltos: resueltos).length;
    final filtroActual = resueltos ? _filtroResueltos : _filtroPendientes;
    Widget botonFiltro({bool mostrarResumen = true}) => FiltroFechaHoraButton(
          key: ValueKey('filtro_${resueltos ? 'resueltos' : 'pendientes'}'),
          filtro: filtroActual,
          enabled: !_ocupado,
          mostrarResumen: mostrarResumen,
          onChanged: (filtro) {
            if (!mounted) return;
            setState(() {
              if (resueltos) {
                _filtroResueltos = filtro;
              } else {
                _filtroPendientes = filtro;
              }
            });
          },
        );
    return Column(children: [
      if (_esAdmin == true)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: ValueKey(
                          'buscar_${resueltos ? 'resueltos' : 'pendientes'}'),
                      controller: controller,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Buscar por departamento o RUT',
                        hintText: 'Ej.: 101 o 12.345.678-9',
                        labelStyle: const TextStyle(color: Colors.white70),
                        hintStyle: const TextStyle(color: Colors.white54),
                        prefixIcon:
                            const Icon(Icons.search, color: Colors.white54),
                        suffixIcon: controller.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Limpiar búsqueda',
                                icon: const Icon(Icons.close,
                                    color: Colors.white54),
                                onPressed: () => setState(controller.clear)),
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 108,
                    child: botonFiltro(mostrarResumen: false),
                  ),
                ],
              ),
              if (filtroActual.activo)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    filtroActual.resumen,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
            ],
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: botonFiltro(),
        ),
      if (_esAdmin == true)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: ValueKey(
                  'exportar_${resueltos ? 'resueltos' : 'pendientes'}'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF20CDFF),
                disabledForegroundColor: Colors.white38,
              ),
              onPressed: _cargando ||
                      _consultando ||
                      _ocupado ||
                      _esAdmin == null ||
                      _error != null ||
                      cantidad == 0
                  ? null
                  : () => _exportarExcel(resueltos: resueltos),
              icon: _exportando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_outlined),
              label: Text(_exportando
                  ? 'Guardando Excel…'
                  : 'Exportar a Excel ($cantidad)'),
            ),
          ),
        ),
      Expanded(child: _buildListaRecados(resueltos: resueltos)),
    ]);
  }

  Widget _buildListaRecados({required bool resueltos}) {
    final estado = resueltos ? 'resuelto' : 'pendiente';
    final filtro = resueltos ? _filtroResueltos : _filtroPendientes;
    final consulta = _esAdmin == true
        ? _normalizarBusqueda(
            (resueltos ? _busquedaResueltos : _busquedaPendientes).text)
        : '';
    DateTime? fechaGrupo(Map<String, dynamic> r) =>
        (resueltos ? _fechaLocal(r['fecha_resolucion']) : null) ??
        _fechaLocal(r['fecha_creacion']);
    final recados = _recadosVisibles(resueltos: resueltos);
    final color = resueltos ? const Color(0xFF4CAF50) : const Color(0xFFFFB74D);
    if (recados.isEmpty) {
      return Center(
          child: Text(
              _error != null
                  ? 'No se pudieron consultar los $_nombrePlural.'
                  : filtro.activo
                      ? 'No hay $_nombrePlural ${resueltos ? 'resueltos' : 'pendientes'} que coincidan con los filtros.'
                      : consulta.isNotEmpty
                          ? 'No hay $_nombrePlural ${resueltos ? 'resueltos' : 'pendientes'} para ese departamento o RUT.'
                          : 'No hay $_nombrePlural ${resueltos ? 'resueltos' : 'pendientes'}.',
              style: const TextStyle(color: Colors.white54)));
    }
    return ListView.separated(
      key: PageStorageKey('recados_$estado'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: recados.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        final r = recados[i];
        final rutEmisor = r['rut_emisor']?.toString().trim() ?? '';
        final rutVisible = rutEmisor.isEmpty ? 'No registrado' : rutEmisor;
        final origen = r['origen']?.toString();
        final origenVisible = switch (origen) {
          'app' => 'Aplicación',
          'citofono' =>
            'Citófono (${r['device_id'] ?? 'equipo no registrado'})',
          _ => 'No registrado',
        };
        final propio = _normalizarRut(r['rut_emisor']?.toString() ?? '') ==
            _normalizarRut(widget.miRut);
        final dia = _dia(fechaGrupo(r));
        final mostrarDia = i == 0 || _dia(fechaGrupo(recados[i - 1])) != dia;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (mostrarDia)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 12),
                child: Row(children: [
                  const Expanded(child: Divider(color: Colors.white24)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(dia,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600)),
                  ),
                  const Expanded(child: Divider(color: Colors.white24)),
                ]),
              ),
            Container(
              decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12)),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                key: PageStorageKey('recado_${r['id']}_$estado'),
                tilePadding: const EdgeInsets.all(16),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                shape: const Border(),
                collapsedShape: const Border(),
                iconColor: color,
                collapsedIconColor: Colors.white54,
                leading: Icon(
                    resueltos ? Icons.check_circle_outline : Icons.schedule,
                    color: color),
                title: Text(r['titulo'].toString(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                subtitle: Text(
                    'Departamento ${r['id_dpto']}\nRUT del emisor: $rutVisible',
                    style: const TextStyle(color: Colors.white70)),
                children: [
                  Text(r['descripcion'].toString(),
                      style:
                          const TextStyle(color: Colors.white70, height: 1.4)),
                  const SizedBox(height: 14),
                  Text('Estado: ${resueltos ? 'Resuelto' : 'Pendiente'}',
                      style: TextStyle(color: color)),
                  const SizedBox(height: 6),
                  Text('Origen: $origenVisible',
                      style: const TextStyle(color: Colors.white54)),
                  const SizedBox(height: 6),
                  Text('Fecha de creación: ${_fecha(r['fecha_creacion'])}',
                      style: const TextStyle(color: Colors.white54)),
                  if (resueltos)
                    Text(
                        'Fecha de resolución: ${_fecha(r['fecha_resolucion'])}',
                        style: const TextStyle(color: Colors.white54)),
                  if ((_esAdmin == true && !resueltos) ||
                      (_esAdmin == false && propio && !resueltos)) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _ocupado || _consultando
                              ? null
                              : () => _accion(r, eliminar: _esAdmin == false),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: _esAdmin == true
                                  ? const Color(0xFF4CAF50)
                                  : Colors.red.shade700,
                              foregroundColor: Colors.white),
                          icon: Icon(_esAdmin == true
                              ? Icons.call
                              : Icons.delete_outline),
                          label: Text(_esAdmin == true
                              ? 'Llamar para resolver'
                              : 'Cancelar $_nombreSingular'),
                        )),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
        length: 2,
        child: Container(
          height: MediaQuery.of(context).size.height * 0.9,
          decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
          child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                child: Column(children: [
                  Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(8))),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                        child: Text(
                            _esAdmin == false
                                ? 'Mis $_nombrePlural'
                                : _tituloModal,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w600))),
                    IconButton(
                        tooltip: 'Actualizar',
                        onPressed:
                            _consultando || _ocupado ? null : () => _cargar(),
                        icon: const Icon(Icons.refresh, color: Colors.white54)),
                    IconButton(
                        tooltip: 'Cerrar',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Colors.white54)),
                  ]),
                  if (_esAdmin == false)
                    SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                            onPressed: _ocupado || _consultando ? null : _crear,
                            icon: const Icon(Icons.add),
                            label: const Text('Crear recado'))),
                  const TabBar(
                      labelColor: Color(0xFF20CDFF),
                      unselectedLabelColor: Colors.white54,
                      indicatorColor: Color(0xFF20CDFF),
                      tabs: [Tab(text: 'Pendientes'), Tab(text: 'Resueltos')]),
                  if (_consultando) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.orange))),
                  Expanded(
                      child: _cargando
                          ? const Center(child: CircularProgressIndicator())
                          : TabBarView(children: [
                              _buildRecados(resueltos: false),
                              _buildRecados(resueltos: true)
                            ])),
                ]),
              )),
        ));
  }
}

class _IntentoRecado {
  final String recadoId;
  final String callId;
  final String rut;
  Future<void>? _cancelacion;

  _IntentoRecado({
    required this.recadoId,
    required this.callId,
    required this.rut,
  });

  Future<void> cancelar() => _cancelacion ??= _cancelar();

  Future<void> _cancelar() async {
    // Cliente independiente: la pantalla puede haberse desmontado y cerrado
    // el cliente que utiliza para consultar recados.
    final client = http.Client();
    try {
      final response = await client
          .post(
            Uri.parse('$kBaseUrl/recados/$recadoId/llamada/cancelar'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'rut': rut, 'call_id': callId}),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('No se pudo confirmar el cierre de la llamada del recado.');
      }
    } catch (_) {
      debugPrint('No se pudo confirmar el cierre de la llamada del recado.');
    } finally {
      client.close();
    }
  }
}

class _NuevoRecadoDialog extends StatefulWidget {
  final Future<void> Function(String, String) onGuardar;
  const _NuevoRecadoDialog({required this.onGuardar});
  @override
  State<_NuevoRecadoDialog> createState() => _NuevoRecadoDialogState();
}

class _NuevoRecadoDialogState extends State<_NuevoRecadoDialog> {
  final _form = GlobalKey<FormState>();
  final _titulo = TextEditingController();
  final _descripcion = TextEditingController();
  bool _guardando = false;
  String? _error;
  @override
  void dispose() {
    _titulo.dispose();
    _descripcion.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (_guardando || !_form.currentState!.validate()) return;
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await widget.onGuardar(_titulo.text.trim(), _descripcion.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is TimeoutException
            ? 'El servidor tardó demasiado. Comprueba el listado antes de reintentar.'
            : e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
        canPop: !_guardando,
        child: AlertDialog(
          title: const Text('Crear recado'),
          content: SingleChildScrollView(
              child: Form(
                  key: _form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                          controller: _titulo,
                          enabled: !_guardando,
                          maxLength: 150,
                          decoration:
                              const InputDecoration(labelText: 'Título'),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'Escribe un título.'
                              : null),
                      TextFormField(
                          controller: _descripcion,
                          enabled: !_guardando,
                          maxLength: 5000,
                          minLines: 3,
                          maxLines: 6,
                          decoration:
                              const InputDecoration(labelText: 'Descripción'),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'Escribe la descripción.'
                              : null),
                      if (_error != null)
                        Text(_error!,
                            style: const TextStyle(color: Colors.red)),
                    ],
                  ))),
          actions: [
            TextButton(
                onPressed:
                    _guardando ? null : () => Navigator.pop(context, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: _guardando ? null : _guardar,
                child: Text(_guardando ? 'Guardando…' : 'Crear')),
          ],
        ));
  }
}
