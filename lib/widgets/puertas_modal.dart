import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';

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
  int? _enviandoPuerta;
  String? _error;
  List<Map<String, dynamic>> _registros = [];

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
    if (!mounted || !_mostrarReporte || _consultando) return;
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
      if (!mounted) return;
      setState(() {
        _registros = registros;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _consultando = false);
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

  String _fechaRegistro(dynamic valor) {
    final texto = valor?.toString().trim() ?? '';
    final tieneZona =
        RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(texto);
    final fecha = DateTime.tryParse(tieneZona ? texto : '${texto}Z')?.toLocal();
    if (fecha == null) return '';
    String dos(int numero) => numero.toString().padLeft(2, '0');
    return '${dos(fecha.day)}/${dos(fecha.month)}/${fecha.year} '
        '${dos(fecha.hour)}:${dos(fecha.minute)}:${dos(fecha.second)}';
  }

  Widget _registro(Map<String, dynamic> registro) {
    final fecha = _fechaRegistro(registro['fecha_creacion']);
    final dpto = registro['id_dpto']?.toString() ?? '';
    final emisor = registro['rut_emisor']?.toString() ?? '';
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
                  if (emisor.isNotEmpty) 'RUT: $emisor',
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
                      onPressed: _consultando ? null : _cargarRegistros,
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
                if (_registros.isEmpty && !_consultando && _error == null)
                  const Text('No hay registros de puertas.',
                      style: TextStyle(color: Colors.grey),
                      textAlign: TextAlign.center),
                ..._registros.map(_registro),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
