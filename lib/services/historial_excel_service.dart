import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class HistorialExcelService {
  static const _nombreHoja = 'Historial de llamadas';
  static const _noDisponible = 'No disponible';

  static String _texto(dynamic valor) => valor?.toString().trim() ?? '';

  static String _normalizarRut(dynamic valor) => _texto(valor)
      .replaceAll('.', '')
      .replaceAll('-', '')
      .toUpperCase()
      .replaceAll('Ó', 'O');

  static String _normalizarNombre(String nombre) =>
      nombre.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  static String _nombreUsuario(Map<String, dynamic> usuario) {
    // El historial utiliza nombres y primer apellido, sin apellido materno.
    final nombre = [usuario['nombres'], usuario['apellido_1']]
        .map(_texto)
        .where((parte) => parte.isNotEmpty)
        .join(' ');
    return nombre.isEmpty ? _texto(usuario['rut_usuario']) : nombre;
  }

  static Future<List<Map<String, dynamic>>> _consultarUsuarios(
      http.Client client, String rut) async {
    // Para una sesión de conserjería estas dos rutas cubren todos los usuarios.
    // Deben estar disponibles ambas listas para detectar nombres repetidos.
    final listas = await Future.wait(
      ['/usuarios-todos', '/usuarios-conserjes'].map((ruta) async {
        final uri =
            Uri.parse('$kBaseUrl$ruta').replace(queryParameters: {'rut': rut});
        final respuesta =
            await client.get(uri).timeout(const Duration(seconds: 15));
        if (respuesta.statusCode != 200) {
          throw StateError('No se pudo consultar el listado de usuarios.');
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
    final esConserje = listas[1].any((usuario) =>
        _normalizarRut(usuario['rut_usuario']) == _normalizarRut(rut) &&
        (usuario['es_admin'] == true || usuario['es_admin'] == 1));
    if (!esConserje) {
      // Las preferencias pueden conservar un rol que cambió en el servidor.
      throw StateError('No se pudo confirmar el directorio completo.');
    }
    return listas.expand((usuarios) => usuarios).toList();
  }

  /// Consulta nombres por RUT sin cerrar el cliente que recibe.
  static Future<Map<String, String>> consultarNombresParticipantes(
      http.Client client, String miRut) async {
    final usuarios = await _consultarUsuarios(client, _normalizarRut(miRut));
    final nombres = <String, String>{};
    for (final usuario in usuarios) {
      final rut = _normalizarRut(usuario['rut_usuario']);
      final nombre = _nombreUsuario(usuario);
      if (rut.isNotEmpty && nombre.isNotEmpty) nombres[rut] = nombre;
    }
    return nombres;
  }

  /// Mantiene separados los participantes cuando el historial es de terceros.
  static ({String emisor, String receptor}) resolverParticipantes(
    Map<String, dynamic> llamada, {
    String miRut = '',
    Map<String, String> nombresPorRut = const {},
  }) {
    final tipo = _normalizarNombre(_texto(llamada['tipo']));
    final saliente = tipo == 'saliente' || tipo.startsWith('saliente ');
    final entrante = tipo == 'entrante' || tipo.startsWith('entrante ');
    final contacto = _texto(llamada['nombre']);

    String resolverNombre(
      String campoNombre,
      String campoRut, {
      required bool esContacto,
      String rutAlternativo = '',
    }) {
      final nombreExplicito = _texto(llamada[campoNombre]);
      if (nombreExplicito.isNotEmpty) return nombreExplicito;
      var rut = _texto(llamada[campoRut]);
      if (rut.isEmpty) rut = _texto(rutAlternativo);
      if (rut.isNotEmpty) {
        final nombre = _texto(nombresPorRut[_normalizarRut(rut)]);
        if (nombre.isNotEmpty) return nombre;
        if (esContacto && contacto.isNotEmpty) return contacto;
        return rut;
      }
      if (esContacto && contacto.isNotEmpty) return contacto;
      return _noDisponible;
    }

    return (
      emisor: resolverNombre(
        'nombre_emisor',
        'rut_emisor',
        esContacto: entrante,
        rutAlternativo: saliente ? miRut : '',
      ),
      receptor: resolverNombre(
        'nombre_receptor',
        'rut_receptor',
        esContacto: saliente,
      ),
    );
  }

  /// Convierte la fecha UTC del servidor a la zona horaria del dispositivo.
  static DateTime? fechaLocal(dynamic valor, {DateTime? ahoraUtc}) {
    final texto = _texto(valor);
    final corta =
        RegExp(r'^(\d{2})/(\d{2})\s+(\d{2}):(\d{2})$').firstMatch(texto);
    if (corta != null) {
      final dia = int.parse(corta[1]!);
      final mes = int.parse(corta[2]!);
      final hora = int.parse(corta[3]!);
      final minuto = int.parse(corta[4]!);
      if (mes < 1 ||
          mes > 12 ||
          dia < 1 ||
          dia > 31 ||
          hora > 23 ||
          minuto > 59) {
        return null;
      }
      // /historial omite el año. Su retención de 30 días permite inferir
      // la fecha reciente, también al consultar diciembre desde enero.
      final ahora = (ahoraUtc ?? DateTime.now()).toUtc();
      final limite = ahora.add(const Duration(minutes: 5));
      for (final anio in [ahora.year + 1, ahora.year, ahora.year - 1]) {
        final utc = DateTime.utc(anio, mes, dia, hora, minuto);
        // DateTime normaliza fechas imposibles; no deben convertirse.
        if (utc.month == mes && utc.day == dia && !utc.isAfter(limite)) {
          return utc.toLocal();
        }
      }
      return null;
    }

    // También admite una fecha ISO completa si el servidor la entrega.
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}.*)?$')
        .hasMatch(texto)) {
      return null;
    }
    final tieneHora = RegExp(r'[Tt ]\d{2}:\d{2}').hasMatch(texto);
    final tieneZona =
        tieneHora && RegExp(r'(?:[zZ]|[+-]\d{2}(?::?\d{2})?)$').hasMatch(texto);
    final utc = DateTime.tryParse(
        tieneHora ? (tieneZona ? texto : '${texto}Z') : '${texto}T00:00:00Z');
    return utc?.toLocal();
  }

  /// Conserva el formato del historial sin mostrar el año inferido.
  static String formatearFechaLocal(dynamic valor, {DateTime? ahoraUtc}) {
    final local = fechaLocal(valor, ahoraUtc: ahoraUtc);
    if (local == null) return _texto(valor);
    String dos(int numero) => numero.toString().padLeft(2, '0');
    return '${dos(local.day)}/${dos(local.month)} '
        '${dos(local.hour)}:${dos(local.minute)}';
  }

  static int? _duracionSegundos(dynamic valor) {
    final segundos =
        valor is int ? valor : int.tryParse(valor?.toString().trim() ?? '');
    return segundos != null && segundos >= 0 ? segundos : null;
  }

  /// Muestra solo segundos, minutos y segundos, u horas, minutos y segundos.
  static String formatearDuracion(dynamic valor) {
    final total = _duracionSegundos(valor);
    if (total == null) return _noDisponible;
    if (total < 60) return '$total s';

    final horas = total ~/ 3600;
    final minutos = (total % 3600) ~/ 60;
    final segundos = total % 60;
    if (horas == 0) return '$minutos min $segundos s';
    return '$horas h $minutos min $segundos s';
  }

  /// [usuarios] debe incluir el directorio completo para resolver nombres únicos.
  static Uint8List generar(List<Map<String, dynamic>> historial,
      {List<Map<String, dynamic>> usuarios = const []}) {
    if (historial.isEmpty) {
      throw ArgumentError('No hay llamadas para exportar.');
    }

    final usuariosPorRut = <String, Map<String, dynamic>>{};
    for (final usuario in usuarios) {
      final rut = _normalizarRut(usuario['rut_usuario']);
      if (rut.isNotEmpty) usuariosPorRut[rut] = usuario;
    }
    final usuariosPorNombre = <String, List<Map<String, dynamic>>>{};
    for (final usuario in usuariosPorRut.values) {
      final nombre = _normalizarNombre(_nombreUsuario(usuario));
      if (nombre.isNotEmpty) {
        usuariosPorNombre.putIfAbsent(nombre, () => []).add(usuario);
      }
    }

    Map<String, dynamic>? buscarUsuarioPorNombre(String nombre) {
      final nombreNormalizado = _normalizarNombre(nombre);
      // Esta etiqueta puede representar varios dispositivos distintos.
      if (nombreNormalizado.isEmpty ||
          nombreNormalizado == 'citófono' ||
          nombreNormalizado == 'citofono') {
        return null;
      }
      final usuarioPorRut = usuariosPorRut[_normalizarRut(nombre)];
      if (usuarioPorRut != null) return usuarioPorRut;
      final coincidencias = usuariosPorNombre[nombreNormalizado];
      return coincidencias?.length == 1 ? coincidencias!.single : null;
    }

    final nombresPorRut = {
      for (final usuario in usuariosPorRut.entries)
        usuario.key: _nombreUsuario(usuario.value),
    };

    final libro = Excel.createExcel();
    libro.rename('Sheet1', _nombreHoja);
    final hoja = libro[_nombreHoja];
    const columnas = [
      'ID de llamada',
      'Departamento',
      'Contacto',
      'Receptor',
      'Fecha',
      'Tipo de llamada',
      'Estado',
      'Duración',
    ];
    const anchos = [18.0, 18.0, 36.0, 36.0, 24.0, 26.0, 18.0, 24.0];
    hoja.appendRow(columnas.map((columna) => TextCellValue(columna)).toList());
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

    for (final llamada in historial) {
      String texto(String campo) => _texto(llamada[campo]);
      CellValue? textoOpcional(String campo) {
        final valor = texto(campo);
        return valor.isEmpty ? null : TextCellValue(valor);
      }

      final tipo = _normalizarNombre(texto('tipo'));
      final saliente = tipo == 'saliente' || tipo.startsWith('saliente ');
      final entrante = tipo == 'entrante' || tipo.startsWith('entrante ');
      var rutContacto = texto('rut_contacto');
      if (rutContacto.isEmpty) {
        rutContacto = saliente
            ? texto('rut_receptor')
            : entrante
                ? texto('rut_emisor')
                : '';
      }
      var contacto = usuariosPorRut[_normalizarRut(rutContacto)];
      var nombre = texto('nombre');
      if (contacto == null && rutContacto.isEmpty && nombre.isNotEmpty) {
        contacto = buscarUsuarioPorNombre(nombre);
      }
      if (nombre.isEmpty && contacto != null) nombre = _nombreUsuario(contacto);
      if (nombre.isEmpty) nombre = rutContacto;

      var departamento = texto('id_dpto_emisor');
      if (departamento.isEmpty) {
        final rutEmisor = _normalizarRut(texto('rut_emisor'));
        var emisor = usuariosPorRut[rutEmisor];
        if (rutEmisor.isEmpty && entrante) {
          // En registros antiguos entrantes, el contacto identifica al emisor.
          final nombreEmisor = texto('nombre_emisor');
          emisor = buscarUsuarioPorNombre(
              nombreEmisor.isEmpty ? texto('nombre') : nombreEmisor);
        }
        // En llamadas salientes el contacto es el receptor, no el emisor.
        departamento = _texto(emisor?['id_dpto']);
      }
      final receptor = resolverParticipantes(
        {...llamada, 'nombre': nombre},
        nombresPorRut: nombresPorRut,
      ).receptor;

      final estado = texto('estado');
      final estadoNormalizado = estado.toLowerCase();
      final etiquetaEstado = estado.isEmpty
          ? 'No registrado'
          : '${estadoNormalizado[0].toUpperCase()}${estadoNormalizado.substring(1)}';
      final duracion = _duracionSegundos(llamada['duracion_segundos']);

      final fecha = formatearFechaLocal(llamada['fecha']);
      // Modal y Excel utilizan la misma conversión a hora local.
      // TextCellValue conserva el formato dd/MM HH:mm y evita fórmulas.
      hoja.appendRow([
        textoOpcional('id'),
        TextCellValue(departamento.isEmpty ? _noDisponible : departamento),
        TextCellValue(nombre.isEmpty ? 'Usuario desconocido' : nombre),
        TextCellValue(receptor.isEmpty ? _noDisponible : receptor),
        fecha.isEmpty ? null : TextCellValue(fecha),
        textoOpcional('tipo'),
        TextCellValue(etiquetaEstado),
        duracion == null ? null : TextCellValue(formatearDuracion(duracion)),
      ]);

      final color = switch (estadoNormalizado) {
        'finalizada' => '#3FAF46',
        'ocupado' => '#FFB142',
        'perdida' || 'rechazada' => '#C9211E',
        _ => '#666666',
      };
      final fila = hoja.maxRows - 1;
      for (var col = 0; col < columnas.length; col++) {
        hoja
            .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: fila))
            .cellStyle = CellStyle(
          bold: true,
          fontColorHex: ExcelColor.white,
          backgroundColorHex: ExcelColor.fromHexString(color),
          verticalAlign: VerticalAlign.Top,
          textWrapping: TextWrapping.WrapText,
          numberFormat: NumFormat.standard_0,
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
  static Future<bool> exportar(List<Map<String, dynamic>> historial,
      {http.Client? client}) async {
    if (historial.isEmpty) {
      throw ArgumentError('No hay llamadas para exportar.');
    }
    var usuarios = <Map<String, dynamic>>[];
    final necesitaUsuarios = historial.any((llamada) =>
        _texto(llamada['id_dpto_emisor']).isEmpty ||
        (_texto(llamada['nombre_receptor']).isEmpty &&
            _texto(llamada['rut_receptor']).isNotEmpty));
    if (necesitaUsuarios) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final rut = _normalizarRut(prefs.getString('rut'));
        if (rut.isNotEmpty && prefs.getInt('es_admin') == 1) {
          final consulta = client ?? http.Client();
          try {
            usuarios = await _consultarUsuarios(consulta, rut);
          } finally {
            if (client == null) consulta.close();
          }
        }
      } catch (_) {
        // Si no hay un directorio completo, se conservan los datos recibidos.
        // Los campos que no se pueden resolver se indican como no disponibles.
      }
    }
    final bytes = generar(historial, usuarios: usuarios);
    final fecha = DateTime.now().toIso8601String().replaceAll(':', '-');
    final destino = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar historial de llamadas en Excel',
      fileName: 'historial_llamadas_$fecha.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      bytes: bytes,
    );
    return destino != null;
  }
}
