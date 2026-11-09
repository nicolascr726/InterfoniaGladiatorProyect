import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../config.dart';

class LlamadaScreen extends StatefulWidget {
  final String room;
  final bool isCaller;
  final String tipo;
  final IO.Socket? socket;
  final String miRut;
  final String rutDestino; // RUT de la otra persona (el que NO soy yo)
  final String? callId;

  const LlamadaScreen({
    super.key,
    required this.room,
    required this.isCaller,
    required this.tipo,
    this.socket,
    required this.miRut,
    required this.rutDestino,
    this.callId,
  });

  @override
  State<LlamadaScreen> createState() => _LlamadaScreenState();
}

class _LlamadaScreenState extends State<LlamadaScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  String _status = 'Conectando...';
  bool _callEnded = false;
  DateTime? _connectedAt;
  late IO.Socket _socket;
  final _desuscribirSocket = <VoidCallback>[];
  Timer? _timeoutTimer;
  Timer? _durationTimer;

  String _formatearDuracion(int segundosTotales) {
    final minutos = segundosTotales ~/ 60;
    final segundos = segundosTotales % 60;

    return '${minutos.toString().padLeft(2, '0')}:'
        '${segundos.toString().padLeft(2, '0')}';
  }

  bool _speakerOn = true;
  bool _muted = false;

  void _toggleSpeaker() async {
    _speakerOn = !_speakerOn;
    if (_localStream != null) {
      await Helper.setSpeakerphoneOn(_speakerOn);
    }
    setState(() {});
  }

  void _toggleMute() {
    _muted = !_muted;
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = !_muted;
    });
    setState(() {});
  }

  void _iniciarContadorDuracion() {
    _durationTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _connectedAt != null) {
        setState(() {});
      }
    });
  }

  String get _estadoConDuracion {
    if (_connectedAt == null) return _status;

    final segundos =
        DateTime.now().difference(_connectedAt!).inSeconds;

    return '$_status · ${_formatearDuracion(segundos)}';
  }

  @override
  void initState() {
    super.initState();
    _iniciarContadorDuracion();
    _setupSocket();
    _initCall();
    if (widget.isCaller) {
      _startTimeoutTimer();
    }
  }

  void _startTimeoutTimer() {
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      if (!_callEnded && _status != 'Llamada conectada') {
        _finalizar(remoto: false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nadie contestó la llamada')),
          );
        }
      }
    });
  }

  void _setupSocket() {
    if (widget.socket != null) {
      _socket = widget.socket!;
    } else {
      // Venimos de Notificación Push
      _socket = IO.io(kBaseUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false,
        'forceNew': true,
      });
    }
    _escucharSocket('end-call', (data) {
      if (_coincideLlamada(data)) _finalizar(remoto: true);
    });
    _escucharSocket('missed-call', (_) => _finalizar(remoto: true));
    _escucharSocket('busy', (data) {
      if (!_coincideLlamada(data) || !mounted || _callEnded) return;
      _finalizar(remoto: true, rechazada: true);
    });
    if (widget.socket == null) _socket.connect();
  }

  void _escucharSocket(String evento, void Function(dynamic) handler) {
    _socket.on(evento, handler);
    _desuscribirSocket.add(() => _socket.off(evento, handler));
  }

  Future<void> _initCall() async {
    await _localRenderer.initialize();
    if (!mounted || _callEnded) return;
    await _remoteRenderer.initialize();
    if (!mounted || _callEnded) return;
    await _startCall();
  }

  Future<Map<String, dynamic>> _getIceServers() async {
    try {
      final res = await http.get(Uri.parse('$kBaseUrl/twilio-ice'));
      final data = jsonDecode(res.body);
      if (data['iceServers'] != null) {
        final List servers = data['iceServers'];
        return {
          'iceServers': servers.map((s) {
            final Map<String, dynamic> server = {'urls': s['urls']};
            if (s['username'] != null) server['username'] = s['username'];
            if (s['credential'] != null) server['credential'] = s['credential'];
            return server;
          }).toList(),
        };
      }
    } catch (_) {}
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    };
  }

  Future<void> _startCall() async {
    final iceConfig = await _getIceServers();
    if (!mounted || _callEnded) return;
    final peer = await createPeerConnection(iceConfig);
    if (!mounted || _callEnded) {
      await peer.dispose();
      return;
    }
    _peerConnection = peer;

    _peerConnection!.onIceCandidate = (candidate) {
      _socket.emit('ice-candidate', {
        'room': widget.room,
        'candidate': candidate.toMap(),
      });
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        setState(() {
          _remoteRenderer.srcObject = event.streams[0];
          _connectedAt ??= DateTime.now();
          _status = 'Llamada conectada';
        });
      }
    };

    // Obtener cámara y micrófono
    final constraints = widget.tipo == 'audio'
        ? {'audio': true, 'video': false}
        : {
            'audio': true,
            'video': {
              'facingMode': 'user',
              'width': 640,
              'height': 480,
              'frameRate': 30,
            }
          };

    try {
      final stream = await navigator.mediaDevices.getUserMedia(constraints);
      if (!mounted || _callEnded) {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
        return;
      }
      _localStream = stream;
      _localRenderer.srcObject = _localStream;
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
      if (mounted) setState(() {}); // Renderizar el video local
      
      if (widget.tipo == 'audio') {
        Helper.setSpeakerphoneOn(_speakerOn);
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Error al acceder a la cámara: $e');
    }
    if (!mounted || _callEnded) return;

    // Escuchar señales WebRTC
    _escucharSocket('offer', (data) async {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recibiendo Offer...')));
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(data['sdp']['sdp'], data['sdp']['type']),
      );
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      _socket.emit('answer', {'room': widget.room, 'sdp': answer.toMap()});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Answer enviado!')));
      _connectedAt ??= DateTime.now();
      if (mounted) setState(() => _status = 'Llamada conectada');
    });

    _escucharSocket('answer', (data) async {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recibiendo Answer...')));
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(data['sdp']['sdp'], data['sdp']['type']),
      );
      _connectedAt ??= DateTime.now();
      if (mounted) setState(() => _status = 'Llamada conectada');
    });

    _escucharSocket('ice-candidate', (data) async {
      try {
        final c = data['candidate'];
        await _peerConnection!.addCandidate(
          RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']),
        );
      } catch (_) {}
    });

    if (widget.isCaller) {
      _escucharSocket('ready', (data) async {
        if (!mounted || _callEnded || !_coincideLlamada(data)) return;
        final offer = await peer.createOffer();
        if (!mounted || _callEnded) return;
        await peer.setLocalDescription(offer);
        if (!mounted || _callEnded) return;
        _socket.emit('offer', {'room': widget.room, 'sdp': offer.toMap()});
      });
    }

    // Unirse a la sala cuando el socket esté conectado
    void unirseSala() {
      if (!mounted || _callEnded) return;
      if (widget.isCaller) {
        setState(() => _status = 'Esperando que contesten...');
      } else {
        setState(() => _status = 'Conectando video...');
      }
      _socket.emit('join-call', {
        'room': widget.room,
        'mi_rut': widget.miRut,
        if (widget.callId?.isNotEmpty == true)
          'call_id': widget.callId,
      });
      debugPrint('📡 Emitido join-call a la sala ${widget.room} con mi_rut ${widget.miRut}');
    }

    if (_socket.connected) {
      unirseSala();
    } else {
      _escucharSocket('connect', (_) => unirseSala());
      _escucharSocket('connect_error', (e) {
        if (mounted) setState(() => _status = 'Error de socket: $e');
      });
    }
  }

  bool _coincideLlamada(dynamic data) {
    final id = data is Map ? data['call_id']?.toString() : null;
    final callId = widget.callId;
    return id == null ||
        id.isEmpty ||
        callId == null ||
        callId.isEmpty ||
        id == callId;
  }

  void _avisarCierre() {
    _socket.emit('end-call', {'room': widget.room, 'call_id': widget.callId});
    if (widget.isCaller && _status != 'Llamada conectada') {
      _socket.emit('end-call', {
        'room': widget.rutDestino,
        'call_id': widget.callId,
      });
      _socket.emit('missed-call', {
        'room': widget.rutDestino,
        'caller_rut': widget.miRut,
        'reason': 'cancelada',
      });
    }
  }

  Future<void> _finalizar({bool remoto = false, bool rechazada = false}) async {
    if (_callEnded) return;
    _callEnded = true;
    _durationTimer?.cancel();

    // SIEMPRE liberar MI rut cuando termine la llamada
    if (widget.miRut.isNotEmpty) {
      _socket.emit('free-rut', {'rut': widget.miRut});
    }

    if (!remoto) _avisarCierre();

    _peerConnection?.close();
    _localStream?.getTracks().forEach((t) => t.stop());

    if (mounted) {
      if (remoto) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(rechazada ? 'Llamada rechazada' : 'La otra persona colgó')),
        );
      }
      final ruta = ModalRoute.of(context);
      if (ruta?.isCurrent == true) {
        ruta?.navigator?.pop();
      } else if (ruta != null && ruta.isActive) {
        ruta.navigator?.removeRoute(ruta);
      }
    }

    // Ambos lados guardan su propio registro (emisor y receptor son siempre correctos)
    try {
      await http.post(
        Uri.parse('$kBaseUrl/historial'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rut_emisor': widget.isCaller ? widget.miRut : widget.rutDestino,
          'rut_receptor': widget.isCaller ? widget.rutDestino : widget.miRut,
          'tipo_llamada': widget.tipo,
          'estado': (widget.isCaller && _status != 'Llamada conectada') ? 'perdida' : 'finalizada',
          'duracion_segundos': _connectedAt == null ? 0 : DateTime.now().difference(_connectedAt!).inSeconds,
        }),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}

    // Se guarda un mensaje genérico en el chat por el registro de la llamada

    final perdida = widget.isCaller && _status != 'Llamada conectada';
    final duracion = _connectedAt == null
        ? 0
        : DateTime.now().difference(_connectedAt!).inSeconds;

    if (widget.isCaller) {
      try {
        final response = await http.post(
          Uri.parse('$kBaseUrl/api/chat/messages'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'rut_emisor': widget.miRut,
            'rut_receptor': widget.rutDestino,
            'mensaje': perdida
                ? '📞 Llamada perdida'
                : '📞 Llamada finalizada · Duración: ${_formatearDuracion(duracion)}',
          }),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode < 200 || response.statusCode >= 300) {
          debugPrint('No se pudo guardar el mensaje de llamada: ${response.body}');
        }
      } catch (e) {
        debugPrint('Error guardando el mensaje de llamada: $e');
      }
    }

  }

  @override
  void dispose() {
    if (!_callEnded && widget.isCaller && _connectedAt == null) _avisarCierre();
    _timeoutTimer?.cancel();
    _durationTimer?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    for (final desuscribir in _desuscribirSocket) {
      desuscribir();
    }
    if (widget.socket == null) {
      // Solo matar el socket si lo creamos aquí
      _socket.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tipo == 'audio') {
      return _buildAudioUI();
    }
    return Scaffold(
      backgroundColor: const Color(0xFF11111B),
      body: Stack(
        children: [
          // Video remoto (pantalla completa)
          if (widget.tipo == 'video')
            Positioned.fill(
              child: RTCVideoView(
                _remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),

          // Resplandor azul
          Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF448AFF).withOpacity(0.25),
                  blurRadius: 80,
                  spreadRadius: 10,
                ),
              ],
            ),
          ),

          // Video local (esquina superior derecha)
          if (widget.tipo == 'video')
            Positioned(
              top: 50,
              right: 15,
              width: 110,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: RTCVideoView(
                  _localRenderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),

          // Estado de la llamada
          Positioned(
            bottom: 130,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _estadoConDuracion,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
            ),
          ),

          // Botón de colgar
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton.large(
                backgroundColor: const Color(0xFFff5252),
                onPressed: _finalizar,
                child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 36),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioUI() {
    final subtitle = widget.isCaller ? 'Llamando a ${widget.rutDestino}' : 'De ${widget.rutDestino}';
    final waitingForAnswer = widget.isCaller && _status != 'Llamada conectada';

    return Scaffold(
      backgroundColor: const Color(0xFF11111B),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF448AFF).withOpacity(0.18),
                  border: Border.all(color: waitingForAnswer ? Colors.orangeAccent : const Color(0xFF448AFF), width: 2),
                ),
                child: Icon(
                  waitingForAnswer ? Icons.notifications_active_rounded : Icons.person_rounded,
                  color: waitingForAnswer ? Colors.orangeAccent : const Color(0xFF448AFF),
                  size: 58,
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Llamada de audio',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  _estadoConDuracion,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 42),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FloatingActionButton(
                    heroTag: 'route_app',
                    backgroundColor: _speakerOn ? const Color(0xFF448AFF) : const Color(0xFF2A2A3A),
                    onPressed: _toggleSpeaker,
                    tooltip: _speakerOn ? 'Usar auricular' : 'Usar altavoz',
                    child: Icon(_speakerOn ? Icons.volume_up_rounded : Icons.phone_in_talk_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 20),
                  FloatingActionButton(
                    heroTag: 'mute_app',
                    backgroundColor: const Color(0xFF2A2A3A),
                    onPressed: waitingForAnswer ? null : _toggleMute,
                    child: Icon(_muted ? Icons.mic_off : Icons.mic, color: Colors.white),
                  ),
                  const SizedBox(width: 28),
                  FloatingActionButton.large(
                    heroTag: 'end_app',
                    backgroundColor: const Color(0xFFFF5252),
                    onPressed: () => _finalizar(remoto: false),
                    child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 36),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                _speakerOn ? 'Salida: altavoces comunes' : 'Salida: auricular interno',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
