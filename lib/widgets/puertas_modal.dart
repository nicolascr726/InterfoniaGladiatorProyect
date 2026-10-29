import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../services/puertas_excel_service.dart';
import '../helpers/filtro_fecha_hora.dart';

class PuertasModal extends StatefulWidget {
  static const String abrirPuertaEndpoint = '$kBaseUrl/api/puertas';
  static const String registrosEndpoint = '$kBaseUrl/api/puertas';
  final String miRut;
  final http.Client? client;
  final bool soloApertura;

  const PuertasModal({
    super.key,
    required this.miRut,
    this.client,
    this.soloApertura = false,
  });

  @override
  State<PuertasModal> createState() => _PuertasModalState();
}

class _PuertasModalState extends State<PuertasModal> {
  late final http.Client _client;
  Timer? _timer;
  bool? _esAdmin;
  bool _cargandoSesion = true;
  bool _consultando = false;
  bool _exportando = false;
  int? _enviandoPuerta;
  String? _error;
  List<Map<String, dynamic>> _registros = [];
  Map<String, Map<String, dynamic>> _citofonosPorId = {};
  final _busqueda = TextEditingController();
  FiltroFechaHora _filtroFechaHora = const FiltroFechaHora();

  bool get _mostrarReporte => _esAdmin == true && !widget.soloApertura;
  bool get _puedeAbrirPuertas =>
      _esAdmin == false || (_esAdmin == true && widget.soloApertura);

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? http.Client();
    _cargarSesion();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _busqueda.dispose();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  String _normalizarRut(String rut) =>
      rut.replaceAll('.', '').replaceAll('-', '').trim().toUpperCase();

  Future<void> _cargarSesion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rutSesion = _normalizarRut(prefs.getString('rut') ?? '');
      final rol = prefs.getInt('es_admin');
      if (rutSesion.isEmpty ||
          rutSesion != _normalizarRut(widget.miRut) ||
          (rol != 0 && rol != 1)) {
        throw Exception(
            'No se pudo identificar la sesión. Vuelve a iniciar sesión.');
      }
      if (!mounted) return;
      setState(() {
        _esAdmin = rol == 1;
        _cargandoSesion = false;
        _error = null;
      });
      _timer?.cancel();
      if (_mostrarReporte) {
        _timer = Timer.periodic(
            const Duration(seconds: 10), (_) => _cargarRegistros());
        await _cargarRegistros();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cargandoSesion = false;
        _error = _mensajeError(e);
      });
    }
  }

  String _mensajeError(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  dynamic _leerRespuesta(http.Response response) {
    final dynamic data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw Exception(
          'El servidor no devolvió una respuesta válida de Puertas.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(data is Map
          ? data['error'] ?? 'No se pudo completar la solicitud.'
          : 'No se pudo completar la solicitud.');
    }
    return data;
  }

  Future<void> _cargarRegistros() async {
    if (!mounted || !_mostrarReporte || _consultando || _exportando) return;
    setState(() => _consultando = true);
    try {
      final response = await _client
          .get(
            Uri.parse(PuertasModal.registrosEndpoint).replace(
              queryParameters: {'rut': widget.miRut},
            ),
          )
          .timeout(const Duration(seconds: 10));
      final data = _leerRespuesta(response);
      if (data is! List) {
        throw Exception('El servidor devolvió un reporte inválido.');
      }
      final registros =
          data.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      final citofonos = await _consultarCitofonos(registros);
      if (!mounted) return;
      setState(() {
        _registros = registros;
        _citofonosPorId = citofonos;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _consultando = false);
    }
  }

  String _texto(dynamic valor) => valor?.toString().trim() ?? '';

  bool _esAliasCitofono(String rut) =>
      _normalizarRut(rut).replaceAll('Ó', 'O').contains('CITOFONO');

  String _deviceIdRegistro(Map<String, dynamic> registro) {
    final identidad = registro['citofono'];
    final id = _texto(registro['device_id']);
    if (id.isNotEmpty) return id;
    if (identidad is Map) {
      final idGuardado = _texto(identidad['device_id']);
      if (idGuardado.isNotEmpty) return idGuardado;
    }
    // Los registros antiguos conservan el dispositivo solo en esta descripción.
    return RegExp(
          r'^Solicitud recibida desde el cit[oó]fono ([A-Za-z0-9][A-Za-z0-9_.-]{0,63})\.$',
          caseSensitive: false,
        ).firstMatch(_texto(registro['descripcion']))?.group(1) ??
        '';
  }

  String _rutRegistrado(Map<String, dynamic> registro) {
    final rut = _texto(registro['rut_emisor']);
    if (rut.isNotEmpty && !_esAliasCitofono(rut)) return rut;
    final identidad = registro['citofono'];
    if (identidad is Map) {
      final rutGuardado = _texto(identidad['rut_usuario']);
      if (rutGuardado.isNotEmpty && !_esAliasCitofono(rutGuardado)) {
        return rutGuardado;
      }
    }
    return '';
  }

  String _departamentoRegistrado(Map<String, dynamic> registro) {
    final departamento = _texto(registro['id_dpto']);
    if (departamento.isNotEmpty) return departamento;
    final identidad = registro['citofono'];
    return identidad is Map ? _texto(identidad['id_dpto']) : '';
  }

  Map<String, dynamic>? _citofonoActual(Map<String, dynamic> registro) {
    if (_rutRegistrado(registro).isNotEmpty) return null;
    return _citofonosPorId[_deviceIdRegistro(registro)];
  }

  Future<Map<String, Map<String, dynamic>>> _consultarCitofonos(
      List<Map<String, dynamic>> registros) async {
    if (!registros.any((registro) =>
        _rutRegistrado(registro).isEmpty &&
        _deviceIdRegistro(registro).isNotEmpty)) {
      return {};
    }
    try {
      final response = await _client
          .get(Uri.parse('$kBaseUrl/api/esp32/audio-status'))
          .timeout(const Duration(seconds: 8));
      final data = _leerRespuesta(response);
      final dispositivos = data is Map ? data['citofonos'] : null;
      if (dispositivos is! List) return {};
      return {
        for (final dispositivo in dispositivos.whereType<Map>())
          if (_texto(dispositivo['device_id']).isNotEmpty &&
              _texto(dispositivo['rut_usuario']).isNotEmpty &&
              !_esAliasCitofono(_texto(dispositivo['rut_usuario'])))
            _texto(dispositivo['device_id']):
                Map<String, dynamic>.from(dispositivo),
      };
    } catch (_) {
      // La asociación actual no sustituye la identidad histórica del registro.
      return {};
    }
  }

  Future<void> _registrarPuerta(int puerta) async {
    if (!_puedeAbrirPuertas || _enviandoPuerta != null) return;
    setState(() => _enviandoPuerta = puerta);
    String mensaje;
    try {
      // El endpoint registra la solicitud y envía la orden de apertura.
      final response = await _client
          .post(
            Uri.parse(PuertasModal.abrirPuertaEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'rut': widget.miRut,
              'puerta': puerta,
              'titulo': 'Apertura de puerta ${puerta == 1 ? 'uno' : 'dos'}',
              'descripcion':
                  'Se abrió la puerta ${puerta == 1 ? 'uno' : 'dos'}.',
            }),
          )
          .timeout(const Duration(seconds: 10));
      final data = _leerRespuesta(response);
      if (data is! Map || data['success'] != true || data['registro'] is! Map) {
        throw Exception('No se pudo confirmar el registro de la puerta.');
      }
      mensaje =
          'Se registró la apertura de la puerta ${puerta == 1 ? 'uno' : 'dos'}.';
    } on TimeoutException {
      mensaje =
          'El servidor no respondió a tiempo. No se pudo confirmar el registro.';
    } catch (e) {
      mensaje = _mensajeError(e);
    } finally {
      if (mounted) setState(() => _enviandoPuerta = null);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(mensaje)));
  }

  Widget _botonPuerta(int puerta) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed:
            _enviandoPuerta == null ? () => _registrarPuerta(puerta) : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF222233),
          foregroundColor: const Color(0xFF448AFF),
          padding: const EdgeInsets.all(18),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        icon: const Icon(Icons.lock_open_rounded),
        label: Text(_enviandoPuerta == puerta
            ? 'Registrando...'
            : 'Abrir puerta ${puerta == 1 ? 'uno' : 'dos'}'),
      ),
    );
  }

  DateTime? _fechaLocal(dynamic valor) => PuertasExcelService.fechaLocal(valor);

  String _dia(DateTime? fecha) {
    if (fecha == null) return 'Fecha no registrada';
    String dos(int numero) => numero.toString().padLeft(2, '0');
    return '${dos(fecha.day)}/${dos(fecha.month)}/${fecha.year}';
  }

  String _fechaRegistro(dynamic valor) {
    final fecha = _fechaLocal(valor);
    if (fecha == null) return '';
    String dos(int numero) => numero.toString().padLeft(2, '0');
    return '${dos(fecha.day)}/${dos(fecha.month)}/${fecha.year} '
        '${dos(fecha.hour)}:${dos(fecha.minute)}:${dos(fecha.second)}';
  }

  String _normalizarBusqueda(String valor) => valor
      .toLowerCase()
      .trim()
      .replaceFirst(RegExp(r'^(departamento|depto|dpto|rut)[.:]?\s*'), '')
      .replaceAll(RegExp(r'[\s\-\.#°º]'), '');

  List<Map<String, dynamic>> _registrosVisibles() {
    final consulta = _normalizarBusqueda(_busqueda.text);
    return _registros.where((registro) {
      if (!_filtroFechaHora.incluye(_fechaLocal(registro['fecha_creacion']))) {
        return false;
      }
      final asociado = _citofonoActual(registro);
      final departamento = _departamentoRegistrado(registro);
      return [
        departamento,
        _rutRegistrado(registro),
        if (departamento.isEmpty) _texto(asociado?['id_dpto']),
        _texto(asociado?['rut_usuario']),
      ].any((valor) => _normalizarBusqueda(valor).contains(consulta));
    }).toList()
      ..sort((a, b) {
        final fechaA = _fechaLocal(a['fecha_creacion']);
        final fechaB = _fechaLocal(b['fecha_creacion']);
        if (fechaA == null) return fechaB == null ? 0 : 1;
        if (fechaB == null) return -1;
        return fechaB.compareTo(fechaA);
      });
  }

  Future<void> _exportarExcel() async {
    if (!_mostrarReporte ||
        _cargandoSesion ||
        _consultando ||
        _exportando ||
        _error != null) {
      return;
    }
    final registros = _registrosVisibles().map((registro) {
      final rut = _rutRegistrado(registro);
      final departamento = _departamentoRegistrado(registro);
      final asociado = _citofonoActual(registro);
      return <String, dynamic>{
        ...registro,
        'rut_emisor': rut.isEmpty ? registro['rut_emisor'] : rut,
        'id_dpto': departamento,
        'device_id': _deviceIdRegistro(registro),
        if (asociado != null) ...{
          'rut_asociado_actual': asociado['rut_usuario'],
          if (departamento.isEmpty)
            'id_dpto_asociado_actual': asociado['id_dpto'],
        },
      };
    }).toList();
    if (registros.isEmpty) return;
    setState(() => _exportando = true);
    try {
      final guardado =
          await PuertasExcelService.exportar(registros, client: _client);
      if (guardado && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Excel guardado con ${registros.length} registros de puertas.'),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No se pudo guardar el Excel. Inténtalo nuevamente.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _exportando = false);
    }
  }

  List<Widget> _registrosAgrupados(List<Map<String, dynamic>> registros) {
    final widgets = <Widget>[];
    String? diaAnterior;
    for (final registro in registros) {
      final dia = _dia(_fechaLocal(registro['fecha_creacion']));
      if (dia != diaAnterior) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Row(children: [
            const Expanded(child: Divider(color: Colors.white24)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(dia,
                  style: const TextStyle(
                      color: Colors.white70, fontWeight: FontWeight.w600)),
            ),
            const Expanded(child: Divider(color: Colors.white24)),
          ]),
        ));
        diaAnterior = dia;
      }
      widgets.add(_registro(registro));
    }
    return widgets;
  }

  Widget _registro(Map<String, dynamic> registro) {
    final fecha = _fechaRegistro(registro['fecha_creacion']);
    final dpto = _departamentoRegistrado(registro);
    final emisor = _rutRegistrado(registro);
    final deviceId = _deviceIdRegistro(registro);
    final asociado = _citofonoActual(registro);
    final rutAsociado = _texto(asociado?['rut_usuario']);
    final dptoAsociado = _texto(asociado?['id_dpto']);
    final titulo = registro['titulo']?.toString() ?? 'Registro de puerta';
    final descripcion = registro['descripcion']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFF222233),
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          leading: const Icon(Icons.door_front_door_rounded,
              color: Color(0xFF448AFF)),
          title: Text(titulo, style: const TextStyle(color: Colors.white)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (descripcion.isNotEmpty)
                Text(descripcion, style: const TextStyle(color: Colors.grey)),
              Text(
                [
                  if (dpto.isNotEmpty) 'Depto. $dpto',
                  if (dpto.isEmpty && dptoAsociado.isNotEmpty)
                    'Depto. asociado actualmente: $dptoAsociado',
                  if (deviceId.isNotEmpty) 'Citófono: $deviceId',
                  if (emisor.isNotEmpty)
                    'RUT: $emisor'
                  else if (rutAsociado.isNotEmpty)
                    'RUT: $rutAsociado'
                  else if (_esAliasCitofono(_texto(registro['rut_emisor'])) ||
                      deviceId.isNotEmpty)
                    'RUT del citófono no registrado',
                  if (fecha.isNotEmpty) fecha,
                ].join('\n'),
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final registros = _registrosVisibles();
    return DraggableScrollableSheet(
      initialChildSize: _mostrarReporte ? 0.75 : 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF11111B),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                        _mostrarReporte ? 'Reporte de puertas' : 'Puertas',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w300)),
                  ),
                  if (_mostrarReporte)
                    IconButton(
                      tooltip: 'Actualizar registros',
                      icon:
                          const Icon(Icons.refresh_rounded, color: Colors.grey),
                      onPressed:
                          _consultando || _exportando ? null : _cargarRegistros,
                    ),
                  IconButton(
                    tooltip: 'Cerrar puertas',
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_cargandoSesion || (_consultando && _registros.isEmpty))
                const Center(
                    child: CircularProgressIndicator(color: Color(0xFF448AFF))),
              if (_error != null) ...[
                Text(_error!, style: const TextStyle(color: Colors.orange)),
                TextButton(
                  onPressed: _consultando
                      ? null
                      : (_esAdmin == null ? _cargarSesion : _cargarRegistros),
                  child: const Text('Reintentar'),
                ),
                const SizedBox(height: 12),
              ],
              if (_puedeAbrirPuertas) ...[
                _botonPuerta(1),
                const SizedBox(height: 14),
                _botonPuerta(2),
              ],
              if (_mostrarReporte) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('buscar_puertas'),
                        controller: _busqueda,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Buscar por departamento o RUT',
                          hintText: 'Ej.: 101 o 12.345.678-9',
                          labelStyle: const TextStyle(color: Colors.white70),
                          hintStyle: const TextStyle(color: Colors.white54),
                          prefixIcon:
                              const Icon(Icons.search, color: Colors.white54),
                          suffixIcon: _busqueda.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Limpiar búsqueda',
                                  icon: const Icon(Icons.close,
                                      color: Colors.white54),
                                  onPressed: () => setState(_busqueda.clear)),
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
                      child: FiltroFechaHoraButton(
                        key: const ValueKey('filtro_puertas'),
                        filtro: _filtroFechaHora,
                        enabled: !_exportando,
                        mostrarResumen: false,
                        onChanged: (filtro) =>
                            setState(() => _filtroFechaHora = filtro),
                      ),
                    ),
                  ],
                ),
                if (_filtroFechaHora.activo)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _filtroFechaHora.resumen,
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const ValueKey('exportar_puertas'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF20CDFF),
                      disabledForegroundColor: Colors.white38,
                    ),
                    onPressed: _cargandoSesion ||
                            _consultando ||
                            _exportando ||
                            _error != null ||
                            registros.isEmpty
                        ? null
                        : _exportarExcel,
                    icon: _exportando
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined),
                    label: Text(_exportando
                        ? 'Guardando Excel…'
                        : 'Exportar a Excel (${registros.length})'),
                  ),
                ),
                const SizedBox(height: 16),
                if (registros.isEmpty && !_consultando && _error == null)
                  Text(
                      _filtroFechaHora.activo
                          ? 'No hay registros de puertas que coincidan con los filtros.'
                          : _normalizarBusqueda(_busqueda.text).isNotEmpty
                              ? 'No hay registros de puertas para ese departamento o RUT.'
                              : 'No hay registros de puertas.',
                      style: const TextStyle(color: Colors.grey),
                      textAlign: TextAlign.center),
                ..._registrosAgrupados(registros),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
