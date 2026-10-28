import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../services/historial_excel_service.dart';

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
  Map<String, Map<String, dynamic>> _citofonosPorId = {};
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
        if (_requiereNombresParticipantes(historial))
          _cargarNombresParticipantes(),
      ]);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _requiereNombresParticipantes(List<Map<String, dynamic>> historial) {
    String texto(dynamic valor) => valor?.toString().trim() ?? '';
    return historial.any((llamada) {
      final tipo =
          texto(llamada['tipo']).replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
      final saliente = tipo == 'saliente' || tipo.startsWith('saliente ');
      final faltaEmisor = texto(llamada['nombre_emisor']).isEmpty &&
          (texto(llamada['rut_emisor']).isNotEmpty ||
              (saliente && widget.miRut.trim().isNotEmpty));
      final faltaReceptor = texto(llamada['nombre_receptor']).isEmpty &&
          texto(llamada['rut_receptor']).isNotEmpty;
      return faltaEmisor || faltaReceptor;
    });
  }

  Future<void> _cargarNombresParticipantes() async {
    try {
      final nombres = await HistorialExcelService.consultarNombresParticipantes(
          _client, widget.miRut);
      if (!mounted) return;
      setState(() => _nombresPorRut = nombres);
    } catch (_) {
      // El historial permanece visible si no se puede consultar el directorio.
      // No se asigna al usuario actual como receptor de llamadas de terceros.
    }
  }

  String _texto(dynamic valor) => valor?.toString().trim() ?? '';

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
    return id.isEmpty
        ? 'Citofono (propietario no registrado)'
        : 'Citofono $id';
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

    String resolver(String campoRut, String campoNombre, String nombre,
        bool esCitofono) {
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
      if (_esCitofono(rut) &&
          _normalizarIdentificador(rut) != 'CITOFONO') {
        return 'Citofono $rut';
      }
      // CITOFONO no identifica una placa concreta, aunque solo haya una online.
      return 'Citofono (propietario no registrado)';
    }

    return (
      emisor: resolver('rut_emisor', 'nombre_emisor', participantes.emisor,
          emisorCitofono),
      receptor: resolver('rut_receptor', 'nombre_receptor',
          participantes.receptor, receptorCitofono),
    );
  }

  Future<void> _exportarExcel() async {
    if (_loading || _exportando || _historial.isEmpty) return;
    final historial = List<Map<String, dynamic>>.from(_historial);
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

  DateTime? _fechaLocal(dynamic valor) => HistorialExcelService.fechaLocal(valor);

  String _dia(dynamic valor) {
    final fecha = _fechaLocal(valor);
    if (fecha == null) return 'Fecha no registrada';
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${dos(fecha.day)}/${dos(fecha.month)}/${fecha.year}';
  }

  @override
  Widget build(BuildContext context) {
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
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('exportar_historial'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF20CDFF),
                    disabledForegroundColor: Colors.white38,
                  ),
                  onPressed: _loading || _exportando || _historial.isEmpty
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
                      : 'Exportar a Excel (${_historial.length})'),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child:
                          CircularProgressIndicator(color: Color(0xFF448AFF)))
                  : _historial.isEmpty
                      ? const Center(
                          child: Text('No hay historial de llamadas.',
                              style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 16),
                          itemCount: _historial.length,
                          itemBuilder: (_, i) {
                            final l = _historial[i];
                            final dia = _dia(l['fecha']);
                            final mostrarDia = i == 0 ||
                                _dia(_historial[i - 1]['fecha']) != dia;
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
                                          child: Divider(color: Colors.white24)),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12),
                                        child: Text(dia,
                                            style: const TextStyle(
                                                color: Colors.white70,
                                                fontWeight: FontWeight.w600)),
                                      ),
                                      const Expanded(
                                          child: Divider(color: Colors.white24)),
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
