import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

enum DestinoExcel { dispositivo, correo }

class ExcelService {
  static const maxBytesCorreo = 8 * 1024 * 1024;

  static bool correoValido(String correo) =>
      correo.length <= 254 &&
      RegExp(r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$")
          .hasMatch(correo);

  static Future<DestinoExcel?> mostrarOpciones(
    BuildContext context, {
    required Future<bool> Function(String? correo) exportar,
  }) =>
      showDialog<DestinoExcel>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ExportarExcelDialog(exportar: exportar),
      );

  static Future<void> enviarCorreo(
    Uint8List bytes, {
    required String nombre,
    required String correo,
    http.Client? client,
  }) async {
    final destinatario = correo.trim();
    if (!correoValido(destinatario)) {
      throw StateError('Ingresa un correo electrónico válido.');
    }
    if (bytes.length > maxBytesCorreo) {
      throw StateError('El Excel supera los 8 MB. Reduce el rango de fechas.');
    }
    final token = await _tokenCorreo();
    final peticion = http.MultipartRequest(
        'POST', Uri.parse('$kBaseUrl/api/excel/enviar-correo'))
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['correo'] = destinatario
      ..files.add(
          http.MultipartFile.fromBytes('archivo', bytes, filename: nombre));
    final conexion = client ?? http.Client();
    try {
      final respuesta = await (() async {
        final stream = await conexion.send(peticion);
        return http.Response.fromStream(stream);
      })()
          .timeout(const Duration(seconds: 90));
      if (respuesta.statusCode == 401) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getString('excel_mail_token') == token) {
          await prefs.remove('excel_mail_token');
        }
        throw StateError('Tu sesión de envío venció. Vuelve a iniciar sesión.');
      }
      dynamic datos;
      try {
        datos = jsonDecode(utf8.decode(respuesta.bodyBytes));
      } catch (_) {
        throw StateError('El servidor no confirmó el envío del Excel.');
      }
      if (respuesta.statusCode != 200 ||
          datos is! Map ||
          datos['success'] != true) {
        throw StateError(datos is Map && datos['error'] is String
            ? datos['error'] as String
            : 'No se pudo enviar el Excel. Inténtalo nuevamente.');
      }
    } on TimeoutException {
      throw StateError('El servidor tardó demasiado en confirmar el envío. '
          'Revisa tu correo antes de reintentar.');
    } on http.ClientException {
      throw StateError('No se pudo confirmar el envío. '
          'Revisa tu conexión y tu correo antes de reintentar.');
    } finally {
      if (client == null) conexion.close();
    }
  }

  static String _normalizarRut(String rut) => rut
      .replaceAll('.', '')
      .replaceAll('-', '')
      .trim()
      .toUpperCase()
      .replaceAll('Ó', 'O');

  static Future<({SharedPreferences prefs, String rut})> _sesionCorreo() async {
    final prefs = await SharedPreferences.getInstance();
    final rut = _normalizarRut(prefs.getString('rut') ?? '');
    if (rut.isEmpty || prefs.getInt('es_admin') != 1) {
      throw StateError('No se encontró una sesión de conserjería activa.');
    }
    return (prefs: prefs, rut: rut);
  }

  // Solo anticipa la renovación; el servidor verifica la firma y el rol.
  static bool _tokenVigente(String token, String rut) {
    try {
      final partes = token.split('.');
      if (partes.length != 3) return false;
      final datos = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(partes[1]))));
      return datos is Map &&
          datos['sub'] is String &&
          _normalizarRut(datos['sub'] as String) == rut &&
          datos['aud'] == 'excel-mail' &&
          datos['exp'] is num &&
          (datos['exp'] as num) >
              DateTime.now().millisecondsSinceEpoch / 1000 + 30;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _tokenCorreo() async {
    final sesion = await _sesionCorreo();
    final token = sesion.prefs.getString('excel_mail_token') ?? '';
    if (token.isEmpty &&
        sesion.prefs.getBool('excel_mail_sin_configuracion') == true) {
      throw StateError('El servidor no tiene configurado el envío de correos. '
          'Contacta a la administración.');
    }
    if (!_tokenVigente(token, sesion.rut)) {
      throw StateError('Vuelve a iniciar sesión para enviar el Excel.');
    }
    return token;
  }

  /// Conserva únicamente la autorización que entrega un inicio de sesión válido.
  static Future<void> guardarAutorizacionCorreo(
      Map<String, dynamic> datos) async {
    final prefs = await SharedPreferences.getInstance();
    final rut = _normalizarRut(prefs.getString('rut') ?? '');
    final token = datos['excel_mail_token'];
    await prefs.remove('excel_mail_token');
    await prefs.remove('excel_mail_sin_configuracion');
    if (datos['success'] == true &&
        prefs.getInt('es_admin') == 1 &&
        (datos['es_admin'] == true || datos['es_admin'] == 1) &&
        _normalizarRut(datos['rut']?.toString() ?? '') == rut) {
      if (token is String && _tokenVigente(token, rut)) {
        await prefs.setString('excel_mail_token', token);
      } else if (token == null || (token is String && token.trim().isEmpty)) {
        // El login actual no emite el token si el servidor no habilitó el correo.
        await prefs.setBool('excel_mail_sin_configuracion', true);
      }
    }
  }
}

class _ExportarExcelDialog extends StatefulWidget {
  final Future<bool> Function(String? correo) exportar;
  const _ExportarExcelDialog({required this.exportar});

  @override
  State<_ExportarExcelDialog> createState() => _ExportarExcelDialogState();
}

class _ExportarExcelDialogState extends State<_ExportarExcelDialog> {
  final _correo = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _porCorreo = false;
  bool _procesando = false;
  String? _error;

  @override
  void dispose() {
    _correo.dispose();
    super.dispose();
  }

  Future<void> _exportar() async {
    if (_procesando || (_porCorreo && !_form.currentState!.validate())) return;
    setState(() {
      _procesando = true;
      _error = null;
    });
    try {
      if (_porCorreo) {
        await ExcelService._tokenCorreo();
        if (!mounted) return;
      }
      final completado =
          await widget.exportar(_porCorreo ? _correo.text.trim() : null);
      if (!mounted) return;
      Navigator.of(context).pop(completado
          ? (_porCorreo ? DestinoExcel.correo : DestinoExcel.dispositivo)
          : null);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _procesando = false;
        _error = error is StateError
            ? error.message.toString()
            : 'No se pudo exportar el Excel. Inténtalo nuevamente.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_procesando,
        child: AlertDialog(
          title: Text(
              _porCorreo ? 'Enviar a correo electrónico' : 'Exportar Excel'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_porCorreo)
                  Form(
                    key: _form,
                    child: TextFormField(
                      controller: _correo,
                      enabled: !_procesando,
                      autofocus: true,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.send,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Correo electrónico',
                        hintText: 'nombre@ejemplo.com',
                        border: OutlineInputBorder(),
                      ),
                      validator: (valor) =>
                          ExcelService.correoValido(valor?.trim() ?? '')
                              ? null
                              : 'Ingresa un correo electrónico válido.',
                      onFieldSubmitted: (_) => _exportar(),
                    ),
                  )
                else ...[
                  OutlinedButton.icon(
                    onPressed: _procesando ? null : _exportar,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Exportar al dispositivo'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _procesando
                        ? null
                        : () => setState(() {
                              _porCorreo = true;
                              _error = null;
                            }),
                    icon: const Icon(Icons.email_outlined),
                    label: const Text('Enviar a correo electrónico'),
                  ),
                ],
                if (_procesando) ...[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _procesando ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
            if (_porCorreo)
              FilledButton(
                onPressed: _procesando ? null : _exportar,
                child: Text(_procesando ? 'Enviando…' : 'Enviar'),
              ),
          ],
        ),
      );
}
