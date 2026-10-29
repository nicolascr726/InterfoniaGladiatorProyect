import 'package:flutter/material.dart';

@immutable
class FiltroFechaHora {
  final DateTime? desde;
  final DateTime? hasta;

  const FiltroFechaHora({this.desde, this.hasta});

  bool get activo => desde != null || hasta != null;

  bool incluye(DateTime? fecha) {
    if (!activo) return true;
    if (fecha == null) return false;
    if (desde != null && fecha.isBefore(desde!)) return false;
    // La hora elegida incluye todos los segundos de ese minuto.
    if (hasta != null &&
        !fecha.isBefore(hasta!.add(const Duration(minutes: 1)))) {
      return false;
    }
    return true;
  }

  String get resumen => [
        if (desde != null) 'Desde ${_fechaHora(desde!)}',
        if (hasta != null) 'Hasta ${_fechaHora(hasta!)}',
      ].join(' · ');
}

String _dos(int numero) => numero.toString().padLeft(2, '0');

String _fecha(DateTime fecha) =>
    '${_dos(fecha.day)}/${_dos(fecha.month)}/${fecha.year}';

String _hora(DateTime fecha) => '${_dos(fecha.hour)}:${_dos(fecha.minute)}';

String _fechaHora(DateTime fecha) => '${_fecha(fecha)} ${_hora(fecha)}';

ThemeData _temaFiltro(BuildContext context) => Theme.of(context).copyWith(
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF20CDFF),
        surface: Color(0xFF1E293B),
      ),
      textTheme: ThemeData.dark().textTheme,
    );

class FiltroFechaHoraButton extends StatelessWidget {
  final FiltroFechaHora filtro;
  final ValueChanged<FiltroFechaHora> onChanged;
  final bool enabled;
  final bool mostrarResumen;

  const FiltroFechaHoraButton({
    super.key,
    required this.filtro,
    required this.onChanged,
    this.enabled = true,
    this.mostrarResumen = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF20CDFF),
            disabledForegroundColor: Colors.white38,
            backgroundColor: filtro.activo ? const Color(0xFF153344) : null,
            minimumSize: const Size(0, 56),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          onPressed: !enabled
              ? null
              : () async {
                  final seleccionado = await showDialog<FiltroFechaHora>(
                    context: context,
                    builder: (context) => Theme(
                      data: _temaFiltro(context),
                      child: _FiltroFechaHoraDialog(inicial: filtro),
                    ),
                  );
                  if (seleccionado != null && context.mounted) {
                    onChanged(seleccionado);
                  }
                },
          icon: Icon(
            filtro.activo ? Icons.filter_alt : Icons.filter_alt_outlined,
            size: 20,
          ),
          label: const Text('Filtrar', textAlign: TextAlign.center),
        ),
        if (mostrarResumen && filtro.activo)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              filtro.resumen,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _FiltroFechaHoraDialog extends StatefulWidget {
  final FiltroFechaHora inicial;

  const _FiltroFechaHoraDialog({required this.inicial});

  @override
  State<_FiltroFechaHoraDialog> createState() => _FiltroFechaHoraDialogState();
}

class _FiltroFechaHoraDialogState extends State<_FiltroFechaHoraDialog> {
  DateTime? _desde;
  DateTime? _hasta;
  String? _error;

  @override
  void initState() {
    super.initState();
    _desde = widget.inicial.desde;
    _hasta = widget.inicial.hasta;
  }

  Future<void> _elegirFecha({required bool desde}) async {
    final actual = desde ? _desde : _hasta;
    final alternativa = desde ? _hasta : _desde;
    final inicial = actual ?? alternativa ?? DateTime.now();
    final fecha = await showDatePicker(
      context: context,
      initialDate: inicial,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
      helpText: desde ? 'Fecha desde' : 'Fecha hasta',
      cancelText: 'Cancelar',
      confirmText: 'Aceptar',
      builder: (context, child) => Theme(
        data: _temaFiltro(context),
        child: child!,
      ),
    );
    if (fecha == null || !mounted) return;
    final nueva = DateTime(
      fecha.year,
      fecha.month,
      fecha.day,
      actual?.hour ?? (desde ? 0 : 23),
      actual?.minute ?? (desde ? 0 : 59),
    );
    setState(() {
      if (desde) {
        _desde = nueva;
      } else {
        _hasta = nueva;
      }
      _error = null;
    });
  }

  Future<void> _elegirHora({required bool desde}) async {
    final actual = desde ? _desde : _hasta;
    if (actual == null) return;
    final hora = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(actual),
      helpText: desde ? 'Hora desde' : 'Hora hasta',
      cancelText: 'Cancelar',
      confirmText: 'Aceptar',
      builder: (context, child) => Theme(
        data: _temaFiltro(context),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      ),
    );
    if (hora == null || !mounted) return;
    final nueva =
        DateTime(actual.year, actual.month, actual.day, hora.hour, hora.minute);
    setState(() {
      if (desde) {
        _desde = nueva;
      } else {
        _hasta = nueva;
      }
      _error = null;
    });
  }

  Widget _limite({required bool desde}) {
    final valor = desde ? _desde : _hasta;
    final nombre = desde ? 'Desde' : 'Hasta';
    final id = desde ? 'desde' : 'hasta';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(nombre,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (valor != null)
              IconButton(
                key: ValueKey('limpiar_$id'),
                tooltip: 'Quitar límite $nombre',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  if (desde) {
                    _desde = null;
                  } else {
                    _hasta = null;
                  }
                  _error = null;
                }),
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
        OutlinedButton.icon(
          key: ValueKey('fecha_$id'),
          onPressed: () => _elegirFecha(desde: desde),
          icon: const Icon(Icons.calendar_today_outlined, size: 18),
          label: Text(valor == null ? 'Seleccionar fecha' : _fecha(valor)),
        ),
        OutlinedButton.icon(
          key: ValueKey('hora_$id'),
          onPressed: valor == null ? null : () => _elegirHora(desde: desde),
          icon: const Icon(Icons.schedule, size: 18),
          label: Text(valor == null ? 'Seleccionar hora' : _hora(valor)),
        ),
      ],
    );
  }

  void _aplicar() {
    if (_desde != null && _hasta != null && _hasta!.isBefore(_desde!)) {
      setState(() => _error =
          'La fecha y hora hasta deben ser posteriores o iguales a desde.');
      return;
    }
    Navigator.of(context).pop(FiltroFechaHora(desde: _desde, hasta: _hasta));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('Filtrar por fecha y hora'),
      scrollable: true,
      content: SizedBox(
        width: 320,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Selecciona un límite o ambos para definir el rango.',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 16),
            _limite(desde: true),
            const SizedBox(height: 12),
            _limite(desde: false),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child:
                    Text(_error!, style: const TextStyle(color: Colors.orange)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('limpiar_filtro_fecha_hora'),
          onPressed: () => Navigator.of(context).pop(const FiltroFechaHora()),
          child: const Text('Limpiar filtro'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const ValueKey('aplicar_filtro_fecha_hora'),
          onPressed: _aplicar,
          child: const Text('Aplicar'),
        ),
      ],
    );
  }
}
