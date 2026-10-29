import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

class HorariosModal extends StatefulWidget {
  final String miRut;
  final http.Client? client;

  const HorariosModal({super.key, required this.miRut, this.client});

  @override
  State<HorariosModal> createState() => _HorariosModalState();
}

class _HorariosModalState extends State<HorariosModal> {
  static const _colorFondo = Color(0xFF11111B);
  static const _colorTarjeta = Color(0xFF222233);
  static const _colorAcento = Color(0xFF448AFF);
  static const _etiquetaInicio = 'Salida';
  static const _etiquetaFin = 'Entrada';

  late final http.Client _client;
  DateTime? _inicio;
  DateTime? _fin;
  List<Map<String, dynamic>> _horarios = [];
  bool _cargando = true;
  bool _guardando = false;
  String? _errorCarga;
  String? _errorFormulario;

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

  String _mensajeError(Object error) {
    if (error is TimeoutException) {
      return 'El servidor tardó demasiado. Reintenta.';
    }
    if (error is http.ClientException) {
      return 'No se pudo conectar al servidor.';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  dynamic _leerRespuesta(http.Response response) {
    final dynamic data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw Exception(
          'El servidor no devolvió una respuesta válida de horarios.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(data is Map
          ? data['error'] ?? 'No se pudo completar la solicitud.'
          : 'No se pudo completar la solicitud.');
    }
    return data;
  }

  Future<void> _cargar() async {
    if (_guardando) return;
    setState(() => _cargando = true);
    try {
      final rut = widget.miRut.trim();
      if (rut.isEmpty) throw Exception('No se encontró el RUT del usuario.');
      final response = await _client
          .get(Uri.parse('$kBaseUrl/horarios')
              .replace(queryParameters: {'rut': rut}))
          .timeout(const Duration(seconds: 15));
      final data = _leerRespuesta(response);
      if (data is! List || data.any((horario) => horario is! Map)) {
        throw Exception('El servidor devolvió una lista de horarios inválida.');
      }
      final horarios = data
          .map((horario) => Map<String, dynamic>.from(horario as Map))
          .toList();
      if (!mounted) return;
      setState(() {
        _horarios = horarios;
        _errorCarga = null;
      });
    } catch (error) {
      if (mounted) setState(() => _errorCarga = _mensajeError(error));
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _seleccionarFecha({required bool inicio}) async {
    final actual = (inicio ? _inicio : _fin) ?? _inicio ?? DateTime.now();
    final etiqueta = inicio ? _etiquetaInicio : _etiquetaFin;
    final fecha = await showDatePicker(
      context: context,
      initialDate: actual,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      helpText: 'Fecha de ${etiqueta.toLowerCase()}',
      cancelText: 'Cancelar',
      confirmText: 'Seleccionar',
    );
    if (fecha == null || !mounted) return;
    final hora = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(actual),
      helpText: 'Hora de ${etiqueta.toLowerCase()}',
      cancelText: 'Cancelar',
      confirmText: 'Seleccionar',
      hourLabelText: 'Hora',
      minuteLabelText: 'Minuto',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (hora == null || !mounted) return;
    final seleccion =
        DateTime(fecha.year, fecha.month, fecha.day, hora.hour, hora.minute);
    setState(() {
      if (inicio) {
        _inicio = seleccion;
      } else {
        _fin = seleccion;
      }
      _errorFormulario = null;
    });
  }

  Future<void> _guardar() async {
    if (_guardando || _cargando) return;
    final inicio = _inicio;
    final fin = _fin;
    if (inicio == null || fin == null) {
      setState(() => _errorFormulario =
          'Selecciona la fecha y hora de salida y de entrada.');
      return;
    }
    if (!fin.isAfter(inicio)) {
      setState(() => _errorFormulario =
          'La fecha y hora de ${_etiquetaFin.toLowerCase()} debe ser posterior a la de ${_etiquetaInicio.toLowerCase()}.');
      return;
    }
    setState(() {
      _guardando = true;
      _errorFormulario = null;
    });
    try {
      final rut = widget.miRut.trim();
      if (rut.isEmpty) throw Exception('No se encontró el RUT del usuario.');
      final response = await _client
          .post(
            Uri.parse('$kBaseUrl/horarios'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'rut': rut,
              'fecha_inicio': inicio.toUtc().toIso8601String(),
              'fecha_fin': fin.toUtc().toIso8601String(),
            }),
          )
          .timeout(const Duration(seconds: 15));
      final data = _leerRespuesta(response);
      if (data is! Map || data['success'] != true || data['horario'] is! Map) {
        throw Exception('No se pudo confirmar el registro del horario.');
      }
      final horario = Map<String, dynamic>.from(data['horario'] as Map);
      if (!mounted) return;
      setState(() {
        _horarios.insert(0, horario);
        _inicio = null;
        _fin = null;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Horario registrado.')));
    } catch (error) {
      if (mounted) setState(() => _errorFormulario = _mensajeError(error));
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  String _fechaFormateada(DateTime fecha) {
    String dos(int numero) => numero.toString().padLeft(2, '0');
    return '${dos(fecha.day)}/${dos(fecha.month)}/${fecha.year} '
        '${dos(fecha.hour)}:${dos(fecha.minute)}';
  }

  String _fechaRegistro(dynamic valor) {
    final texto = valor?.toString().trim() ?? '';
    if (texto.isEmpty) return 'Fecha no disponible';
    final tieneZona =
        RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(texto);
    final fecha = DateTime.tryParse(tieneZona ? texto : '${texto}Z')?.toLocal();
    return fecha == null ? 'Fecha no disponible' : _fechaFormateada(fecha);
  }

  Widget _campoFecha({required bool inicio}) {
    final etiqueta = inicio ? _etiquetaInicio : _etiquetaFin;
    final fecha = inicio ? _inicio : _fin;
    return OutlinedButton.icon(
      key: ValueKey(inicio ? 'horario-inicio' : 'horario-fin'),
      onPressed: _guardando ? null : () => _seleccionarFecha(inicio: inicio),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: const Icon(Icons.event_rounded, color: _colorAcento),
      label: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Fecha y hora de ${etiqueta.toLowerCase()}',
              style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          Text(fecha == null ? 'Seleccionar' : _fechaFormateada(fecha)),
        ],
      ),
    );
  }

  Widget _registro(Map<String, dynamic> horario) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _colorTarjeta,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$_etiquetaInicio: ${_fechaRegistro(horario['fecha_inicio'])}',
              style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 6),
          Text('$_etiquetaFin: ${_fechaRegistro(horario['fecha_fin'])}',
              style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) => Container(
        decoration: const BoxDecoration(
          color: _colorFondo,
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
                  const Expanded(
                    child: Text('Horarios',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w300)),
                  ),
                  IconButton(
                    tooltip: 'Actualizar horarios',
                    onPressed: _cargando || _guardando ? null : _cargar,
                    icon: const Icon(Icons.refresh_rounded, color: Colors.grey),
                  ),
                  IconButton(
                    tooltip: 'Cerrar horarios',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('Registrar horario',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 6),
              const Text('Indica cuándo sales y cuándo vuelves.',
                  style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 12),
              _campoFecha(inicio: true),
              const SizedBox(height: 12),
              _campoFecha(inicio: false),
              if (_errorFormulario != null) ...[
                const SizedBox(height: 12),
                Text(_errorFormulario!,
                    style: const TextStyle(color: Colors.orange)),
              ],
              const SizedBox(height: 16),
              ElevatedButton.icon(
                key: const ValueKey('guardar-horario'),
                onPressed: _guardando || _cargando ? null : _guardar,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _colorAcento,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: _guardando
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save_rounded),
                label: Text(_guardando ? 'Guardando...' : 'Guardar horario'),
              ),
              const SizedBox(height: 24),
              const Text('Horarios registrados',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 12),
              if (_cargando)
                const Center(
                    child: CircularProgressIndicator(color: _colorAcento)),
              if (_errorCarga != null) ...[
                Text(_errorCarga!,
                    style: const TextStyle(color: Colors.orange)),
                TextButton(
                  onPressed: _cargando || _guardando ? null : _cargar,
                  child: const Text('Reintentar'),
                ),
              ],
              if (!_cargando && _errorCarga == null && _horarios.isEmpty)
                const Text('No hay horarios registrados.',
                    style: TextStyle(color: Colors.grey)),
              ..._horarios.map(_registro),
            ],
          ),
        ),
      ),
    );
  }
}
