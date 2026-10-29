import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../services/historial_excel_service.dart';
import '../helpers/filtro_fecha_hora.dart';

class HistorialModal extends StatefulWidget {
  final String miRut;
  final http.Client? client;
  const HistorialModal({super.key, required this.miRut, this.client});

  @override
  State<HistorialModal> createState() => _HistorialModalState();
}

class _HistorialModalState extends State<HistorialModal> {
  late final http.Client _client;
  List<Map<String, dynamic>> _historial = [];
  Map<String, String> _nombresPorRut = {};
  Map<String, String> _departamentosPorRut = {};
  Map<String, Map<String, dynamic>> _citofonosPorId = {};
  final _busqueda = TextEditingController();
  FiltroFechaHora _filtroFechaHora = const FiltroFechaHora();
  bool _loading = true;
  bool _exportando = false;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? http.Client();
    _cargar();
  }

  @override
  void dispose() {
    _busqueda.dispose();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  Future<void> _cargar() async {
    try {
      final res = await _client
          .get(
            Uri.parse('$kBaseUrl/historial')
                .replace(queryParameters: {'rut': widget.miRut}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        throw const FormatException('No se pudo consultar el historial.');
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! List || data.any((llamada) => llamada is! Map)) {
        throw const FormatException('El historial no es válido.');
      }
      final historial = data
          .map((llamada) => Map<String, dynamic>.from(llamada as Map))
          .toList()
        ..sort((a, b) {
          final fechaA = _fechaLocal(a['fecha']);
          final fechaB = _fechaLocal(b['fecha']);
          if (fechaA == null) return fechaB == null ? 0 : 1;
          if (fechaB == null) return -1;
          return fechaB.compareTo(fechaA);
        });
      if (!mounted) return;
      setState(() {
        _historial = historial;
        _loading = false;
      });
      await Future.wait([
        _cargarCitofonos(),
        _cargarParticipantes(),
      ]);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cargarParticipantes() async {
    if (_historial.isEmpty) return;
    try {
      final listas = await Future.wait(
        ['/usuarios-todos', '/usuarios-conserjes'].map((ruta) async {
          final respuesta = await _client
              .get(Uri.parse('$kBaseUrl$ruta')
                  .replace(queryParameters: {'rut': widget.miRut}))
              .timeout(const Duration(seconds: 15));
          if (respuesta.statusCode != 200) {
            throw const FormatException('No se pudo consultar el directorio.');
          }
          final datos = jsonDecode(utf8.decode(respuesta.bodyBytes));
          if (datos is! List || datos.any((usuario) => usuario is! Map)) {
            throw const FormatException('El directorio no es válido.');
          }
          return datos
              .map((usuario) => Map<String, dynamic>.from(usuario as Map))
              .toList();
        }),
      );
      final esConserje = listas[1].any((usuario) =>
          _normalizarIdentificador(usuario['rut_usuario']) ==
              _normalizarIdentificador(widget.miRut) &&
          (usuario['es_admin'] == true || usuario['es_admin'] == 1));
      if (!esConserje) return;
      final nombres = <String, String>{};
      final departamentos = <String, String>{};
      for (final usuario in listas.expand((usuarios) => usuarios)) {
        final rut = _normalizarIdentificador(usuario['rut_usuario']);
        if (rut.isEmpty) continue;
        final nombre = [usuario['nombres'], usuario['apellido_1']]
            .map(_texto)
            .where((parte) => parte.isNotEmpty)
            .join(' ');
        nombres[rut] = nombre.isEmpty ? _texto(usuario['rut_usuario']) : nombre;
        departamentos[rut] = _texto(usuario['id_dpto']);
      }
      if (!mounted) return;
      setState(() {
        _nombresPorRut = nombres;
        _departamentosPorRut = departamentos;
      });
    } catch (_) {
      // El historial permanece visible si no se puede consultar el directorio.
      // No se asigna al usuario actual como receptor de llamadas de terceros.
    }
  }

  String _texto(dynamic valor) => valor?.toString().trim() ?? '';

  String _normalizarBusqueda(String valor) => valor
      .toLowerCase()
      .trim()
      .replaceFirst(RegExp(r'^(departamento|depto|dpto|rut)[.:]?\s*'), '')
      .replaceAll(RegExp(r'[\s\-\.#°º]'), '');

  List<Map<String, dynamic>> _historialVisible() {
    final consulta = _normalizarBusqueda(_busqueda.text);
    return _historial.where((llamada) {
      if (!_filtroFechaHora.incluye(_fechaLocal(llamada['fecha']))) {
        return false;
      }
      if (consulta.isEmpty) return true;
      final citofono = llamada['citofono'];
      final departamentos = [
        llamada['id_dpto'],
        llamada['id_dpto_emisor'],
        llamada['id_dpto_receptor'],
        _departamentosPorRut[_normalizarIdentificador(llamada['rut_emisor'])],
        _departamentosPorRut[_normalizarIdentificador(llamada['rut_receptor'])],
        if (citofono is Map) ...[
          citofono['id_dpto'],
          _departamentosPorRut[
              _normalizarIdentificador(citofono['rut_usuario'])],
        ],
      ];
      final ruts = [
        llamada['rut_emisor'],
        llamada['rut_receptor'],
        if (citofono is Map) citofono['rut_usuario'],
      ];
      return [
        ...departamentos,
        ...ruts
      ].any((valor) => _normalizarBusqueda(_texto(valor)).contains(consulta));
    }).toList();
  }

  String _normalizarIdentificador(dynamic valor) => _texto(valor)
      .replaceAll(RegExp(r'[.\s-]'), '')
      .toUpperCase()
      .replaceAll('Ó', 'O');

  bool _esCitofono(dynamic valor) =>
      _normalizarIdentificador(valor).contains('CITOFONO');

  bool _esNombreCitofono(String nombre) =>
      RegExp(r'^cit[oó]fono(?:\s|$)', caseSensitive: false).hasMatch(nombre);

  Future<void> _cargarCitofonos() async {
    if (_historial.isEmpty) return;
    try {
      final respuesta = await _client
          .get(Uri.parse('$kBaseUrl/api/esp32/audio-status'))
          .timeout(const Duration(seconds: 8));
      if (respuesta.statusCode != 200) return;
      final data = jsonDecode(utf8.decode(respuesta.bodyBytes));
      final dispositivos = data is Map ? data['citofonos'] : null;
      if (dispositivos is! List || !mounted) return;
      final porId = <String, Map<String, dynamic>>{};
      for (final dispositivo in dispositivos.whereType<Map>()) {
        final id = _texto(dispositivo['device_id']);
        if (id.isNotEmpty) {
          porId[id] = Map<String, dynamic>.from(dispositivo);
        }
      }
      setState(() => _citofonosPorId = porId);
    } catch (_) {
      // Una consulta de equipos fallida no impide consultar el historial.
    }
  }

  String _nombreCitofono(Map dispositivo) {
    final nombre = _texto(dispositivo['display_name']);
    if (nombre.isNotEmpty) return nombre;
    final nombreCompleto = _texto(dispositivo['nombre_completo']);
    if (nombreCompleto.isNotEmpty) return 'Citofono de $nombreCompleto';
    final rut = _texto(dispositivo['rut_usuario']);
    if (rut.isNotEmpty) {
      final propietario = _nombresPorRut[_normalizarIdentificador(rut)];
      return 'Citofono de ${propietario ?? 'RUT $rut'}';
    }
    final id = _texto(dispositivo['device_id']);
    return id.isEmpty ? 'Citofono (propietario no registrado)' : 'Citofono $id';
  }

  ({String emisor, String receptor}) _resolverParticipantes(
      Map<String, dynamic> llamada) {
    final participantes = HistorialExcelService.resolverParticipantes(
      llamada,
      miRut: widget.miRut,
      nombresPorRut: _nombresPorRut,
    );
    final emisorCitofono = _esCitofono(llamada['rut_emisor']) ||
        _esNombreCitofono(participantes.emisor);
    final receptorCitofono = _esCitofono(llamada['rut_receptor']) ||
        _esNombreCitofono(participantes.receptor);

    String resolver(
        String campoRut, String campoNombre, String nombre, bool esCitofono) {
      final rut = _texto(llamada[campoRut]);
      // Preferir la identidad conservada en el registro, si está disponible.
      final identidad = llamada['citofono'];
      if (esCitofono &&
          identidad is Map &&
          emisorCitofono != receptorCitofono) {
        return _nombreCitofono(identidad);
      }
      if (RegExp(r'^cit[oó]fono de\s+', caseSensitive: false)
          .hasMatch(nombre)) {
        return nombre;
      }
      final nombreExplicito = _texto(llamada[campoNombre]);
      if (esCitofono &&
          nombreExplicito.isNotEmpty &&
          !_esNombreCitofono(nombreExplicito)) {
        return 'Citofono de $nombreExplicito';
      }

      // Nunca resolver el alias genérico mediante los equipos conectados hoy.
      final id = _normalizarIdentificador(rut);
      if (id.isNotEmpty &&
          id != 'CITOFONO' &&
          (esCitofono || !RegExp(r'^[0-9]+K?$').hasMatch(id))) {
        var dispositivo = _citofonosPorId[rut];
        if (dispositivo == null) {
          final coincidencias = _citofonosPorId.values
              .where((d) => _normalizarIdentificador(d['device_id']) == id)
              .toList();
          // El historial normaliza los IDs: no elegir si la coincidencia es ambigua.
          if (coincidencias.length == 1) dispositivo = coincidencias.single;
        }
        if (dispositivo != null) return _nombreCitofono(dispositivo);
      }
      if (!esCitofono) return nombre;
      if (_esCitofono(rut) && _normalizarIdentificador(rut) != 'CITOFONO') {
        return 'Citofono $rut';
      }
      // CITOFONO no identifica una placa concreta, aunque solo haya una online.
      return 'Citofono (propietario no registrado)';
    }

    return (
      emisor: resolver(
          'rut_emisor', 'nombre_emisor', participantes.emisor, emisorCitofono),
      receptor: resolver('rut_receptor', 'nombre_receptor',
          participantes.receptor, receptorCitofono),
    );
  }

  Future<void> _exportarExcel() async {
    if (_loading || _exportando) return;
    final historial = List<Map<String, dynamic>>.from(_historialVisible());
    if (historial.isEmpty) return;
    setState(() => _exportando = true);
    try {
      final guardado = await HistorialExcelService.exportar(historial);
      if (guardado && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Excel guardado con ${historial.length} llamadas.'),
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

  Color _colorEstado(String estado) {
    switch (estado.trim().toLowerCase()) {
      case 'finalizada':
        return const Color(0xFF4CAF50);
      case 'ocupado':
        return const Color(0xFFffb142);
      case 'perdida':
        return const Color(0xFFff5252);
      default:
        return Colors.grey;
    }
  }

  DateTime? _fechaLocal(dynamic valor) =>
      HistorialExcelService.fechaLocal(valor);

  String _dia(dynamic valor) {
    final fecha = _fechaLocal(valor);
    if (fecha == null) return 'Fecha no registrada';
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${dos(fecha.day)}/${dos(fecha.month)}/${fecha.year}';
  }

  @override
  Widget build(BuildContext context) {
    final historial = _historialVisible();
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF11111B),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
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
                    child: Text('Historial de Llamadas',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w300)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('buscar_historial'),
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
                      key: const ValueKey('filtro_historial'),
                      filtro: _filtroFechaHora,
                      enabled: !_exportando,
                      mostrarResumen: false,
                      onChanged: (filtro) =>
                          setState(() => _filtroFechaHora = filtro),
                    ),
                  ),
                ],
              ),
            ),
            if (_filtroFechaHora.activo)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
                child: Text(
                  _filtroFechaHora.resumen,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('exportar_historial'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF20CDFF),
                    disabledForegroundColor: Colors.white38,
                  ),
                  onPressed: _loading || _exportando || historial.isEmpty
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
                      : 'Exportar a Excel (${historial.length})'),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child:
                          CircularProgressIndicator(color: Color(0xFF448AFF)))
                  : historial.isEmpty
                      ? Center(
                          child: Text(
                              _filtroFechaHora.activo
                                  ? 'No hay llamadas que coincidan con los filtros.'
                                  : _normalizarBusqueda(_busqueda.text).isEmpty
                                      ? 'No hay historial de llamadas.'
                                      : 'No hay llamadas para ese departamento o RUT.',
                              style: const TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 16),
                          itemCount: historial.length,
                          itemBuilder: (_, i) {
                            final l = historial[i];
                            final dia = _dia(l['fecha']);
                            final mostrarDia = i == 0 ||
                                _dia(historial[i - 1]['fecha']) != dia;
                            final participantes = _resolverParticipantes(l);
                            final tipo = (l['tipo'] ?? 'Llamada').toString();
                            final fecha =
                                HistorialExcelService.formatearFechaLocal(
                                    l['fecha']);
                            final estado =
                                (l['estado'] ?? 'Finalizada').toString();
                            final duracion =
                                HistorialExcelService.formatearDuracion(
                                    l['duracion_segundos'] ?? 0);

                            final tarjeta = Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: _colorEstado(estado)
                                      .withValues(alpha: 0.25),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: _colorEstado(estado)
                                          .withValues(alpha: 0.15),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      tipo.toLowerCase().contains('saliente')
                                          ? Icons.call_made_rounded
                                          : Icons.call_received_rounded,
                                      color: _colorEstado(estado),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          tipo,
                                          style: TextStyle(
                                            color: _colorEstado(estado),
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Emisor: ${participantes.emisor}',
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 13,
                                          ),
                                        ),
                                        Text(
                                          'Receptor: ${participantes.receptor}',
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          fecha,
                                          style: const TextStyle(
                                            color: Colors.grey,
                                            fontSize: 12,
                                          ),
                                        ),
                                        Text(
                                          'Estado: $estado · Duración: $duracion',
                                          style: const TextStyle(
                                            color: Colors.grey,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (mostrarDia)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                        top: 4, bottom: 12),
                                    child: Row(children: [
                                      const Expanded(
                                          child:
                                              Divider(color: Colors.white24)),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12),
                                        child: Text(dia,
                                            style: const TextStyle(
                                                color: Colors.white70,
                                                fontWeight: FontWeight.w600)),
                                      ),
                                      const Expanded(
                                          child:
                                              Divider(color: Colors.white24)),
                                    ]),
                                  ),
                                tarjeta,
                              ],
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
