import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class PuertasExcelService {
  static String _texto(dynamic valor) => valor?.toString().trim() ?? '';

  static String _normalizarRut(dynamic valor) =>
      _texto(valor).replaceAll(RegExp(r'[.\s-]'), '').toUpperCase();

  /// Convierte las fechas UTC del servidor a la zona horaria del dispositivo.
  static DateTime? fechaLocal(dynamic valor) {
    if (valor is DateTime) return valor.toLocal();
    final texto = _texto(valor);
    final partes = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,]\d+)?)?([zZ]|[+-]\d{2}(?::?\d{2})?)?)?$',
    ).firstMatch(texto);
    if (partes == null) return null;
    final anio = int.parse(partes[1]!);
    final mes = int.parse(partes[2]!);
    final dia = int.parse(partes[3]!);
    final calendario = DateTime.utc(anio, mes, dia);
    if (calendario.year != anio ||
        calendario.month != mes ||
        calendario.day != dia ||
        int.parse(partes[4] ?? '0') > 23 ||
        int.parse(partes[5] ?? '0') > 59 ||
        int.parse(partes[6] ?? '0') > 59) {
      return null;
    }
    final zona = partes[7];
    if (zona != null && zona.toUpperCase() != 'Z') {
      final digitos = zona.substring(1).replaceAll(':', '');
      if (int.parse(digitos.substring(0, 2)) > 23 ||
          (digitos.length > 2 && int.parse(digitos.substring(2)) > 59)) {
        return null;
      }
    }
    final fecha = DateTime.tryParse(partes[4] == null
        ? '${texto}T00:00:00Z'
        : zona == null
            ? '${texto}Z'
            : texto);
    return fecha?.toLocal();
  }

  static Future<List<Map<String, dynamic>>> _consultarUsuarios(
      http.Client client) async {
    final prefs = await SharedPreferences.getInstance();
    final rut = _normalizarRut(prefs.getString('rut'));
    if (rut.isEmpty || prefs.getInt('es_admin') != 1) {
      throw StateError('No se encontró una sesión de conserjería activa.');
    }
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
        if (datos is! List || datos.any((usuario) => usuario is! Map)) {
          throw const FormatException('El listado de usuarios no es válido.');
        }
        return datos
            .map((usuario) => Map<String, dynamic>.from(usuario as Map))
            .toList();
      }),
    );
    return listas.expand((usuarios) => usuarios).toList();
  }

  static Uint8List generar(List<Map<String, dynamic>> registros,
      {List<Map<String, dynamic>> usuarios = const []}) {
    if (registros.isEmpty) {
      throw ArgumentError('No hay registros de puertas para exportar.');
    }
    final usuariosPorRut = <String, Map<String, dynamic>>{};
    for (final usuario in usuarios) {
      final rut = _normalizarRut(usuario['rut_usuario']);
      if (rut.isNotEmpty) usuariosPorRut[rut] = usuario;
    }
    final libro = Excel.createExcel();
    const nombreHoja = 'Registros de puertas';
    libro.rename('Sheet1', nombreHoja);
    final hoja = libro[nombreHoja];
    const columnas = [
      'ID del registro',
      'Departamento',
      'RUT del emisor',
      'Nombre del emisor',
      'Apellido paterno',
      'Apellido materno',
      'Puerta',
      'Título',
      'Descripción',
      'Fecha de creación',
      'Dispositivo',
      'RUT asociado actualmente',
      'Departamento asociado actualmente',
    ];
    const anchos = [
      18.0,
      18.0,
      22.0,
      30.0,
      24.0,
      24.0,
      14.0,
      36.0,
      70.0,
      26.0,
      26.0,
      28.0,
      34.0,
    ];
    hoja.appendRow(columnas.map((columna) => TextCellValue(columna)).toList());
    hoja.setRowHeight(0, 30);
    for (var col = 0; col < columnas.length; col++) {
      hoja.setColumnWidth(col, anchos[col]);
      hoja
          .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0))
          .cellStyle = CellStyle(
        bold: true,
        fontColorHex: ExcelColor.white,
        backgroundColorHex: ExcelColor.fromHexString('#5983B0'),
        textWrapping: TextWrapping.WrapText,
      );
    }

    for (final registro in registros) {
      final rut = _texto(registro['rut_emisor']);
      final emisor = usuariosPorRut[_normalizarRut(rut)];
      String datoEmisor(String campo) {
        final valor = _texto(emisor?[campo]);
        return valor.isEmpty ? 'No registrado' : valor;
      }

      final fecha = fechaLocal(registro['fecha_creacion']);
      final puerta = int.tryParse(_texto(registro['puerta']));
      // Los identificadores y textos se conservan como texto, sin fórmulas.
      // La asociación actual se exporta separada de la identidad registrada.
      hoja.appendRow([
        TextCellValue(_texto(registro['id'])),
        TextCellValue(_texto(registro['id_dpto'])),
        TextCellValue(rut.isEmpty ? 'No registrado' : rut),
        TextCellValue(datoEmisor('nombres')),
        TextCellValue(datoEmisor('apellido_1')),
        TextCellValue(datoEmisor('apellido_2')),
        puerta == null
            ? TextCellValue(_texto(registro['puerta']))
            : IntCellValue(puerta),
        TextCellValue(_texto(registro['titulo'])),
        TextCellValue(_texto(registro['descripcion'])),
        fecha == null ? null : DateTimeCellValue.fromDateTime(fecha),
        TextCellValue(_texto(registro['device_id'])),
        TextCellValue(_texto(registro['rut_asociado_actual'])),
        TextCellValue(_texto(registro['id_dpto_asociado_actual'])),
      ]);
      final fila = hoja.maxRows - 1;
      for (var col = 0; col < columnas.length; col++) {
        hoja
            .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: fila))
            .cellStyle = CellStyle(
          bold: true,
          fontColorHex: ExcelColor.white,
          backgroundColorHex: ExcelColor.fromHexString('#27476B'),
          verticalAlign: VerticalAlign.Top,
          textWrapping: TextWrapping.WrapText,
          numberFormat: col == 9
              ? NumFormat.custom(formatCode: 'dd/mm/yyyy hh:mm:ss')
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
  static Future<bool> exportar(List<Map<String, dynamic>> registros,
      {http.Client? client}) async {
    if (registros.isEmpty) {
      throw ArgumentError('No hay registros de puertas para exportar.');
    }
    var usuarios = <Map<String, dynamic>>[];
    final consulta = client ?? http.Client();
    try {
      usuarios = await _consultarUsuarios(consulta);
    } catch (_) {
      // Conservar los registros si el directorio no está disponible.
    } finally {
      if (client == null) consulta.close();
    }
    final bytes = generar(registros, usuarios: usuarios);
    final fecha = DateTime.now().toIso8601String().replaceAll(':', '-');
    final destino = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar registros de puertas en Excel',
      fileName: 'registros_puertas_$fecha.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      bytes: bytes,
    );
    return destino != null;
  }
}
