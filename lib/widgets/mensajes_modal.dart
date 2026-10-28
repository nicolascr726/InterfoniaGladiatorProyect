import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../config.dart';

class MensajesModal extends StatefulWidget {
  final String miRut;
  final bool soloConserjes;
  final Map<String, dynamic>? contactoInicial;

  const MensajesModal({
    super.key,
    required this.miRut,
    this.soloConserjes = false,
    this.contactoInicial,
  });

  @override
  State<MensajesModal> createState() => _MensajesModalState();
}

class _MensajesModalState extends State<MensajesModal> {
  final TextEditingController _mensajeController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _pollTimer;

  bool _loadingContactos = true;
  bool _consultaContactosEnCurso = false;
  bool _loadingMensajes = false;
  String? _error;
  String _unidadPropia = 'Depto/Casa';
  Map<String, dynamic>? _contactoSeleccionado;
  List<Map<String, dynamic>> _contactos = [];
  List<Map<String, dynamic>> _mensajes = [];

  @override
  void initState() {
    super.initState();
    _contactoSeleccionado = widget.contactoInicial;
    if (_contactoSeleccionado == null) {
      _cargarContactos();
    } else {
      _cargarMensajes();
    }
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_contactoSeleccionado != null) {
        _cargarMensajes(silencioso: true);
      } else {
        _cargarContactos(silencioso: true);
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _mensajeController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _contactoRut(Map<String, dynamic> c) =>
      (c['rut_usuario'] ?? '').toString();

  String _textoBusqueda(dynamic value) => (value ?? '')
      .toString()
      .toLowerCase()
      .replaceAll('á', 'a')
      .replaceAll('é', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .trim();

  List<Map<String, dynamic>> _buscarContactos(String query) {
    final q = _textoBusqueda(query);
    if (q.isEmpty) return _contactos;
    return _contactos.where((contacto) {
      final dpto = (contacto['id_dpto'] ?? '').toString();
      return _textoBusqueda([
        contacto['nombres'] ?? '',
        contacto['apellido_1'] ?? '',
        contacto['apellido_2'] ?? '',
        contacto['rut_usuario'] ?? '',
        contacto['display_name'] ?? '',
        contacto['unidad_label'] ?? '',
        _contactoTitulo(contacto),
        'depto departamento $dpto',
      ].join(' '))
          .contains(q);
    }).toList();
  }

  DateTime? _fechaEnvioLocal(dynamic fechaHora) {
    final valor = (fechaHora ?? '').toString().trim();
    if (valor.isEmpty) return null;

    // El servidor guarda UTC y puede enviar la fecha sin indicador de zona.
    final tieneZona =
    RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(valor);
    final fecha = DateTime.tryParse(tieneZona ? valor : '${valor}Z');
    return fecha?.toLocal();
  }

  String _diaEnvio(dynamic fechaHora) {
    final fecha = _fechaEnvioLocal(fechaHora);
    if (fecha == null) return 'Fecha no registrada';
    return '${fecha.day.toString().padLeft(2, '0')}/'
        '${fecha.month.toString().padLeft(2, '0')}/${fecha.year}';
  }

  String _horaEnvio(dynamic fechaHora) {
    final local = _fechaEnvioLocal(fechaHora);
    if (local == null) return '--:--';
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  String _contactoTitulo(Map<String, dynamic> c) {
    final display = (c['display_name'] ?? '').toString().trim();
    if (display.isNotEmpty) return display;

    final esAdmin = c['es_admin'] == true || c['es_admin'] == 1;
    final nombre = '${c['nombres'] ?? ''} ${c['apellido_1'] ?? ''}'.trim();
    if (esAdmin) return nombre.isEmpty ? 'Conserjería' : nombre;

    final unidad = (c['id_dpto'] ?? '').toString().trim();
    final label = unidad.isEmpty ? 'Depto/Casa' : 'Depto/Casa $unidad';
    return nombre.isEmpty ? label : '$label - $nombre';
  }

  String _contactoUltimoMensaje(Map<String, dynamic> contacto) {
    final rawLastMessage = contacto['last_message'];

    if (rawLastMessage is! Map) {
      return 'Sin mensajes recibidos';
    }

    final lastMessage = Map<String, dynamic>.from(rawLastMessage);
    final esImagen =
        lastMessage['es_imagen'] == true || lastMessage['es_imagen'] == 1;
    final esMio = lastMessage['is_mine'] == true;
    final prefijo = esMio ? 'Tú: ' : '';

    if (esImagen) {
      return '📷 Imagen';
    }

    final mensaje = (lastMessage['mensaje'] ?? '').toString().trim();

    if (mensaje.isEmpty) {
      return 'Sin mensajes recibidos';
    }
    return '$prefijo$mensaje';
  }

  Future<void> _cargarContactos({bool silencioso = false}) async {
    if (!mounted || _consultaContactosEnCurso) return;
    _consultaContactosEnCurso = true;
    if (!silencioso) {
      setState(() {
        _loadingContactos = true;
        _error = null;
      });
    }

    try {
      final uri = Uri.parse('$kBaseUrl/api/chat/contactos').replace(
        queryParameters: {'rut': widget.miRut},
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? res.body);
      }

      final contactos = (data['contactos'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((contacto) =>
      !widget.soloConserjes ||
          contacto['es_admin'] == true ||
          contacto['es_admin'] == 1)
          .toList();

      final ordenOriginal = {
        for (var i = 0; i < contactos.length; i++) _contactoRut(contactos[i]): i,
      };
      // La fecha del último mensaje conserva la posición después de leerlo.
      contactos.sort((a, b) {
        final ultimoA = a['last_message'];
        final ultimoB = b['last_message'];
        final fechaA =
            _fechaEnvioLocal(ultimoA is Map ? ultimoA['fecha_hora'] : null);
        final fechaB =
            _fechaEnvioLocal(ultimoB is Map ? ultimoB['fecha_hora'] : null);

        if (fechaA == null && fechaB != null) return 1;
        if (fechaA != null && fechaB == null) return -1;
        if (fechaA != null && fechaB != null) {
          final porFecha = fechaB.compareTo(fechaA);
          if (porFecha != 0) return porFecha;
        }

        final idA =
            int.tryParse((ultimoA is Map ? ultimoA['id'] : '').toString()) ?? 0;
        final idB =
            int.tryParse((ultimoB is Map ? ultimoB['id'] : '').toString()) ?? 0;
        final porId = idB.compareTo(idA);
        if (porId != 0) return porId;

        return ordenOriginal[_contactoRut(a)]!
            .compareTo(ordenOriginal[_contactoRut(b)]!);
      });

      if (!mounted) return;
      setState(() {
        _contactos = contactos;
        _unidadPropia = (data['unidad_label'] ?? 'Depto/Casa').toString();
        _loadingContactos = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silencioso) {
        setState(() {
          _loadingContactos = false;
          _error = 'No se pudieron cargar contactos: $e';
        });
      }
    } finally {
      _consultaContactosEnCurso = false;
    }
  }

  Future<void> _cargarMensajes({bool silencioso = false}) async {
    final contacto = _contactoSeleccionado;
    if (contacto == null) return;

    if (!silencioso) {
      setState(() {
        _loadingMensajes = true;
        _error = null;
      });
    }

    try {
      final uri = Uri.parse('$kBaseUrl/api/chat/messages').replace(
        queryParameters: {
          'rut': widget.miRut,
          'peer': _contactoRut(contacto),
          'limit': '50',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? res.body);
      }

      final mensajes = (data['messages'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (!mounted) return;
      setState(() {
        _mensajes = mensajes;
        _loadingMensajes = false;
        _error = null;
      });
      _bajarAlFinal();
    } catch (e) {
      if (!mounted) return;
      if (!silencioso) {
        setState(() {
          _loadingMensajes = false;
          _error = 'No se pudieron cargar mensajes: $e';
        });
      }
    }
  }

  Future<void> _enviarMensaje() async {
    final contacto = _contactoSeleccionado;
    final texto = _mensajeController.text.trim();
    if (contacto == null || texto.isEmpty) return;

    _mensajeController.clear();
    try {
      final res = await http
          .post(
        Uri.parse('$kBaseUrl/api/chat/messages'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rut_emisor': widget.miRut,
          'rut_receptor': _contactoRut(contacto),
          'mensaje': texto,
        }),
      )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? res.body);
      }
      await _cargarMensajes(silencioso: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo enviar: $e')),
      );
    }
  }

  Future<void> _eliminarMensaje(int mensajeId) async {
    try {
      final res = await http
          .delete(
        Uri.parse('$kBaseUrl/api/chat/message/$mensajeId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'rut': widget.miRut}),
      )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? res.body);
      }
      await _cargarMensajes(silencioso: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo eliminar el mensaje: $e')),
      );
    }
  }

  Future<void> _vaciarChat() async {
    final contacto = _contactoSeleccionado;
    if (contacto == null) return;

    bool? confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF222233),
        title: const Text('Vaciar chat', style: TextStyle(color: Colors.white)),
        content: const Text(
          '¿Estás seguro de que deseas eliminar todos los mensajes de esta conversación?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child:
            const Text('Vaciar', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    try {
      final res = await http
          .delete(
        Uri.parse('$kBaseUrl/api/chat/clear'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rut': widget.miRut,
          'peer': _contactoRut(contacto),
        }),
      )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? res.body);
      }
      await _cargarMensajes(silencioso: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo vaciar el chat: $e')),
      );
    }
  }

  void _mostrarOpcionesImagen() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF222233),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading:
              const Icon(Icons.camera_alt_rounded, color: Colors.white),
              title: const Text('Tomar Foto',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _seleccionarYSubir(ImageSource.camera);
              },
            ),
            ListTile(
              leading:
              const Icon(Icons.photo_library_rounded, color: Colors.white),
              title: const Text('Elegir de Galería',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _seleccionarYSubir(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _seleccionarYSubir(ImageSource source) async {
    try {
      final XFile? pickedFile =
      await ImagePicker().pickImage(source: source, imageQuality: 70);
      if (pickedFile == null) {
        print('No se seleccionó ninguna imagen.');
        return;
      }

      final contacto = _contactoSeleccionado;
      if (contacto == null) return;

      setState(() {
        _loadingMensajes = true;
      });

      print('Preparando subida de imagen: ${pickedFile.path}');
      var request =
      http.MultipartRequest('POST', Uri.parse('$kBaseUrl/api/chat/upload'));
      request.fields['rut_emisor'] = widget.miRut;
      request.fields['rut_receptor'] = _contactoRut(contacto);
      request.files
          .add(await http.MultipartFile.fromPath('file', pickedFile.path));

      print('Enviando a $kBaseUrl/api/chat/upload ...');
      final streamedResponse =
      await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamedResponse);
      print('Status Code de Subida: ${response.statusCode}');
      print('Respuesta del servidor: ${response.body}');

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? response.body);
      }
      print('Subida exitosa, recargando mensajes...');
      await _cargarMensajes(silencioso: true);
    } catch (e) {
      print('Error grave al subir imagen: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo enviar la imagen: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loadingMensajes = false;
        });
      }
    }
  }

  void _bajarAlFinal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _seleccionarContacto(Map<String, dynamic> contacto) {
    setState(() {
      _contactoSeleccionado = contacto;
      _mensajes = [];
    });
    _cargarMensajes();
  }

  Widget _buildHeader() {
    final contacto = _contactoSeleccionado;
    return Row(
      children: [
        IconButton(
          icon: Icon(
              contacto == null ? Icons.close_rounded : Icons.arrow_back_rounded,
              color: Colors.white),
          onPressed: () {
            if (contacto == null) {
              Navigator.pop(context);
            } else {
              setState(() => _contactoSeleccionado = null);
              _cargarContactos();
            }
          },
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                contacto == null ? 'Mensajes' : _contactoTitulo(contacto),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600),
              ),
              Text(
                contacto == null
                    ? 'Cuenta compartida: $_unidadPropia + pantalla puerta'
                    : 'Chat por Depto/Casa',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
        if (contacto == null)
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF448AFF)),
            onPressed: _cargarContactos,
          )
        else
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
            color: const Color(0xFF222233),
            onSelected: (value) {
              if (value == 'vaciar') {
                _vaciarChat();
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem<String>(
                value: 'vaciar',
                child: Text('Vaciar conversación',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildContactos() {
    if (_loadingContactos) {
      return const Expanded(
          child: Center(
              child: CircularProgressIndicator(color: Color(0xFF448AFF))));
    }
    final contactos = _buscarContactos(_searchController.text);
    if (contactos.isEmpty) {
      return Expanded(
          child: Center(
              child: Text(
                  _contactos.isEmpty
                      ? 'No hay contactos disponibles.'
                      : 'No hay contactos para mostrar.',
                  style: const TextStyle(color: Colors.grey))));
    }

    return Expanded(
      child: ListView.builder(
        itemCount: contactos.length,
        itemBuilder: (context, index) {
          final c = contactos[index];
          final unread = int.tryParse((c['unread'] ?? '0').toString()) ?? 0;
          final esAdmin = c['es_admin'] == true || c['es_admin'] == 1;
          return Card(
            color: const Color(0xFF222233),
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor:
                esAdmin ? const Color(0xFF448AFF) : const Color(0xFF4CAF50),
                child: Icon(
                    esAdmin ? Icons.support_agent_rounded : Icons.home_rounded,
                    color: Colors.white),
              ),
              title: Text(_contactoTitulo(c),
                  style: const TextStyle(color: Colors.white)),
              subtitle: Text(
                _contactoUltimoMensaje(c),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: unread > 0 ? Colors.white70 : Colors.white54,
                  fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              trailing: unread > 0
                  ? CircleAvatar(
                radius: 13,
                backgroundColor: const Color(0xFFFF5252),
                child: Text('$unread',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 12)),
              )
                  : const Icon(Icons.chevron_right_rounded,
                  color: Colors.white38),
              onTap: () => _seleccionarContacto(c),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMensajes() {
    final contacto = _contactoSeleccionado;
    if (contacto == null) return const SizedBox.shrink();

    return Expanded(
      child: Column(
        children: [
          Expanded(
            child: _loadingMensajes
                ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF448AFF)))
                : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _mensajes.length,
              itemBuilder: (context, index) {
                final m = _mensajes[index];
                final propio =
                    (m['rut_emisor'] ?? '').toString() == widget.miRut;
                final mensajeId = m['id'];
                final leido = m['leido'] == true || m['leido'] == 1;

                final burbuja = GestureDetector(
                  onLongPress: () {
                    showModalBottomSheet(
                      context: context,
                      backgroundColor: const Color(0xFF222233),
                      builder: (ctx) => SafeArea(
                        child: Wrap(
                          children: [
                            ListTile(
                              leading: const Icon(
                                Icons.delete_rounded,
                                color: Colors.redAccent,
                              ),
                              title: const Text(
                                'Eliminar mensaje',
                                style: TextStyle(color: Colors.white),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                if (mensajeId != null) {
                                  _eliminarMensaje(mensajeId);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  child: Align(
                    alignment: propio
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 9),
                      constraints: BoxConstraints(
                        maxWidth:
                        MediaQuery.of(context).size.width * 0.72,
                      ),
                      decoration: BoxDecoration(
                        color: propio
                            ? const Color(0xFF448AFF)
                            : const Color(0xFF333344),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: propio
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          if (m['es_imagen'] == true)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                '$kBaseUrl${m['mensaje']}',
                                fit: BoxFit.cover,
                                errorBuilder:
                                    (context, error, stackTrace) =>
                                const Icon(
                                  Icons.broken_image,
                                  color: Colors.white54,
                                ),
                              ),
                            )
                          else
                            Text(
                              (m['mensaje'] ?? '').toString(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                            ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _horaEnvio(m['fecha_hora']),
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 10,
                                ),
                              ),
                              if (propio) ...[
                                const SizedBox(width: 3),
                                Icon(
                                  leido
                                      ? Icons.done_all_rounded
                                      : Icons.done_rounded,
                                  size: 16,
                                  color: leido
                                      ? const Color(0xFFB3E5FC)
                                      : Colors.white60,
                                  semanticLabel:
                                  leido ? 'Leído' : 'No leído',
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                final dia = _diaEnvio(m['fecha_hora']);
                final mostrarDia = index == 0 ||
                    _diaEnvio(_mensajes[index - 1]['fecha_hora']) != dia;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (mostrarDia)
                      Padding(
                        padding:
                        const EdgeInsets.only(top: 4, bottom: 12),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Divider(color: Colors.white24),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12),
                              child: Text(
                                dia,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const Expanded(
                              child: Divider(color: Colors.white24),
                            ),
                          ],
                        ),
                      ),
                    burbuja,
                  ],
                );
              },
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.attach_file_rounded,
                    color: Colors.white54),
                onPressed: _mostrarOpcionesImagen,
              ),
              Expanded(
                child: TextField(
                  controller: _mensajeController,
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Escribe un mensaje...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: const Color(0xFF222233),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _enviarMensaje(),
                ),
              ),
              const SizedBox(width: 8),
              FloatingActionButton.small(
                heroTag: 'fab_enviar_mensaje_${_contactoRut(contacto)}',
                backgroundColor: const Color(0xFF4CAF50),
                onPressed: _enviarMensaje,
                child: const Icon(Icons.send_rounded, color: Colors.white),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 12,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        children: [
          Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(8))),
          const SizedBox(height: 8),
          _buildHeader(),
          if (_contactoSeleccionado == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Buscar por nombre, RUT o Depto...',
                  hintStyle: const TextStyle(color: Colors.grey),
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF222233),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF444444)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF444444)),
                  ),
                ),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.orange)),
          ],
          const SizedBox(height: 8),
          _contactoSeleccionado == null ? _buildContactos() : _buildMensajes(),
        ],
      ),
    );
  }
}
