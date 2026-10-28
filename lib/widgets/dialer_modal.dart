import 'package:flutter/material.dart';
import 'directorio_modal.dart';

class DialerModal extends StatefulWidget {
  final String miRut;
  final Set<String> rutosOcupados;
  final Function(String rutOrDpto, String tipo) onLlamar;

  const DialerModal({
    super.key,
    required this.miRut,
    required this.rutosOcupados,
    required this.onLlamar,
  });

  @override
  State<DialerModal> createState() => _DialerModalState();
}

class _DialerModalState extends State<DialerModal> {
  String _inputDpto = '';

  void _onKeyPress(String digit) {
    if (_inputDpto.length < 8) {
      setState(() {
        _inputDpto += digit;
      });
    }
  }

  void _onBackspace() {
    if (_inputDpto.isNotEmpty) {
      setState(() {
        _inputDpto = _inputDpto.substring(0, _inputDpto.length - 1);
      });
    }
  }

  void _onClear() {
    setState(() {
      _inputDpto = '';
    });
  }

  void _ejecutarLlamada(String tipo) {
    final dpto = _inputDpto.trim();
    if (dpto.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ingresa o marca un número de departamento'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    Navigator.pop(context);
    widget.onLlamar(dpto, tipo);
  }

  Widget _buildKeypadButton(String text, {VoidCallback? onTap, Color? color, IconData? icon}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(6.0),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap ?? () => _onKeyPress(text),
            child: Container(
              height: 60,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color ?? const Color(0xFF1A2338),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: icon != null
                  ? Icon(icon, color: Colors.white70, size: 22)
                  : Text(
                      text,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool ocupado = widget.rutosOcupados.contains(_inputDpto.trim());

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.dialpad_rounded, color: Color(0xFF6366F1), size: 28),
                  SizedBox(width: 10),
                  Text(
                    'Marcar Departamento',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white54),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // CAMPO DE TEXTO DEL DEPARTAMENTO (Teclado nativo)
          Expanded(
            child: Column(
              children: [
                TextFormField(
                  autofocus: true,
                  keyboardType: TextInputType.text,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: 'N° Depto (Ej: B-12, 1-69)',
                    hintStyle: const TextStyle(color: Colors.white30, fontSize: 18, letterSpacing: 0),
                    filled: true,
                    fillColor: const Color(0xFF151C2C),
                    prefixIcon: const Padding(
                      padding: EdgeInsets.only(left: 20, right: 10),
                      child: Icon(Icons.home_work_rounded, color: Color(0xFF6366F1), size: 28),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: Colors.white12, width: 1.5),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: Color(0xFF6366F1), width: 1.5),
                    ),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _inputDpto = value;
                    });
                  },
                ),
                if (ocupado) ...[
                  const SizedBox(height: 16),
                  const Text(
                    '🔴 Este departamento se encuentra en otra llamada',
                    style: TextStyle(color: Color(0xFFFF5252), fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          // BOTONES DE LLAMADA
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 52,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF10B981), Color(0xFF059669)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF10B981).withOpacity(0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: _inputDpto.isEmpty || ocupado ? null : () => _ejecutarLlamada('audio'),
                    icon: const Icon(Icons.call_rounded, color: Colors.white),
                    label: const Text(
                      'Llamar Audio',
                      style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 52,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF6366F1).withOpacity(0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: _inputDpto.isEmpty || ocupado ? null : () => _ejecutarLlamada('video'),
                    icon: const Icon(Icons.videocam_rounded, color: Colors.white),
                    label: const Text(
                      'Videollamada',
                      style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // BOTÓN DE ACCESO AL DIRECTORIO COMPLETO
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: Colors.white.withOpacity(0.12)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: () {
              Navigator.pop(context);
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => DirectorioModal(
                  miRut: widget.miRut,
                  rutosOcupados: widget.rutosOcupados,
                  onLlamar: widget.onLlamar,
                ),
              );
            },
            icon: const Icon(Icons.list_alt_rounded, color: Colors.white70, size: 20),
            label: const Text('Ver lista del Directorio', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}
