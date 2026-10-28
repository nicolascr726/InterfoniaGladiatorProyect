import 'package:flutter/material.dart';

import '../services/notification_history_service.dart';

class NotificacionesPanel extends StatefulWidget {
  final List<NotificationHistoryEntry> notificaciones;
  final bool loading;
  final String? error;
  final VoidCallback? onRefresh;
  final ValueChanged<NotificationHistoryEntry>? onTap;
  final Future<bool> Function(NotificationHistoryEntry)? onDismiss;

  const NotificacionesPanel({
    super.key,
    required this.notificaciones,
    this.loading = false,
    this.error,
    this.onRefresh,
    this.onTap,
    this.onDismiss,
  });

  @override
  State<NotificacionesPanel> createState() => _NotificacionesPanelState();
}

class _NotificacionesPanelState extends State<NotificacionesPanel> {
  // Retira la fila al terminar su animación aunque el padre aún no se actualice.
  final _descartadas = <String>{};
  final _descartesPendientes = <String, Future<bool>>{};

  Future<bool> _confirmarDescarte(NotificationHistoryEntry notificacion) async {
    final onDismiss = widget.onDismiss;
    if (onDismiss == null || _descartadas.contains(notificacion.id)) {
      return false;
    }

    final pendiente = _descartesPendientes[notificacion.id];
    if (pendiente != null) return pendiente;

    final descarte = Future<bool>.sync(() => onDismiss(notificacion)).then(
      (confirmado) => confirmado,
      onError: (Object _, StackTrace __) => false,
    );
    _descartesPendientes[notificacion.id] = descarte;
    try {
      return await descarte;
    } finally {
      _descartesPendientes.remove(notificacion.id);
    }
  }

  void _ocultarDescarte(String id) {
    if (!mounted) return;
    setState(() => _descartadas.add(id));
  }

  Future<void> _descartarAccesible(
      NotificationHistoryEntry notificacion) async {
    if (await _confirmarDescarte(notificacion)) {
      _ocultarDescarte(notificacion.id);
    }
  }

  String _fechaHora(DateTime fecha) {
    final local = fecha.toLocal();
    String dos(int valor) => valor.toString().padLeft(2, '0');
    return '${dos(local.day)}/${dos(local.month)}/${local.year} · '
        '${dos(local.hour)}:${dos(local.minute)}';
  }

  IconData _icono(String tipo) {
    switch (tipo) {
      case 'chat_message':
        return Icons.chat_bubble_outline_rounded;
      case 'call':
      case 'incoming_call':
        return Icons.call_received_rounded;
      case 'call_record':
        return Icons.history_rounded;
      case 'outgoing_call':
        return Icons.call_made_rounded;
      case 'audio':
      case 'audio_call':
        return Icons.call_rounded;
      case 'video':
      case 'video_call':
        return Icons.videocam_rounded;
      case 'missed_call':
        return Icons.phone_missed_rounded;
      case 'recado':
      case 'recado_created':
        return Icons.sticky_note_2_outlined;
      case 'recado_resolved':
        return Icons.task_alt_rounded;
      case 'door_opening':
        return Icons.door_front_door_outlined;
      default:
        return Icons.notifications_none_rounded;
    }
  }

  Color _color(String tipo) {
    switch (tipo) {
      case 'chat_message':
        return const Color(0xFF80B1FF);
      case 'call':
      case 'incoming_call':
      case 'call_record':
      case 'outgoing_call':
      case 'audio':
      case 'audio_call':
        return const Color(0xFF81C784);
      case 'video':
      case 'video_call':
        return const Color(0xFF80CBC4);
      case 'missed_call':
        return const Color(0xFFFF8A80);
      case 'recado':
      case 'recado_created':
        return const Color(0xFFFFCC80);
      case 'recado_resolved':
        return const Color(0xFF81C784);
      case 'door_opening':
        return const Color(0xFFCE93D8);
      default:
        return const Color(0xFFFFCC80);
    }
  }

  Widget _estadoVacio() {
    return const Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.notifications_none_rounded,
              size: 44,
              color: Colors.white38,
            ),
            SizedBox(height: 12),
            Text(
              'Sin notificaciones',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Aquí aparecerán las llamadas, mensajes, recados y aperturas de puerta.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _notificacion(NotificationHistoryEntry notificacion) {
    final color = _color(notificacion.type);
    return InkWell(
      onTap: widget.onTap == null || notificacion.type != 'chat_message'
          ? null
          : () => widget.onTap!(notificacion),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFF222233),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_icono(notificacion.type), color: color, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    notificacion.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (notificacion.body.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      notificacion.body,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    _fechaHora(notificacion.receivedAt),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fondoDescarte(Alignment alineacion) {
    return Container(
      color: const Color(0xFFE2EAF4),
      alignment: alineacion,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.archive_outlined, color: Color(0xFF263B59)),
          SizedBox(width: 8),
          Text('Descartar', style: TextStyle(color: Color(0xFF263B59))),
        ],
      ),
    );
  }

  Widget _filaDescartable(NotificationHistoryEntry notificacion) {
    return Dismissible(
      key: ValueKey(notificacion.id),
      direction: widget.onDismiss == null
          ? DismissDirection.none
          : DismissDirection.horizontal,
      confirmDismiss: (_) => _confirmarDescarte(notificacion),
      onDismissed: (_) => _ocultarDescarte(notificacion.id),
      background: _fondoDescarte(Alignment.centerLeft),
      secondaryBackground: _fondoDescarte(Alignment.centerRight),
      child: Semantics(
        onDismiss: widget.onDismiss == null
            ? null
            : () => _descartarAccesible(notificacion),
        child: _notificacion(notificacion),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notificaciones = widget.notificaciones
        .where((notificacion) => !_descartadas.contains(notificacion.id))
        .toList();
    return Material(
      color: const Color(0xFF151C2C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0xFF35435B)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Notificaciones',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (notificaciones.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '${notificaciones.length}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                  ),
                if (widget.onRefresh != null)
                  IconButton(
                    tooltip: 'Actualizar notificaciones',
                    onPressed: widget.loading ? null : widget.onRefresh,
                    icon: const Icon(Icons.refresh_rounded),
                    color: const Color(0xFF80B1FF),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF35435B)),
          if (widget.loading && notificaciones.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          if (widget.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                widget.error!,
                style: const TextStyle(color: Color(0xFFFFCC80), fontSize: 13),
              ),
            ),
          Expanded(
            child: widget.loading && notificaciones.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : notificaciones.isEmpty
                    ? _estadoVacio()
                    : ListView.separated(
                        key: const PageStorageKey('lista_notificaciones'),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: notificaciones.length,
                        findItemIndexCallback: (key) {
                          final index = notificaciones.indexWhere(
                            (notificacion) => ValueKey(notificacion.id) == key,
                          );
                          return index < 0 ? null : index;
                        },
                        itemBuilder: (_, index) =>
                            _filaDescartable(notificaciones[index]),
                        separatorBuilder: (_, __) => const Divider(
                          height: 1,
                          indent: 64,
                          endIndent: 16,
                          color: Color(0xFF273349),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
