import 'package:flutter/material.dart';
import 'historial_modal.dart';
import 'puertas_modal.dart';
import 'recados_modal.dart';

class ReportesModal extends StatelessWidget {
  final String miRut;

  const ReportesModal({super.key, required this.miRut});

  void _abrirReporte(BuildContext context, WidgetBuilder builder) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: builder,
    );
  }

  Widget _botonReporte({
    required String titulo,
    required IconData icono,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFF222233),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          leading: Icon(icono, color: const Color(0xFF448AFF)),
          title: Text(titulo, style: const TextStyle(color: Colors.white)),
          trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
          onTap: onTap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF11111B),
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
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Reportes',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cerrar reportes',
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _botonReporte(
                titulo: 'Historial de llamadas',
                icono: Icons.history_rounded,
                onTap: () => _abrirReporte(
                  context,
                  (_) => HistorialModal(miRut: miRut),
                ),
              ),
              _botonReporte(
                titulo: 'Reportes de Mensajes',
                icono: Icons.sticky_note_2_rounded,
                onTap: () => _abrirReporte(
                  context,
                  (_) => RecadosModal(miRut: miRut, mostrarComoMensajes: true),
                ),
              ),
              _botonReporte(
                titulo: 'Reportes de Puertas',
                icono: Icons.door_front_door_rounded,
                onTap: () => _abrirReporte(
                  context,
                  (_) => PuertasModal(miRut: miRut),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
