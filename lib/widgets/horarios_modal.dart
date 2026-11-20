import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

class HorariosModal extends StatefulWidget {
  final String miRut;
  final String nombreUsuario;
  final http.Client? client;

  const HorariosModal({
    super.key,
    required this.miRut,
    this.nombreUsuario = '',
    this.client,
  });

  @override
  State<HorariosModal> createState() => _HorariosModalState();
}

class _HorariosModalState extends State<HorariosModal> {
  static const _colorFondo = Color(0xFF111722);
  static const _colorTarjeta = Color(0xFF1B2535);
  static const _colorAcento = Color(0xFF2865E8);
  static const _colorTexto = Color(0xFFF2F5FC);
  static const _colorSecundario = Color(0xFFB6C3D9);
  static const _colorBorde = Color(0xFF39485E);
  static const _colorRegreso = Color(0xFF76DCC6);
  static const _etiquetaInicio = 'Salida';
  static const _etiquetaFin = 'Regreso';

  late final http.Client _client;
  DateTime? _fechaInicio;
  DateTime? _fechaFin;
  TimeOfDay? _horaInicio;
  TimeOfDay? _horaFin;
  List<Map<String, dynamic>> _horarios = [];
  bool _mostrarHistorial = false;
  String _filtroHistorial = 'Todos';
  bool _cargando = true;
  bool _guardando = false;
  int? _registrandoRegresoId;
  String? _errorCarga;
  String? _errorFormulario;

  DateTime? get _inicio => _combinar(_fechaInicio, _horaInicio);
  DateTime? get _fin => _combinar(_fechaFin, _horaFin);

  DateTime? _combinar(DateTime? fecha, TimeOfDay? hora) => fecha == null ||
          hora == null
      ? null
      : DateTime(fecha.year, fecha.month, fecha.day, hora.hour, hora.minute);

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
    final actual =
        (inicio ? _fechaInicio : _fechaFin) ?? _fechaInicio ?? DateTime.now();
    final etiqueta = inicio ? _etiquetaInicio : _etiquetaFin;
    final fecha = await showDatePicker(
      context: context,
      initialDate: actual,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      helpText: 'Fecha de ${etiqueta.toLowerCase()}',
      cancelText: 'Cancelar',
      confirmText: 'Seleccionar',
      builder: (context, child) => Theme(data: _tema(context), child: child!),
    );
    if (fecha == null || !mounted) return;
    setState(() {
      if (inicio) {
        _fechaInicio = fecha;
      } else {
        _fechaFin = fecha;
      }
      _errorFormulario = null;
    });
  }

  Future<void> _seleccionarHora({required bool inicio}) async {
    final etiqueta = inicio ? _etiquetaInicio : _etiquetaFin;
    final hora = await showTimePicker(
      context: context,
      initialTime:
          (inicio ? _horaInicio : _horaFin) ?? _horaInicio ?? TimeOfDay.now(),
      helpText: 'Hora de ${etiqueta.toLowerCase()}',
      cancelText: 'Cancelar',
      confirmText: 'Seleccionar',
      hourLabelText: 'Hora',
      minuteLabelText: 'Minuto',
      builder: (context, child) => Theme(
        data: _tema(context),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      ),
    );
    if (hora == null || !mounted) return;
    setState(() {
      if (inicio) {
        _horaInicio = hora;
      } else {
        _horaFin = hora;
      }
      _errorFormulario = null;
    });
  }

  Future<void> _guardar(ScrollController scrollController) async {
    if (_guardando || _cargando) return;
    final inicio = _inicio;
    final fin = _fin;
    if (inicio == null || fin == null) {
      _mostrarErrorFormulario(
          'Selecciona la fecha y hora de salida y de regreso.',
          scrollController);
      return;
    }
    if (!fin.isAfter(inicio)) {
      _mostrarErrorFormulario(
          'La fecha y hora de ${_etiquetaFin.toLowerCase()} debe ser posterior a la de ${_etiquetaInicio.toLowerCase()}.',
          scrollController);
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
        _fechaInicio = null;
        _fechaFin = null;
        _horaInicio = null;
        _horaFin = null;
        _mostrarHistorial = true;
        _filtroHistorial = 'Todos';
      });
      if (scrollController.hasClients) scrollController.jumpTo(0);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Horario registrado.')));
    } catch (error) {
      if (mounted) {
        _mostrarErrorFormulario(_mensajeError(error), scrollController);
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _registrarRegreso(Map<String, dynamic> horario) async {
    if (_guardando || _cargando) return;
    final id = horario['id'];
    final rut = widget.miRut.trim();
    if (id is! int || id <= 0 || rut.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No se pudo identificar el horario o el usuario.')));
      return;
    }
    setState(() {
      _guardando = true;
      _registrandoRegresoId = id;
    });
    try {
      final response = await _client
          .post(
            Uri.parse('$kBaseUrl/horarios/$id/regreso'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'rut': rut}),
          )
          .timeout(const Duration(seconds: 15));
      final data = _leerRespuesta(response);
      if (data is! Map || data['success'] != true || data['horario'] is! Map) {
        throw Exception('No se pudo confirmar el regreso.');
      }
      final actualizado = Map<String, dynamic>.from(data['horario'] as Map);
      if (actualizado['id'] != id || actualizado['estado'] != 'Finalizado') {
        throw Exception(
            'El servidor no confirmó la finalización de este horario.');
      }
      if (!mounted) return;
      setState(() {
        final indice = _horarios.indexWhere((item) => item['id'] == id);
        if (indice >= 0) _horarios[indice] = actualizado;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Regreso registrado. El horario ha finalizado.')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(_mensajeError(error))));
      }
    } finally {
      if (mounted) {
        setState(() {
          _guardando = false;
          _registrandoRegresoId = null;
        });
      }
    }
  }

  ThemeData _tema(BuildContext context) {
    final base = Theme.of(context);
    return base.copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: _colorAcento,
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFF9FC1FF),
        surface: _colorTarjeta,
        onSurface: _colorTexto,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: _colorTexto,
        displayColor: _colorTexto,
      ),
      iconTheme: const IconThemeData(color: _colorSecundario),
      dividerColor: _colorBorde,
    );
  }

  String _fechaFormateada(DateTime fecha) {
    const meses = [
      'ene',
      'feb',
      'mar',
      'abr',
      'may',
      'jun',
      'jul',
      'ago',
      'sep',
      'oct',
      'nov',
      'dic',
    ];
    return '${fecha.day} ${meses[fecha.month - 1]} ${fecha.year}';
  }

  String _horaFormateada(TimeOfDay hora) =>
      '${hora.hour.toString().padLeft(2, '0')}:'
      '${hora.minute.toString().padLeft(2, '0')}';

  DateTime? _fechaRegistro(dynamic valor) {
    final texto = valor?.toString().trim() ?? '';
    if (texto.isEmpty) return null;
    final tieneZona =
        RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(texto);
    return DateTime.tryParse(tieneZona ? texto : '${texto}Z')?.toLocal();
  }

  String _duracion(Duration duracion) {
    final dias = duracion.inDays;
    final horas = duracion.inHours.remainder(24);
    final minutos = duracion.inMinutes.remainder(60);
    return [
      if (dias > 0) '$dias ${dias == 1 ? 'día' : 'días'}',
      if (horas > 0) '$horas h',
      if (minutos > 0) '$minutos min',
      if (duracion.inMinutes == 0) 'Menos de 1 min',
    ].join(' · ');
  }

  String _estadoHorario(Map<String, dynamic> horario) {
    final inicio = _fechaRegistro(horario['fecha_inicio']);
    final fin = _fechaRegistro(horario['fecha_fin']);
    if (inicio == null || fin == null || !fin.isAfter(inicio)) {
      return 'Sin fecha';
    }
    if (horario['estado'] == 'Finalizado' ||
        _fechaRegistro(horario['fecha_regreso']) != null) {
      return 'Finalizado';
    }
    final ahora = DateTime.now();
    if (!fin.isAfter(ahora)) return 'Finalizado';
    return inicio.isAfter(ahora) ? 'Próximo' : 'En curso';
  }

  void _cambiarVista(bool historial, ScrollController controller) {
    if (_guardando || _mostrarHistorial == historial) return;
    if (controller.hasClients) controller.jumpTo(0);
    setState(() => _mostrarHistorial = historial);
  }

  void _mostrarErrorFormulario(String mensaje, ScrollController controller) {
    setState(() => _errorFormulario = mensaje);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _mostrarHistorial || !controller.hasClients) return;
      controller.animateTo(
        controller.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _tarjeta(Widget child) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _colorTarjeta,
          border: Border.all(color: _colorBorde),
          borderRadius: BorderRadius.circular(20),
        ),
        child: child,
      );

  Widget _aviso(String mensaje, {bool error = false}) => Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: error ? const Color(0xFF392831) : const Color(0xFF20334D),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(error ? Icons.error_outline : Icons.info_outline,
                  size: 20,
                  color: error ? const Color(0xFFFFB7B2) : _colorSecundario),
              const SizedBox(width: 10),
              Expanded(
                child: Text(mensaje,
                    style: TextStyle(
                        color: error ? const Color(0xFFFFCEC9) : _colorTexto,
                        height: 1.4)),
              ),
            ],
          ),
        ),
      );

  Widget _selector({
    required Key key,
    required String etiqueta,
    required String valor,
    required String ayuda,
    required IconData icono,
    required VoidCallback onPressed,
  }) =>
      Tooltip(
        message: ayuda,
        child: OutlinedButton(
          key: key,
          onPressed: _guardando ? null : onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: _colorTexto,
            disabledForegroundColor: _colorSecundario,
            side: const BorderSide(color: _colorBorde),
            padding: const EdgeInsets.all(14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(etiqueta,
                  style:
                      const TextStyle(color: _colorSecundario, fontSize: 12)),
              const SizedBox(height: 8),
              Row(children: [
                Icon(icono, size: 20, color: const Color(0xFF9FC1FF)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(valor,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ]),
            ],
          ),
        ),
      );

  Widget _campoFecha({required bool inicio}) {
    final etiqueta = inicio ? _etiquetaInicio : _etiquetaFin;
    final fecha = inicio ? _fechaInicio : _fechaFin;
    final hora = inicio ? _horaInicio : _horaFin;
    final color = inicio ? const Color(0xFF9FC1FF) : _colorRegreso;
    final selectorFecha = _selector(
      key: ValueKey(inicio ? 'horario-inicio' : 'horario-fin'),
      etiqueta: 'Fecha',
      valor: fecha == null ? 'Elegir fecha' : _fechaFormateada(fecha),
      ayuda: 'Seleccionar fecha de ${etiqueta.toLowerCase()}',
      icono: Icons.calendar_today_outlined,
      onPressed: () => _seleccionarFecha(inicio: inicio),
    );
    final selectorHora = _selector(
      key: ValueKey(inicio ? 'hora-inicio' : 'hora-fin'),
      etiqueta: 'Hora · 24 h',
      valor: hora == null ? 'Elegir' : _horaFormateada(hora),
      ayuda: 'Seleccionar hora de ${etiqueta.toLowerCase()}',
      icono: Icons.schedule_rounded,
      onPressed: () => _seleccionarHora(inicio: inicio),
    );
    return _tarjeta(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: inicio ? const Color(0xFF273E61) : const Color(0xFF203F3F),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(inicio ? Icons.logout_rounded : Icons.login_rounded,
                color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${inicio ? '1' : '2'}. $etiqueta',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              Text(inicio ? 'Cuándo sales' : 'Cuándo vuelves',
                  style:
                      const TextStyle(color: _colorSecundario, fontSize: 13)),
            ]),
          ),
          if (fecha != null && hora != null)
            Icon(Icons.check_circle_rounded, color: color, size: 22),
        ]),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, constraints) {
          final apilados = constraints.maxWidth < 280 ||
              MediaQuery.textScalerOf(context).scale(14) > 19;
          return apilados
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                      selectorFecha,
                      const SizedBox(height: 10),
                      selectorHora,
                    ])
              : Row(children: [
                  Expanded(flex: 3, child: selectorFecha),
                  const SizedBox(width: 10),
                  Expanded(flex: 2, child: selectorHora),
                ]);
        }),
      ],
    ));
  }

  List<Widget> _formulario() {
    final inicio = _inicio;
    final fin = _fin;
    return [
      Row(children: [
        const Expanded(
          child: Text('Nuevo horario',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        ),
        if (_fechaInicio != null ||
            _fechaFin != null ||
            _horaInicio != null ||
            _horaFin != null)
          TextButton(
            onPressed: _guardando
                ? null
                : () => setState(() {
                      _fechaInicio = null;
                      _fechaFin = null;
                      _horaInicio = null;
                      _horaFin = null;
                      _errorFormulario = null;
                    }),
            child: const Text('Limpiar'),
          ),
      ]),
      const SizedBox(height: 6),
      const Text('Indica cuándo sales y cuándo regresas.',
          style: TextStyle(color: _colorSecundario, height: 1.4)),
      const SizedBox(height: 20),
      _campoFecha(inicio: true),
      const SizedBox(height: 12),
      _campoFecha(inicio: false),
      const SizedBox(height: 16),
      if (inicio != null && fin != null && fin.isAfter(inicio))
        _aviso('Tiempo fuera: ${_duracion(fin.difference(inicio))}. '
            'Revisa las fechas antes de guardar.')
      else if (_errorFormulario == null)
        _aviso(
            inicio != null && fin != null
                ? 'El regreso debe ser posterior a la salida.'
                : 'Elige una fecha y una hora en cada tarjeta. Usa tu hora local.',
            error: inicio != null && fin != null),
      if (_errorFormulario != null) ...[
        const SizedBox(height: 12),
        _aviso(_errorFormulario!, error: true),
      ],
    ];
  }

  String _fechaHoraRegistro(DateTime? fecha) {
    if (fecha == null) return 'Fecha no disponible';
    final hora = _horaFormateada(TimeOfDay.fromDateTime(fecha));
    return '${_fechaFormateada(fecha)} · $hora';
  }

  String _normalizarRut(String rut) =>
      rut.replaceAll(RegExp(r'[.\s-]'), '').toUpperCase();

  Widget _lineaRegistro(String etiqueta, String valor, IconData icono) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 18, color: _colorSecundario),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(etiqueta,
                    style: const TextStyle(
                        color: _colorSecundario, fontSize: 12)),
                const SizedBox(height: 3),
                Text(valor,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      );

  Widget _registro(Map<String, dynamic> horario) {
    final departamento = horario['id_dpto']?.toString().trim() ?? '';
    final rutCreador = horario['rut_usuario']?.toString().trim() ?? '';
    final nombreUsuario = widget.nombreUsuario.trim();
    var creador = rutCreador.isEmpty ? 'No identificado' : 'RUT $rutCreador';
    if (rutCreador.isNotEmpty &&
        nombreUsuario.isNotEmpty &&
        _normalizarRut(rutCreador) == _normalizarRut(widget.miRut)) {
      creador = nombreUsuario;
    }
    final inicio = _fechaRegistro(horario['fecha_inicio']);
    final fin =
        _fechaRegistro(horario['fecha_regreso'] ?? horario['fecha_fin']);
    final estado = _estadoHorario(horario);
    final color = estado == 'En curso' ? _colorRegreso : _colorSecundario;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _tarjeta(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: const Color(0xFF263449),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(estado,
                      style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
                if (inicio != null && fin != null && fin.isAfter(inicio))
                  Text(_duracion(fin.difference(inicio)),
                      style: const TextStyle(
                          color: _colorSecundario, fontSize: 13)),
              ]),
          const SizedBox(height: 16),
          _lineaRegistro(
            'Departamento',
            departamento.isEmpty ? 'No registrado' : departamento,
            Icons.apartment_rounded,
          ),
          const SizedBox(height: 10),
          _lineaRegistro('Creado por', creador, Icons.person_outline_rounded),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: _colorBorde),
          ),
          _lineaRegistro(
              _etiquetaInicio, _fechaHoraRegistro(inicio), Icons.logout_rounded),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: _colorBorde),
          ),
          _lineaRegistro(
              _etiquetaFin, _fechaHoraRegistro(fin), Icons.login_rounded),
          if (estado == 'En curso') ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                key: ValueKey('registrar-regreso-${horario['id']}'),
                onPressed: _guardando || _cargando
                    ? null
                    : () => _registrarRegreso(horario),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _colorRegreso,
                  foregroundColor: _colorFondo,
                  minimumSize: const Size(0, 48),
                  elevation: 0,
                ),
                icon: _registrandoRegresoId == horario['id']
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login_rounded),
                label: Text(_registrandoRegresoId == horario['id']
                    ? 'Registrando regreso...'
                    : 'Registrar regreso'),
              ),
            ),
          ],
        ],
      )),
    );
  }

  Widget _pestana(String texto, bool historial, ScrollController controller) {
    final seleccionada = _mostrarHistorial == historial;
    return Expanded(
      child: Semantics(
        selected: seleccionada,
        child: TextButton(
          onPressed:
              _guardando ? null : () => _cambiarVista(historial, controller),
          style: TextButton.styleFrom(
            foregroundColor: seleccionada ? _colorTexto : _colorSecundario,
            backgroundColor:
                seleccionada ? const Color(0xFF2A4165) : Colors.transparent,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(texto,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _historial(ScrollController controller) {
    final visibles = _horarios.where((horario) {
      final estado = _estadoHorario(horario);
      return _filtroHistorial == 'Todos' ||
          (_filtroHistorial == 'Vigentes' &&
              (estado == 'Próximo' || estado == 'En curso')) ||
          (_filtroHistorial == 'Finalizados' && estado == 'Finalizado');
    }).toList();
    return CustomScrollView(
      key: const ValueKey('historial-horarios'),
      controller: controller,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          sliver: SliverToBoxAdapter(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Tus horarios',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text('Consulta tus salidas y regresos registrados.',
                      style: TextStyle(color: _colorSecundario, height: 1.4)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final filtro in ['Todos', 'Vigentes', 'Finalizados'])
                      ChoiceChip(
                        label: Text(filtro),
                        selected: _filtroHistorial == filtro,
                        onSelected: (_) =>
                            setState(() => _filtroHistorial = filtro),
                        selectedColor: const Color(0xFF2A4165),
                        backgroundColor: _colorTarjeta,
                        labelStyle: const TextStyle(color: _colorTexto),
                        side: const BorderSide(color: _colorBorde),
                      ),
                  ]),
                  if (_filtroHistorial == 'Vigentes') ...[
                    const SizedBox(height: 8),
                    const Text(
                        'Incluye próximos horarios y los que están en curso.',
                        style:
                            TextStyle(color: _colorSecundario, fontSize: 13)),
                  ],
                  if (_cargando) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(
                        color: _colorAcento,
                        semanticsLabel: 'Cargando horarios'),
                  ],
                  if (_errorCarga != null) ...[
                    const SizedBox(height: 16),
                    _aviso(_errorCarga!, error: true),
                    TextButton.icon(
                      onPressed: _cargando || _guardando ? null : _cargar,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Reintentar'),
                    ),
                  ],
                  if (!_cargando &&
                      _errorCarga == null &&
                      visibles.isEmpty) ...[
                    const SizedBox(height: 24),
                    _tarjeta(Column(children: [
                      const Icon(Icons.event_note_rounded,
                          size: 40, color: _colorSecundario),
                      const SizedBox(height: 14),
                      Text(
                          _horarios.isEmpty
                              ? 'Aún no tienes horarios'
                              : 'Sin horarios en esta categoría',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      const Text('Los horarios que guardes aparecerán aquí.',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: _colorSecundario, height: 1.4)),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: () => _cambiarVista(false, controller),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Registrar horario'),
                      ),
                    ])),
                  ],
                ]),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, index) => _registro(visibles[index]),
              childCount: visibles.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _encabezado(ScrollController controller, {required bool compacto}) {
    final acciones = [
      IconButton(
        tooltip: 'Actualizar horarios',
        onPressed: _cargando || _guardando ? null : _cargar,
        icon: const Icon(Icons.refresh_rounded),
      ),
      IconButton(
        tooltip: 'Cerrar horarios',
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close_rounded),
      ),
    ];
    final navegacion = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _colorTarjeta,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        _pestana('Registrar', false, controller),
        const SizedBox(width: 4),
        _pestana(_cargando ? 'Historial' : 'Historial (${_horarios.length})',
            true, controller),
      ]),
    );
    return Padding(
      padding: compacto
          ? const EdgeInsets.all(8)
          : const EdgeInsets.fromLTRB(20, 10, 20, 16),
      child: compacto
          ? Row(children: [Expanded(child: navegacion), ...acciones])
          : Column(children: [
              ExcludeSemantics(
                  child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: _colorBorde, borderRadius: BorderRadius.circular(4)),
              )),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: Semantics(
                  header: true,
                  child: const Text('Horarios',
                      style:
                          TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                )),
                ...acciones,
              ]),
              const SizedBox(height: 12),
              navegacion,
            ]),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
        data: _tema(context),
        child: LayoutBuilder(builder: (context, constraints) {
          final necesitaAltura = constraints.maxHeight < 600 ||
              MediaQuery.textScalerOf(context).scale(16) > 22;
          return DraggableScrollableSheet(
            initialChildSize: necesitaAltura ? 0.96 : 0.88,
            minChildSize: necesitaAltura ? 0.96 : 0.6,
            maxChildSize: 0.96,
            expand: false,
            builder: (_, scrollController) => Material(
              color: _colorFondo,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
              clipBehavior: Clip.antiAlias,
              child: SafeArea(
                top: false,
                child: Column(children: [
                  _encabezado(scrollController,
                      compacto: constraints.maxHeight < 480),
                  Expanded(
                    child: _mostrarHistorial
                        ? _historial(scrollController)
                        : ListView(
                            key: const ValueKey('formulario-horarios'),
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                            children: [
                              if (_errorCarga != null) ...[
                                _aviso(_errorCarga!, error: true),
                                TextButton.icon(
                                  onPressed:
                                      _cargando || _guardando ? null : _cargar,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('Reintentar'),
                                ),
                                const SizedBox(height: 8),
                              ],
                              ..._formulario(),
                            ],
                          ),
                  ),
                  if (!_mostrarHistorial)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      decoration: const BoxDecoration(
                        color: _colorFondo,
                        border: Border(top: BorderSide(color: _colorBorde)),
                      ),
                      child: ElevatedButton.icon(
                        key: const ValueKey('guardar-horario'),
                        onPressed: _guardando || _cargando
                            ? null
                            : () => _guardar(scrollController),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _colorAcento,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: _colorTarjeta,
                          disabledForegroundColor: _colorSecundario,
                          minimumSize: const Size(0, 52),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: _guardando
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.check_rounded),
                        label: Text(
                            _guardando
                                ? 'Guardando...'
                                : _cargando
                                    ? 'Cargando horarios...'
                                    : 'Guardar horario',
                            textAlign: TextAlign.center,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                ]),
              ),
            ),
          );
        }),
      );
}
