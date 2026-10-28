import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class RecadosExcelService {
  static String _normalizarRut(dynamic valor) => (valor?.toString() ?? '')
      .replaceAll('.', '')
      .replaceAll('-', '')
      .trim()
      .toUpperCase();

  static Future<List<Map<String, dynamic>>> _consultarUsuarios(
      http.Client client) async {
    final prefs = await SharedPreferences.getInstance();
    final rut = _normalizarRut(prefs.getString('rut'));
    if (rut.isEmpty || prefs.getInt('es_admin') != 1) {
      throw StateError('No se encontró una sesión de conserjería activa.');
    }
    // Ambas consultas existentes cubren residentes y conserjes.
    final listas = await Future.wait(
      ['/usuarios-todos', '/usuarios-conserjes'].map((ruta) async {
        final uri =
            Uri.parse('$kBaseUrl$ruta').replace(queryParameters: {'rut': rut});
        final respuesta =
            await client.get(uri).timeout(const Duration(seconds: 15));
        if (respuesta.statusCode != 200) {
          throw StateError(
              'No se pudieron consultar los nombres de los emisores.');
        }
        final datos = jsonDecode(utf8.decode(respuesta.bodyBytes));
        if (datos is! List || datos.any((u) => u is! Map)) {
          throw const FormatException('El listado de usuarios no es válido.');
        }
        return datos.map((u) => Map<String, dynamic>.from(u as Map)).toList();
      }),
    );
    return listas.expand((usuarios) => usuarios).toList();
  }

  static DateTime? fechaLocal(dynamic valor) {
    final parsed = DateTime.tryParse(valor?.toString() ?? '');
    if (parsed == null) return null;
    // El servidor devuelve fechas UTC sin sufijo de zona horaria.
    return (parsed.isUtc
            ? parsed
            : DateTime.utc(
                parsed.year,
                parsed.month,
                parsed.day,
                parsed.hour,
                parsed.minute,
                parsed.second,
                parsed.millisecond,
                parsed.microsecond))
        .toLocal();
  }

  static Uint8List generar(List<Map<String, dynamic>> recados,
      {List<Map<String, dynamic>> usuarios = const [],
      bool mostrarComoMensajes = false}) {
    final nombreListado = mostrarComoMensajes ? 'mensajes' : 'recados';
    if (recados.isEmpty) {
      throw ArgumentError('No hay $nombreListado para exportar.');
    }
    final usuariosPorRut = <String, Map<String, dynamic>>{};
    for (final usuario in usuarios) {
      final rut = _normalizarRut(usuario['rut_usuario']);
      if (rut.isNotEmpty) usuariosPorRut[rut] = usuario;
    }
    final libro = Excel.createExcel();
    final nombreHoja = mostrarComoMensajes ? 'Mensajes' : 'Recados';
    libro.rename('Sheet1', nombreHoja);
    final hoja = libro[nombreHoja];
    const columnas = [
      'Departamento',
      'RUT del emisor',
      'Nombre del emisor',
      'Apellido paterno',
      'Apellido materno',
      'Título',
      'Descripción',
      'Estado',
      'Fecha de creación',
      'Fecha de resolución',
    ];
    hoja.appendRow(columnas.map((s) => TextCellValue(s)).toList());
    const anchos = [18.0, 22.0, 30.0, 24.0, 24.0, 36.0, 70.0, 16.0, 24.0, 24.0];
    for (var col = 0; col < columnas.length; col++) {
      hoja.setColumnWidth(col, anchos[col]);
      hoja
          .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0))
          .cellStyle = CellStyle(
        bold: true,
        fontColorHex: ExcelColor.white,
        backgroundColorHex: ExcelColor.fromHexString('#5983B0'),
      );
    }
    hoja.setRowHeight(0, 26);
    CellValue? fecha(dynamic valor) {
      final local = fechaLocal(valor);
      return local == null ? null : DateTimeCellValue.fromDateTime(local);
    }

    for (final recado in recados) {
      final rutEmisor = recado['rut_emisor']?.toString().trim() ?? '';
      final emisor = usuariosPorRut[_normalizarRut(rutEmisor)];
      String datoEmisor(String campo) {
        final valor = emisor?[campo]?.toString().trim() ?? '';
        return valor.isEmpty ? 'No registrado' : valor;
      }

      // TextCellValue conserva identificadores y evita interpretar fórmulas.
      hoja.appendRow([
        TextCellValue(recado['id_dpto']?.toString() ?? ''),
        TextCellValue(rutEmisor.isEmpty ? 'No registrado' : rutEmisor),
        TextCellValue(datoEmisor('nombres')),
        TextCellValue(datoEmisor('apellido_1')),
        TextCellValue(datoEmisor('apellido_2')),
        TextCellValue(recado['titulo']?.toString() ?? ''),
        TextCellValue(recado['descripcion']?.toString() ?? ''),
        TextCellValue(switch (recado['estado']) {
          'pendiente' => 'Pendiente',
          'resuelto' => 'Resuelto',
          final valor => valor?.toString() ?? '',
        }),
        fecha(recado['fecha_creacion']),
        fecha(recado['fecha_resolucion']),
      ]);
      final fila = hoja.maxRows - 1;
      for (var col = 0; col < columnas.length; col++) {
        hoja
            .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: fila))
            .cellStyle = CellStyle(
          bold: true,
          fontColorHex: ExcelColor.white,
          backgroundColorHex: ExcelColor.fromHexString(
              recado['estado'] == 'resuelto' ? '#3FAF46' : '#C9211E'),
          verticalAlign: VerticalAlign.Top,
          textWrapping: TextWrapping.WrapText,
          numberFormat: col >= 8
              ? NumFormat.custom(formatCode: 'dd/mm/yyyy hh:mm')
              : NumFormat.standard_0,
        );
      }
    }
    final bytes = libro.encode();
    if (bytes == null || bytes.isEmpty) {
      throw StateError('No se pudo generar el archivo Excel.');
    }
    return Uint8List.fromList(bytes);
  }

  /// Devuelve false si el usuario cancela el selector de guardado.
  static Future<bool> exportar(List<Map<String, dynamic>> recados,
      {required bool resueltos,
      http.Client? client,
      bool mostrarComoMensajes = false}) async {
    final nombreListado = mostrarComoMensajes ? 'mensajes' : 'recados';
    if (recados.isEmpty) {
      throw ArgumentError('No hay $nombreListado para exportar.');
    }
    final consulta = client ?? http.Client();
    final List<Map<String, dynamic>> usuarios;
    try {
      usuarios = await _consultarUsuarios(consulta);
    } finally {
      if (client == null) consulta.close();
    }
    final bytes = generar(recados,
        usuarios: usuarios, mostrarComoMensajes: mostrarComoMensajes);
    final fecha = DateTime.now().toIso8601String().replaceAll(':', '-');
    final nombre =
        '${nombreListado}_${resueltos ? 'resueltos' : 'pendientes'}_$fecha.xlsx';
    final destino = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar $nombreListado en Excel',
      fileName: nombre,
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      bytes: bytes,
    );
    if (destino == null) return false;
    return true;
  }
}
