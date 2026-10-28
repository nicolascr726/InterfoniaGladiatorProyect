import eventlet
eventlet.monkey_patch()

from flask import Flask, request, jsonify, render_template, redirect, send_from_directory
from flask_socketio import SocketIO, emit, join_room
from flask_sock import Sock
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS
import firebase_admin
from firebase_admin import credentials, messaging
import requests
import jwt
import os
import sys
import datetime
from collections import deque
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from eventlet.semaphore import Semaphore
import uuid
from werkzeug.utils import secure_filename
from sqlalchemy import text

app = Flask(__name__, static_folder='static')
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*")
sock = Sock(app)
ph = PasswordHasher()
DEBUG_LOGIN=True

# ─── FIREBASE ────────────────────────────────
cred = credentials.Certificate("firebase-key.json")
firebase_admin.initialize_app(cred)

# ─── BASE DE DATOS ───────────────────────────
# Producción: MySQL en Ubuntu
app.config['SQLALCHEMY_DATABASE_URI'] = 'mysql+pymysql://flask:flaskpass@localhost/condominios_db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
db = SQLAlchemy(app)

# ─── MODELO DE USUARIO ───────────────────────
class Usuario(db.Model):
    __tablename__ = 'usuarios'
    rut_usuario = db.Column(db.String(8), primary_key=True)
    nombres = db.Column(db.String(80))
    apellido_1 = db.Column(db.String(50))
    apellido_2 = db.Column(db.String(50))
    telefono = db.Column(db.String(20), nullable=False)
    correo = db.Column(db.String(80))
    clave_app = db.Column(db.String(20))
    sexo = db.Column(db.String(20))
    fecha_nacimiento = db.Column(db.Date)
    fecha_registro = db.Column(db.Date)
    id_dpto = db.Column(db.String(50))
    img_perfil = db.Column(db.String, default="default.png")
    es_admin = db.Column(db.Integer, default=0)

class HistorialLlamadas(db.Model):
    __tablename__ = 'historial_llamadas'
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    rut_emisor = db.Column(db.String(20), nullable=False)
    rut_receptor = db.Column(db.String(20), nullable=False)
    tipo_llamada = db.Column(db.String(20), default="video")
    estado = db.Column(db.String(20), default="finalizada")
    fecha_hora = db.Column(db.DateTime, default=datetime.datetime.utcnow)
    duracion_segundos = db.Column(db.Integer, default=0)


class ChatMensaje(db.Model):
    __tablename__ = 'chat_mensajes'
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    rut_emisor = db.Column(db.String(20), nullable=False, index=True)
    rut_receptor = db.Column(db.String(20), nullable=False, index=True)
    mensaje = db.Column(db.Text, nullable=False)
    fecha_hora = db.Column(db.DateTime, default=datetime.datetime.utcnow, index=True)
    leido = db.Column(db.Integer, default=0)
    es_imagen = db.Column(db.Boolean, default=False)


# ─── ESTADO DE LLAMADAS CITÓFONO ESP32 ───────────────────────────────
# Se usa para cerrar el flujo app -> citófono y citófono -> app sin depender
# de WebRTC. El audio sigue usando los WebSockets crudos /browser_rx,/browser_tx.
CITOFONO_RUT = os.getenv('CITOFONO_RUT', 'CITOFONO')
CITOFONO_DEVICE_ID = os.getenv('CITOFONO_DEVICE_ID', 'citofono-1')
CITOFONO_RING_TIMEOUT_SECONDS = int(os.getenv('CITOFONO_RING_TIMEOUT_SECONDS', '60'))

_citofono_calls = {}
_citofono_last_ended_calls = {}
_citofono_lock = Semaphore()


def _norm_rut(value):
    return (str(value or '')
            .replace('.', '')
            .replace('-', '')
            .strip()
            .upper()
            .replace('Ó', 'O'))


def _is_citofono_value(value):
    v = _norm_rut(value)
    return bool(v) and (v == 'CITOFONO' or v == 'CITOFONO1' or v == 'CITOFONO_1' or 'CITOFONO' in v)


def _utcnow():
    return datetime.datetime.utcnow()


def _iso(dt):
    return dt.isoformat() + 'Z' if dt else None


def _new_call_id(prefix='ctf'):
    return f"{prefix}-{int(_utcnow().timestamp() * 1000)}"


def _public_citofono_call(call):
    if not call:
        return None
    return {
        'call_id': call.get('call_id'),
        'device_id': call.get('device_id'),
        'direction': call.get('direction'),
        'state': call.get('state'),
        'caller_rut': call.get('caller_rut'),
        'caller_dpto': call.get('caller_dpto'),
        'target_rut': call.get('target_rut'),
        'app_rut': call.get('app_rut'),
        'room': call.get('room'),
        'tipo': call.get('tipo', 'audio'),
        'created_at': _iso(call.get('created_at')),
        'answered_at': _iso(call.get('answered_at')),
        'ended_at': _iso(call.get('ended_at')),
        'end_reason': call.get('end_reason'),
    }


def _emit_citofono_event(call, event='citofono-call-state'):
    if not call:
        return
    payload = _public_citofono_call(call)
    app_rut = call.get('app_rut') or call.get('caller_rut') or call.get('room')
    if app_rut:
        socketio.emit(event, payload, to=app_rut)


def _set_user_busy_for_call(call, ocupado):
    if not call:
        return
    app_rut = call.get('app_rut') or call.get('caller_rut')
    if app_rut:
        if ocupado:
            ruts_en_llamada.add(app_rut)
        else:
            ruts_en_llamada.discard(app_rut)
        socketio.emit('user-status', {'rut': app_rut, 'ocupado': bool(ocupado)})
    if ocupado:
        ruts_en_llamada.add(CITOFONO_RUT)
    else:
        ruts_en_llamada.discard(CITOFONO_RUT)
    socketio.emit('user-status', {'rut': CITOFONO_RUT, 'ocupado': bool(ocupado)})


def _save_call_history_safely(call, estado='finalizada', duracion=None):
    if not call:
        return None
    try:
        rut_emisor = call.get('caller_rut') or CITOFONO_RUT
        rut_receptor = call.get('target_rut') or call.get('app_rut') or ''
        if _is_citofono_value(rut_emisor):
            rut_emisor = CITOFONO_RUT
        if _is_citofono_value(rut_receptor):
            rut_receptor = CITOFONO_RUT
        if not rut_emisor or not rut_receptor:
            return None
        if duracion is None:
            start = call.get('answered_at') or call.get('created_at') or _utcnow()
            end = call.get('ended_at') or _utcnow()
            duracion = max(0, int((end - start).total_seconds()))
        nueva = HistorialLlamadas(
            rut_emisor=rut_emisor,
            rut_receptor=rut_receptor,
            tipo_llamada=call.get('tipo', 'audio'),
            estado=estado,
            duracion_segundos=int(duracion or 0),
        )
        db.session.add(nueva)
        db.session.commit()
        return nueva.id
    except Exception as e:
        db.session.rollback()
        print(f'[CITOFONO] No se pudo guardar historial: {e}')
        return None


def _expire_citofono_call_if_needed(device_id):
    global _citofono_calls, _citofono_last_ended_calls
    call = _citofono_calls.get(device_id)
    if not call or call.get('state') != 'ringing':
        return call
    age = (_utcnow() - call.get('created_at', _utcnow())).total_seconds()
    if age <= CITOFONO_RING_TIMEOUT_SECONDS:
        return call
    call['state'] = 'ended'
    call['ended_at'] = _utcnow()
    call['end_reason'] = 'timeout'
    _set_user_busy_for_call(call, False)
    _emit_citofono_event(call, 'citofono-timeout')
    _emit_citofono_event(call, 'end-call')
    _save_call_history_safely(call, estado='perdida', duracion=0)
    _citofono_last_ended_calls[device_id] = call.copy()
    _citofono_calls.pop(device_id, None)
    return None


def _start_citofono_call_from_app(caller_rut, caller_dpto, target_device_id, target_rut=None):
    global _citofono_calls
    caller_rut = _norm_rut(caller_rut)
    target_rut = _norm_rut(target_rut) if target_rut else CITOFONO_RUT
    if not caller_rut:
        return jsonify({'success': False, 'error': 'Falta caller_rut para llamar al citófono'}), 400

    _citofono_lock.acquire()
    try:
        _expire_citofono_call_if_needed(target_device_id)
        existing_call = _citofono_calls.get(target_device_id)
        if existing_call and existing_call.get('state') in ('ringing', 'active'):
            return jsonify({'success': False, 'error': 'Citófono ocupado', 'busy': True}), 409

        now = _utcnow()
        new_call = {
            'call_id': _new_call_id('app-ctf'),
            'device_id': target_device_id,
            'direction': 'app_to_citofono',
            'state': 'ringing',
            'caller_rut': caller_rut,
            'caller_dpto': caller_dpto or caller_rut,
            'target_rut': target_rut,
            'app_rut': caller_rut,
            'room': caller_rut,
            'tipo': 'audio',
            'created_at': now,
            'answered_at': None,
            'ended_at': None,
            'end_reason': None,
        }
        _citofono_calls[target_device_id] = new_call
        call = new_call.copy()
    finally:
        _citofono_lock.release()

    _set_user_busy_for_call(call, True)
    _emit_citofono_event(call, 'citofono-call-state')
    print(f"[CITOFONO] app -> kit ringing call_id={call['call_id']} caller={caller_rut} device_id={target_device_id}")
    return jsonify({'success': True, 'citofono': True, 'call_id': call['call_id'], 'state': 'ringing'})


def _register_citofono_call_to_app(target_rut, caller_rut, caller_dpto, caller_device_id):
    # Citófono físico llama a una app. Se genera call_id para que la app pueda
    # contestar/rechazar/colgar y para que el ESP32 pueda enterarse por polling.
    global _citofono_calls
    target_rut = _norm_rut(target_rut)
    now = _utcnow()
    _citofono_lock.acquire()
    try:
        _expire_citofono_call_if_needed(caller_device_id)
        new_call = {
            'call_id': _new_call_id('ctf-app'),
            'device_id': caller_device_id,
            'direction': 'citofono_to_app',
            'state': 'ringing',
            'caller_rut': caller_rut,
            'caller_dpto': caller_dpto or 'Citófono',
            'target_rut': target_rut,
            'app_rut': target_rut,
            'room': target_rut,
            'tipo': 'audio',
            'created_at': now,
            'answered_at': None,
            'ended_at': None,
            'end_reason': None,
        }
        _citofono_calls[caller_device_id] = new_call
        call = new_call.copy()
    finally:
        _citofono_lock.release()
    _set_user_busy_for_call(call, True)
    return call


def _find_device_id_for_call(call_id):
    for did, call in _citofono_calls.items():
        if call.get('call_id') == call_id:
            return did
    return None

def _answer_citofono_call(call_id, answered_by='esp32'):
    global _citofono_calls
    _citofono_lock.acquire()
    try:
        device_id = _find_device_id_for_call(call_id)
        if not device_id:
            return None, 'Llamada no encontrada o expirada'
        
        call = _expire_citofono_call_if_needed(device_id)
        if not call:
            return None, 'Llamada expirada'
            
        if call.get('state') == 'active':
            return call.copy(), None
        if call.get('state') != 'ringing':
            return None, 'La llamada no está sonando'
            
        call['state'] = 'active'
        call['answered_at'] = _utcnow()
        call['answered_by'] = answered_by
        _citofono_calls[device_id] = call
        out = call.copy()
    finally:
        _citofono_lock.release()
        
    _set_user_busy_for_call(out, True)
    _emit_citofono_event(out, 'citofono-answered')
    _emit_citofono_event(out, 'citofono-call-state')
    print(f"[CITOFONO] answered call_id={out['call_id']} by={answered_by}")
    return out, None


def _end_citofono_call(call_id=None, reason='finalizada', estado='finalizada', duracion=None, notify=True, target_device_id=None):
    global _citofono_calls, _citofono_last_ended_calls
    _citofono_lock.acquire()
    try:
        device_id = target_device_id
        if not device_id and call_id:
            device_id = _find_device_id_for_call(call_id)
            
        if not device_id:
            # Fallback if we don't know the device ID but need to clear by target
            for did, c in list(_citofono_calls.items()):
                if c.get('call_id') == call_id or not call_id:
                    device_id = did
                    break
                    
        if not device_id or device_id not in _citofono_calls:
            return None
            
        call = _citofono_calls[device_id]
        if call_id and call.get('call_id') != call_id:
            return None
            
        call['state'] = 'ended'
        call['ended_at'] = _utcnow()
        call['end_reason'] = reason
        ended = call.copy()
        _citofono_last_ended_calls[device_id] = ended.copy()
        _citofono_calls.pop(device_id, None)
    finally:
        _citofono_lock.release()

    _set_user_busy_for_call(ended, False)
    if notify:
        _emit_citofono_event(ended, 'end-call')
        _emit_citofono_event(ended, 'citofono-call-state')
    history_id = _save_call_history_safely(ended, estado=estado, duracion=duracion)
    print(f"[CITOFONO] ended call_id={ended['call_id']} reason={reason}")
    ended['history_id'] = history_id
    return ended

# ─── LOGIN ────────────────────────────────────
@app.route("/login", methods=["POST"])
def login():
    debug_info = {
        "stage": "start",
        "rut_raw": None,
        "rut_normalizado": None,
        "tiene_usuario": None,
        "password_ok": None,
        "exception": None,
    }

    try:
        data = request.get_json(silent=True) or {}
        print("📥 Payload recibido en /login:", data)
        debug_info["payload"] = data

        # Campos que llegan desde la app
        rut_raw = (data.get("rut")
                   or data.get("rut_usuario")
                   or data.get("usuario")
                   or "")
        clave_raw = (data.get("password")
                     or data.get("clave")
                     or "")

        # Normalizar RUT
        rut = (rut_raw
               .replace(".", "")
               .replace("-", "")
               .strip()
               .upper())
        clave = clave_raw.strip()

        debug_info["rut_raw"] = rut_raw
        debug_info["rut_normalizado"] = rut
        debug_info["stage"] = "after_normalize"
        print(f"🔎 Buscando usuario con rut_normalizado='{rut}'")

        # 1) Buscar solo por RUT
        usuario = Usuario.query.filter_by(rut_usuario=rut).first()
        debug_info["tiene_usuario"] = bool(usuario)

        if not usuario:
            debug_info["stage"] = "no_user"
            print("❌ No se encontró usuario con ese RUT. Muestra algunos registros:")
            for u in Usuario.query.limit(5).all():
                print(f"   - BD: rut='{u.rut_usuario}'")
            resp = {
                "success": False,
                "error": "Credenciales inválidas",
            }
            if DEBUG_LOGIN:
                resp["debug"] = debug_info
            return jsonify(resp), 401

        debug_info["stage"] = "before_password_verify"
        print(f"👤 Usuario encontrado en BD: rut='{usuario.rut_usuario}'")

        # 2) Verificar la contraseña contra el hash Argon2
        try:
            ok = ph.verify(usuario.clave_app, clave)
            debug_info["password_ok"] = bool(ok)
            print(f"🔐 Resultado verificación password: {ok}")
            if not ok:
                debug_info["stage"] = "password_mismatch"
                resp = {
                    "success": False,
                    "error": "Credenciales inválidas",
                }
                if DEBUG_LOGIN:
                    resp["debug"] = debug_info
                return jsonify(resp), 401
        except VerifyMismatchError:
            debug_info["stage"] = "password_mismatch_exception"
            debug_info["password_ok"] = False
            print("❌ Contraseña incorrecta (VerifyMismatchError)")
            resp = {
                "success": False,
                "error": "Credenciales inválidas",
            }
            if DEBUG_LOGIN:
                resp["debug"] = debug_info
            return jsonify(resp), 401
        except Exception as e:
            debug_info["stage"] = "password_verify_exception"
            debug_info["exception"] = str(e)
            print(f"⚠️ Error al verificar hash Argon2: {e}")
            resp = {
                "success": False,
                "error": "Error interno al verificar credenciales",
            }
            if DEBUG_LOGIN:
                resp["debug"] = debug_info
            return jsonify(resp), 500

        debug_info["stage"] = "success"
        print(f"✅ Login correcto para RUT {usuario.rut_usuario}")

        resp = {
            "success": True,
            "rut": usuario.rut_usuario,
            "nombre": usuario.nombres,
            "apellido": usuario.apellido_1,
            "img": usuario.img_perfil,
            "dpto": usuario.id_dpto,
            "es_admin": usuario.es_admin
        }
        if DEBUG_LOGIN:
            resp["debug"] = debug_info
        return jsonify(resp)

    except Exception as e:
        debug_info["stage"] = "outer_exception"
        debug_info["exception"] = str(e)
        print(f"💥 Excepción general en /login: {e}")
        resp = {
            "success": False,
            "error": "Error interno en login",
        }
        if DEBUG_LOGIN:
            resp["debug"] = debug_info
        return jsonify(resp), 500

@app.route("/debug-usuarios", methods=["GET"])
def debug_usuarios():
    usuarios = Usuario.query.limit(10).all()
    return jsonify([
        {
            "rut_usuario": u.rut_usuario,
            "clave_app": u.clave_app,
            "nombres": u.nombres
        }
        for u in usuarios
    ])

# ─── FCM TOKEN ────────────────────────────────
rut_to_token = {}

@app.route("/registrar-token", methods=["POST"])
def registrar_token():
    data = request.json
    rut = _norm_rut(data.get("rut"))
    token = data.get("token")
    if not rut or not token:
        return jsonify({"error": "Faltan datos"}), 400
    rut_to_token[rut] = token
    print(f"✅ Token registrado: {rut}")
    return jsonify({"success": True})


def _validar_llamada_roles(caller_rut, target_rut):
    """
    Regla de llamadas ACTUALIZADA: Intercomunicación total (todos con todos).
    """
    caller = Usuario.query.filter_by(rut_usuario=_norm_rut(caller_rut)).first()
    target = Usuario.query.filter_by(rut_usuario=_norm_rut(target_rut)).first()

    if not caller:
        return False, 'Emisor de llamada no encontrado'
    if not target:
        return False, 'Receptor de llamada no encontrado'

    # ELIMINAMOS la restricción que bloqueaba llamadas entre residentes.
    # Ahora es Todos con Todos.
    return True, None


@app.route("/llamar", methods=["POST"])
def llamar():
    data = request.json or {}
    rut = _norm_rut(data.get("rut", ""))
    tipo = (data.get("tipo", "video") or "video").strip().lower()
    caller_rut_raw = data.get("caller_rut", "")
    caller_rut = _norm_rut(caller_rut_raw)
    caller_dpto = data.get("caller_dpto", "") or ""
    
    destino = str(data.get("destino", "ambos")).strip().lower() # app, kit, ambos
    
    is_caller_citofono = _is_citofono_value(caller_rut_raw) or caller_rut == "99999999" or _is_citofono_value(caller_dpto)

    # --- NUEVO: Intercomunicación Total y Fix del ESP32 ---
    id_dpto_str = str(data.get("id_dpto", "")).strip()

    # FIX: El ESP32 envía el depto de destino dentro de "caller_dpto" por error en su firmware.
    if is_caller_citofono and not id_dpto_str and caller_dpto:
        id_dpto_str = caller_dpto
        caller_dpto = "Citófono" # Corregimos el nombre para que la notificación diga "Citófono"

    # Si viene un departamento de destino o RUT, resolvemos el usuario de destino
    if id_dpto_str or rut:
        if id_dpto_str == "000" or rut == "000":
            # Llamar a Conserjería
            target_user = Usuario.query.filter_by(es_admin=True).first()
            if not target_user:
                return jsonify({"success": False, "error": "No hay conserje registrado"}), 404
            rut = target_user.rut_usuario
            caller_dpto = caller_dpto or "Citófono"
        else:
            # 1. Si rut viene especificado y ya existe como usuario (ej: click desde el Directorio)
            direct_user = Usuario.query.filter_by(rut_usuario=_norm_rut(rut)).first() if rut else None
            if direct_user:
                target_user = direct_user
            else:
                # 2. Buscar por departamento (priorizando residente)
                target_user = Usuario.query.filter_by(id_dpto=id_dpto_str, es_admin=False).first()
                if not target_user:
                    target_user = Usuario.query.filter_by(id_dpto=id_dpto_str).first()
                # 3. Fallback: buscar si id_dpto_str era en realidad un RUT
                if not target_user:
                    target_user = Usuario.query.filter_by(rut_usuario=_norm_rut(id_dpto_str)).first()
            
            if not target_user:
                return jsonify({"success": False, "error": f"No se encontró usuario para el departamento {id_dpto_str or rut}"}), 404
            
            rut = target_user.rut_usuario
            caller_dpto = caller_dpto or "Citófono"

    # Determinar el device_id del caller (si es un kit)
    caller_device_id = CITOFONO_DEVICE_ID if is_caller_citofono else caller_rut

    # Caso 1: Forzamos la llamada al KIT del destino
    if destino == "kit" or _is_citofono_value(rut): 
        target_device_id = CITOFONO_DEVICE_ID if _is_citofono_value(rut) else rut
        return _start_citofono_call_from_app(caller_rut, caller_dpto, target_device_id, target_rut=rut)

    # Validación de roles (SOLO si NO es el citófono físico el que origina la llamada)
    if not is_caller_citofono:
        ok_roles, role_error = _validar_llamada_roles(caller_rut, rut)
        if not ok_roles:
            return jsonify({"success": False, "error": role_error}), 403

    print(f"📞 Buscando token para RUT: {rut}")
    print(f"📄 RUTs registrados en rut_to_token: {list(rut_to_token.keys())}")

    token = rut_to_token.get(rut)

    call_id = None
    caller_is_citofono = _is_citofono_value(caller_rut_raw) or _is_citofono_value(caller_dpto)
    
    # Si el que llama es un Kit, registramos la llamada para que el Kit sepa el estado
    if tipo == "audio" and caller_is_citofono:
        call = _register_citofono_call_to_app(rut, caller_rut, caller_dpto, caller_device_id)
        call_id = call.get('call_id')
        caller_rut = CITOFONO_RUT
        caller_dpto = call.get('caller_dpto') or 'Citófono'
        
    # Si el destino es "ambos", también registramos una llamada al Kit del destinatario
    if destino == "ambos" and not _is_citofono_value(rut):
        # Hacer sonar el kit del destino al mismo tiempo (usando el rut del destino como device_id)
        target_device_id = CITOFONO_DEVICE_ID if rut == CITOFONO_RUT else rut
        # Importante: Registramos la llamada para que el ESP32 del destino haga polling y timbre
        call = _register_citofono_call_to_app(rut, caller_rut, caller_dpto, target_device_id)
        if not call_id:
            call_id = call.get('call_id')

    # No enviar Socket ni Push a la App si el destino es SOLO kit
    # (En esta ruta ya retornamos arriba si destino == "kit")

    socket_payload = {
        'type': 'call',
        'caller_rut': caller_rut,
        'caller_dpto': caller_dpto,
        'tipo': tipo,
    }
    if call_id:
        socket_payload['call_id'] = call_id
        socket_payload['target_rut'] = rut

    # 1. Emitir por socket a la App
    socketio.emit('incoming-call', socket_payload, to=rut)
    norm_target = _norm_rut(rut)
    if norm_target and norm_target != rut:
        socketio.emit('incoming-call', socket_payload, to=norm_target)

    # 2. Notificar vía FCM
    if not token:
        print(f"⚠️ No hay token FCM para {rut}. Solo notificado por Socket.IO.")
        resp = {"success": True, "warning": "Sin token FCM"}
        if call_id:
            resp["call_id"] = call_id
            resp["citofono"] = True
        return jsonify(resp)

    try:
        if tipo == "audio":
            titulo = "Llamada de audio"
            body = f"Llamada entrante de {caller_dpto if caller_dpto else caller_rut}"
            tipo_notificacion = "audio"
        else:
            titulo = "Videollamada"
            body = f"Videollamada entrante de {caller_dpto if caller_dpto else caller_rut}"
            tipo_notificacion = "video"

        fcm_data = {
            "type": "call",
            "rut": rut,
            "caller_rut": caller_rut,
            "caller_dpto": caller_dpto,
            "tipo": tipo_notificacion,
            "click_action": "FLUTTER_NOTIFICATION_CLICK"
        }
        if call_id:
            fcm_data["call_id"] = call_id
            fcm_data["target_rut"] = rut

        mensaje = messaging.Message(
            token=token,
            notification=messaging.Notification(
                title=titulo,
                body=body
            ),
            data=fcm_data,
            android=messaging.AndroidConfig(
                priority="high",
                ttl=0,
                notification=messaging.AndroidNotification(
                    channel_id="calls_channel_v5",
                    priority="high",
                    sound="default"
                )
            )
        )
        response = messaging.send(mensaje)
        print(f"✅ Notificación enviada ({tipo_notificacion}): {response}")
        resp = {"success": True}
        if call_id:
            resp["call_id"] = call_id
            resp["citofono"] = True
        return jsonify(resp)
    except Exception as e:
        print(f"❌ Error al enviar notificación: {e}")
        if call_id:
            _end_citofono_call(call_id=call_id, reason='fcm_error', estado='perdida', duracion=0, notify=False)
        return jsonify({"error": str(e)}), 500

# ─── USUARIOS ────────────────────────────────
@app.route("/usuarios-conserjes", methods=["GET"])
def usuarios_conserjes():
    conserjes = Usuario.query.filter_by(es_admin=True).all()
    return jsonify([{
        "rut_usuario": u.rut_usuario,
        "nombres": u.nombres,
        "apellido_1": u.apellido_1,
        "id_dpto": u.id_dpto,
        "es_admin": u.es_admin
    } for u in conserjes])

@app.route("/usuarios-todos", methods=["GET"])
def usuarios_todos():
    # Se eliminaron los filtros: ahora se muestran todos los usuarios (residentes y conserjes)
    usuarios = Usuario.query.all()

    return jsonify([{
        "rut_usuario": u.rut_usuario,
        "nombres": u.nombres,
        "apellido_1": u.apellido_1,
        "id_dpto": u.id_dpto,
        "es_admin": u.es_admin
    } for u in usuarios])


def _usuario_chat_payload(u, unread=0, last_message=None):
    if not u:
        return {}
    es_admin = bool(u.es_admin)
    unidad = '' if es_admin else str(u.id_dpto or '').strip()
    nombre = ' '.join([str(u.nombres or '').strip(), str(u.apellido_1 or '').strip()]).strip()
    if es_admin:
        etiqueta = nombre or 'Conserjería'
        unidad_label = 'Conserjería'
    else:
        unidad_label = f"Depto/Casa {unidad}" if unidad else 'Depto/Casa'
        etiqueta = f"{unidad_label} - {nombre}" if nombre else unidad_label
    return {
        'rut_usuario': u.rut_usuario,
        'nombres': u.nombres,
        'apellido_1': u.apellido_1,
        'id_dpto': u.id_dpto,
        'es_admin': u.es_admin,
        'unidad_label': unidad_label,
        'display_name': etiqueta,
        'unread': int(unread or 0),
        'last_message': last_message,
    }


def _chat_message_payload(m):
    return {
        'id': m.id,
        'rut_emisor': m.rut_emisor,
        'rut_receptor': m.rut_receptor,
        'mensaje': m.mensaje,
        'fecha_hora': m.fecha_hora.isoformat() if m.fecha_hora else None,
        'leido': bool(m.leido),
        'es_imagen': bool(getattr(m, 'es_imagen', False)),
    }


def _normaliza_chat_rut(value):
    return _norm_rut(value)


@app.route('/api/chat/contactos', methods=['GET'])
def chat_contactos():
    rut = _normaliza_chat_rut(request.args.get('rut', ''))
    if not rut:
        return jsonify({'success': False, 'error': 'Falta rut'}), 400

    solicitante = Usuario.query.filter_by(rut_usuario=rut).first()
    if not solicitante:
        return jsonify({'success': False, 'error': 'Usuario no encontrado'}), 404

    usuarios = Usuario.query.filter(Usuario.rut_usuario != rut).order_by(Usuario.es_admin.desc(), Usuario.id_dpto.asc(), Usuario.nombres.asc()).all()

    unread_counts = {}
    try:
        rows = db.session.query(ChatMensaje.rut_emisor, db.func.count(ChatMensaje.id)).filter(
            ChatMensaje.rut_receptor == rut,
            ChatMensaje.leido == 0,
        ).group_by(ChatMensaje.rut_emisor).all()
        unread_counts = {sender: count for sender, count in rows}
    except Exception:
        unread_counts = {}

    return jsonify({
        'success': True,
        'rut': rut,
        'unidad_label': _usuario_chat_payload(solicitante).get('unidad_label'),
        'contactos': [_usuario_chat_payload(u, unread_counts.get(u.rut_usuario, 0)) for u in usuarios],
    })


@app.route('/api/chat/messages', methods=['GET'])
def chat_get_messages():
    rut = _normaliza_chat_rut(request.args.get('rut', ''))
    peer = _normaliza_chat_rut(request.args.get('peer', ''))
    limit = request.args.get('limit', '50')
    after_id = request.args.get('after_id', '')

    try:
        limit = max(1, min(int(limit), 100))
    except Exception:
        limit = 50

    if not rut or not peer:
        return jsonify({'success': False, 'error': 'Falta rut o peer'}), 400

    if not Usuario.query.filter_by(rut_usuario=rut).first():
        return jsonify({'success': False, 'error': 'Usuario no encontrado'}), 404
    if not Usuario.query.filter_by(rut_usuario=peer).first():
        return jsonify({'success': False, 'error': 'Destino no encontrado'}), 404

    q = ChatMensaje.query.filter(
        db.or_(
            db.and_(ChatMensaje.rut_emisor == rut, ChatMensaje.rut_receptor == peer),
            db.and_(ChatMensaje.rut_emisor == peer, ChatMensaje.rut_receptor == rut),
        )
    )
    if after_id:
        try:
            q = q.filter(ChatMensaje.id > int(after_id))
        except Exception:
            pass

    mensajes = q.order_by(ChatMensaje.fecha_hora.desc(), ChatMensaje.id.desc()).limit(limit).all()
    mensajes = list(reversed(mensajes))

    try:
        ChatMensaje.query.filter_by(rut_emisor=peer, rut_receptor=rut, leido=0).update({'leido': 1})
        db.session.commit()
    except Exception:
        db.session.rollback()

    return jsonify({
        'success': True,
        'rut': rut,
        'peer': peer,
        'messages': [_chat_message_payload(m) for m in mensajes],
    })


def _send_chat_push(receptor_rut, emisor, receptor, mensaje_payload):
    token = rut_to_token.get(_norm_rut(receptor_rut))
    if not token:
        print(f"⚠️ Sin token FCM para mensaje a {receptor_rut}")
        return False

    body = str(mensaje_payload.get('mensaje') or '').strip()
    if len(body) > 120:
        body = body[:117] + '...'

    sender_label = _usuario_chat_payload(emisor).get('display_name') or emisor.rut_usuario
    receiver_label = _usuario_chat_payload(receptor).get('display_name') or receptor.rut_usuario

    data = {
        'type': 'chat_message',
        'rut_emisor': str(mensaje_payload.get('rut_emisor') or ''),
        'rut_receptor': str(mensaje_payload.get('rut_receptor') or ''),
        'mensaje': str(mensaje_payload.get('mensaje') or ''),
        'sender_label': str(sender_label),
        'receiver_label': str(receiver_label),
        'message_id': str(mensaje_payload.get('id') or ''),
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
    }

    try:
        msg = messaging.Message(
            token=token,
            data=data,
            android=messaging.AndroidConfig(priority='high', ttl=0),
        )
        response = messaging.send(msg)
        print(f"✅ Push mensaje enviado a {receptor_rut}: {response}")
        return True
    except Exception as e:
        print(f"❌ Error push mensaje a {receptor_rut}: {e}")
        return False

@app.route('/api/chat/messages', methods=['POST'])
def chat_send_message():
    data = request.get_json(silent=True) or {}
    rut_emisor = _normaliza_chat_rut(data.get('rut_emisor') or data.get('from') or data.get('sender'))
    rut_receptor = _normaliza_chat_rut(data.get('rut_receptor') or data.get('to') or data.get('receiver'))
    mensaje = str(data.get('mensaje') or data.get('message') or '').strip()

    if not rut_emisor or not rut_receptor or not mensaje:
        return jsonify({'success': False, 'error': 'Falta emisor, receptor o mensaje'}), 400
    if len(mensaje) > 1000:
        mensaje = mensaje[:1000]

    emisor = Usuario.query.filter_by(rut_usuario=rut_emisor).first()
    receptor = Usuario.query.filter_by(rut_usuario=rut_receptor).first()
    if not emisor:
        return jsonify({'success': False, 'error': 'Emisor no encontrado'}), 404
    if not receptor:
        return jsonify({'success': False, 'error': 'Receptor no encontrado'}), 404

    nuevo = ChatMensaje(
        rut_emisor=rut_emisor,
        rut_receptor=rut_receptor,
        mensaje=mensaje,
        leido=0,
    )
    db.session.add(nuevo)
    db.session.commit()

    payload = _chat_message_payload(nuevo)
    payload['type'] = 'chat_message'
    payload['sender_label'] = _usuario_chat_payload(emisor).get('display_name')
    payload['receiver_label'] = _usuario_chat_payload(receptor).get('display_name')

    socketio.emit('chat-message', payload, to=rut_emisor)
    socketio.emit('chat-message', payload, to=rut_receptor)

    if rut_receptor != rut_emisor:
        _send_chat_push(rut_receptor, emisor, receptor, payload)

    return jsonify({'success': True, 'message': payload})


@app.route('/api/chat/upload', methods=['POST'])
def chat_upload_image():
    if 'file' not in request.files:
        return jsonify({'success': False, 'error': 'No file part'}), 400
    file = request.files['file']
    if file.filename == '':
        return jsonify({'success': False, 'error': 'No selected file'}), 400

    rut_emisor = _normaliza_chat_rut(request.form.get('rut_emisor') or '')
    rut_receptor = _normaliza_chat_rut(request.form.get('rut_receptor') or '')

    if not rut_emisor or not rut_receptor:
        return jsonify({'success': False, 'error': 'Falta emisor o receptor'}), 400

    emisor = Usuario.query.filter_by(rut_usuario=rut_emisor).first()
    receptor = Usuario.query.filter_by(rut_usuario=rut_receptor).first()
    if not emisor or not receptor:
        return jsonify({'success': False, 'error': 'Usuario no encontrado'}), 404

    filename = secure_filename(file.filename)
    unique_filename = f"{uuid.uuid4().hex}_{filename}"
    upload_dir = os.path.join(app.static_folder, 'uploads', 'chat')
    os.makedirs(upload_dir, exist_ok=True)
    upload_path = os.path.join(upload_dir, unique_filename)
    file.save(upload_path)

    image_url = f"/static/uploads/chat/{unique_filename}"

    nuevo = ChatMensaje(
        rut_emisor=rut_emisor,
        rut_receptor=rut_receptor,
        mensaje=image_url,
        leido=0,
        es_imagen=True
    )
    db.session.add(nuevo)
    db.session.commit()

    payload = _chat_message_payload(nuevo)
    payload['type'] = 'chat_message'
    payload['sender_label'] = _usuario_chat_payload(emisor).get('display_name')
    payload['receiver_label'] = _usuario_chat_payload(receptor).get('display_name')

    socketio.emit('chat-message', payload, to=rut_emisor)
    socketio.emit('chat-message', payload, to=rut_receptor)

    if rut_receptor != rut_emisor:
        _send_chat_push(rut_receptor, emisor, receptor, payload)

    return jsonify({'success': True, 'message': payload})


@app.route('/api/chat/unread-count', methods=['GET'])
def chat_unread_count():
    rut = _normaliza_chat_rut(request.args.get('rut', ''))
    if not rut:
        return jsonify({'success': False, 'error': 'Falta rut'}), 400
    total = db.session.query(db.func.count(ChatMensaje.id)).filter(
        ChatMensaje.rut_receptor == rut,
        ChatMensaje.leido == 0,
    ).scalar() or 0
    return jsonify({'success': True, 'rut': rut, 'unread': int(total)})

def get_nombre_by_rut(rut):
    if not rut or _is_citofono_value(rut):
        return "Citófono"
    u = Usuario.query.filter_by(rut_usuario=_norm_rut(rut)).first()
    if u:
        nombre = f"{u.nombres or ''} {u.apellido_1 or ''}".strip()
        return nombre if nombre else u.rut_usuario
    return rut

def get_nombre_contacto(l, my_rut):
    my_rut_norm = _norm_rut(my_rut)
    if _norm_rut(l.rut_emisor) == my_rut_norm:
        return get_nombre_by_rut(l.rut_receptor)
    return get_nombre_by_rut(l.rut_emisor)


@app.route("/historial", methods=["GET"])
def obtener_historial():
    rut = request.args.get("rut", "").strip().upper()
    if not rut:
        return jsonify({"error": "Falta el RUT"}), 400
    
    usuario = Usuario.query.filter_by(rut_usuario=rut).first()
    if not usuario:
        return jsonify({"error": "Usuario no encontrado"}), 404

    if usuario.es_admin:
        llamadas = HistorialLlamadas.query.order_by(HistorialLlamadas.fecha_hora.desc()).limit(6).all()
    else:
        llamadas = HistorialLlamadas.query.filter(
            db.or_(HistorialLlamadas.rut_emisor == rut, HistorialLlamadas.rut_receptor == rut)
        ).order_by(HistorialLlamadas.fecha_hora.desc()).limit(6).all()

    resultado = []
    for l in llamadas:
        direccion = "Saliente" if _norm_rut(l.rut_emisor) == _norm_rut(rut) else "Entrante"
        
        estado_final = l.estado.capitalize()
        if estado_final == "Finalizada" and l.duracion_segundos == 0:
            estado_final = "Perdida"
            
        resultado.append({
            "id": l.id,
            "fecha": l.fecha_hora.strftime('%d/%m %H:%M') if l.fecha_hora else '-',
            "tipo": f"{direccion} {l.tipo_llamada}", 
            "estado": estado_final,
            "nombre": get_nombre_contacto(l, rut),
            "duracion_segundos": l.duracion_segundos
        })

    return jsonify(resultado)

@app.route("/historial", methods=["POST"])
def guardar_historial():
    data = request.json
    rut_emisor = data.get("rut_emisor", "").strip().upper()
    rut_receptor = data.get("rut_receptor", "").strip().upper()
    tipo = data.get("tipo_llamada", "video")
    estado = data.get("estado", "finalizada")
    duracion = data.get("duracion_segundos", 0)

    if not rut_emisor or not rut_receptor:
        return jsonify({"error": "Faltan datos de emisor o receptor"}), 400

    nueva_llamada = HistorialLlamadas(
        rut_emisor=rut_emisor,
        rut_receptor=rut_receptor,
        tipo_llamada=tipo,
        estado=estado,
        duracion_segundos=duracion
    )
    db.session.add(nueva_llamada)
    db.session.commit()
    return jsonify({"success": True, "id": nueva_llamada.id})

@app.route("/setup-local", methods=["GET"])
def setup_local():
    if sys.platform != "win32":
        return "Solo disponible en entorno local (Windows)", 403
    
    if not Usuario.query.filter_by(rut_usuario="11111111").first():
        conserje = Usuario(
            rut_usuario="11111111", nombres="Conserje", apellido_1="Prueba",
            telefono="123456789", es_admin=1, clave_app=ph.hash("111")
        )
        db.session.add(conserje)
        
    if not Usuario.query.filter_by(rut_usuario="22222222").first():
        residente = Usuario(
            rut_usuario="22222222", nombres="Residente", apellido_1="Test",
            telefono="987654321", es_admin=0, id_dpto="101", clave_app=ph.hash("222")
        )
        db.session.add(residente)
        
    db.session.commit()
    return "Usuarios de prueba creados (Conserje: 11111111 / 111) (Residente: 22222222 / 222)"

# ─── WebRTC SOCKET.IO ────────────────────────
ruts_en_llamada = set() # { 'RUT_1', 'RUT_2' }
client_to_rut = {} # Mapa de request.sid a RUT para manejar desconexiones

@socketio.on('register')
def handle_register(data):
    room = data.get('room')
    if room:
        join_room(room)
        norm = _norm_rut(room)
        if norm and norm != room:
            join_room(norm)
        client_to_rut[request.sid] = room

@socketio.on('join-call')
def handle_join_call(data):
    room = data.get('room')
    mi_rut = data.get('mi_rut')  
    if room:
        join_room(room)
        
        rut_a_ocupar = mi_rut if mi_rut else room
        client_to_rut[request.sid] = rut_a_ocupar
        ruts_en_llamada.add(rut_a_ocupar)
        socketio.emit('user-status', {'rut': rut_a_ocupar, 'ocupado': True})
        
        emit('ready', {}, to=room, include_self=False)

@socketio.on('free-rut')
def handle_free_rut(data):
    rut = data.get('rut')
    if rut and rut in ruts_en_llamada:
        ruts_en_llamada.discard(rut)
        socketio.emit('user-status', {'rut': rut, 'ocupado': False})

@socketio.on('offer')
def handle_offer(data):
    emit('offer', data, to=data['room'], include_self=False)

@socketio.on('answer')
def handle_answer(data):
    emit('answer', data, to=data['room'], include_self=False)

@socketio.on('ice-candidate')
def handle_ice(data):
    emit('ice-candidate', data, to=data['room'], include_self=False)

@socketio.on('busy')
def handle_busy(data):
    emit('busy', data, to=data['room'], include_self=False)

@socketio.on('end-call')
def handle_end(data):
    rut = data.get('room')
    emit('end-call', {}, to=rut, include_self=False)
    if rut and rut in ruts_en_llamada:
        ruts_en_llamada.discard(rut)
        socketio.emit('user-status', {'rut': rut, 'ocupado': False})

@socketio.on('disconnect')
def handle_disconnect():
    sid = request.sid
    if sid in client_to_rut:
        rut = client_to_rut[sid]
        if rut in ruts_en_llamada:
            ruts_en_llamada.discard(rut)
            socketio.emit('user-status', {'rut': rut, 'ocupado': False})
        del client_to_rut[sid]

# ─── ENDPOINT: quiénes están en llamada ahora ──
@app.route('/usuarios-en-llamada', methods=['GET'])
def usuarios_en_llamada():
    return jsonify(list(ruts_en_llamada))


# --- ESP32 AUDIO BRIDGE ----------------------------------------------------
_esp32_tx_clients = set()      
_esp32_rx_clients = set()      
_browser_rx_clients = set()    
_browser_tx_clients = set()    
_audio_lock = Semaphore()

MAX_AUDIO_FRAME_BYTES = int(os.getenv('MAX_AUDIO_FRAME_BYTES', '2048'))

BROWSER_TX_SAMPLE_RATE = int(os.getenv('BROWSER_TX_SAMPLE_RATE', '8000'))
BROWSER_TX_FRAME_MS = int(os.getenv('BROWSER_TX_FRAME_MS', '20'))
BROWSER_TX_FRAME_BYTES = int(BROWSER_TX_SAMPLE_RATE * 2 * BROWSER_TX_FRAME_MS / 1000)  # 320 bytes
BROWSER_TX_MAX_QUEUE_BYTES = int(os.getenv('BROWSER_TX_MAX_QUEUE_BYTES', str(BROWSER_TX_FRAME_BYTES * 8)))  # 160 ms

_browser_to_esp32_queue = deque()
_browser_to_esp32_pacer_started = False
_browser_to_esp32_dropped = 0
_browser_to_esp32_forwarded = 0


def _safe_close_audio_ws(ws):
    try:
        ws.close()
    except Exception:
        pass


def _audio_counts_unsafe():
    return {
        'esp32_tx_clients': len(_esp32_tx_clients),
        'esp32_rx_clients': len(_esp32_rx_clients),
        'browser_rx_clients': len(_browser_rx_clients),
        'browser_tx_clients': len(_browser_tx_clients),
        'max_audio_frame_bytes': MAX_AUDIO_FRAME_BYTES,
        'browser_tx_sample_rate': BROWSER_TX_SAMPLE_RATE,
        'browser_tx_frame_bytes': BROWSER_TX_FRAME_BYTES,
        'browser_tx_frame_ms': BROWSER_TX_FRAME_MS,
        'browser_tx_mode': 'pcm16_mono_8khz',
        'browser_tx_queue_bytes': len(_browser_to_esp32_queue),
        'browser_tx_dropped_bytes': _browser_to_esp32_dropped,
        'browser_tx_forwarded_bytes': _browser_to_esp32_forwarded,
    }


def _print_audio_counts():
    _audio_lock.acquire()
    try:
        counts = _audio_counts_unsafe()
    finally:
        _audio_lock.release()
    print('[AUDIO] counts ' + ' '.join(f'{k}={v}' for k, v in counts.items()))


def _register_audio_ws(bucket, ws, label, single=False):
    old_clients = []
    _audio_lock.acquire()
    try:
        if single:
            old_clients = list(bucket)
            bucket.clear()
        bucket.add(ws)
    finally:
        _audio_lock.release()

    for old in old_clients:
        if old is not ws:
            print(f'[AUDIO] cerrando {label} anterior')
            _safe_close_audio_ws(old)

    print(f'[AUDIO] conectado role={label}')
    _print_audio_counts()


def _unregister_audio_ws(bucket, ws, label):
    _audio_lock.acquire()
    try:
        bucket.discard(ws)
    finally:
        _audio_lock.release()
    print(f'[AUDIO] desconectado role={label}')
    _print_audio_counts()


def _snapshot_audio_clients(bucket):
    _audio_lock.acquire()
    try:
        return list(bucket)
    finally:
        _audio_lock.release()


def _remove_dead_audio_client(bucket, ws):
    _audio_lock.acquire()
    try:
        bucket.discard(ws)
    finally:
        _audio_lock.release()


def _forward_audio(target_bucket, payload):
    if payload is None or isinstance(payload, str):
        return 0

    if not isinstance(payload, (bytes, bytearray, memoryview)):
        return 0

    payload = bytes(payload)

    if len(payload) > MAX_AUDIO_FRAME_BYTES:
        print(f'[AUDIO] frame descartado por tamano={len(payload)}')
        return 0

    sent = 0
    for client in _snapshot_audio_clients(target_bucket):
        try:
            client.send(payload)
            sent += 1
        except Exception as e:
            print(f'[AUDIO] relay fallo, removiendo cliente: {e}')
            _remove_dead_audio_client(target_bucket, client)
            _safe_close_audio_ws(client)
    return sent


def _ensure_browser_to_esp32_pacer():
    global _browser_to_esp32_pacer_started
    _audio_lock.acquire()
    try:
        if _browser_to_esp32_pacer_started:
            return
        _browser_to_esp32_pacer_started = True
    finally:
        _audio_lock.release()

    eventlet.spawn_n(_browser_to_esp32_pacer_loop)
    print('[AUDIO] browser_tx pacer iniciado ' +
          f'frame={BROWSER_TX_FRAME_BYTES}B cada {BROWSER_TX_FRAME_MS}ms ' +
          f'queue_max={BROWSER_TX_MAX_QUEUE_BYTES}B')


def _enqueue_browser_audio_for_esp32(payload):
    global _browser_to_esp32_dropped

    if payload is None or isinstance(payload, str):
        return 0

    if not isinstance(payload, (bytes, bytearray, memoryview)):
        return 0

    payload = bytes(payload)
    if len(payload) > MAX_AUDIO_FRAME_BYTES:
        print(f'[AUDIO] browser_tx frame descartado por tamano={len(payload)}')
        return 0

    usable = len(payload) - (len(payload) % 2)
    if usable <= 0:
        return 0

    start = max(0, usable - BROWSER_TX_MAX_QUEUE_BYTES)
    if start:
        _browser_to_esp32_dropped += start

    data = payload[start:usable]

    _audio_lock.acquire()
    try:
        while len(_browser_to_esp32_queue) + len(data) > BROWSER_TX_MAX_QUEUE_BYTES and _browser_to_esp32_queue:
            _browser_to_esp32_queue.popleft()
            _browser_to_esp32_dropped += 1
        _browser_to_esp32_queue.extend(data)
        qlen = len(_browser_to_esp32_queue)
    finally:
        _audio_lock.release()

    return qlen


def _pop_browser_to_esp32_frame():
    _audio_lock.acquire()
    try:
        if len(_browser_to_esp32_queue) < BROWSER_TX_FRAME_BYTES:
            return None
        frame = bytearray(BROWSER_TX_FRAME_BYTES)
        for i in range(BROWSER_TX_FRAME_BYTES):
            frame[i] = _browser_to_esp32_queue.popleft()
        return bytes(frame)
    finally:
        _audio_lock.release()


def _browser_to_esp32_pacer_loop():
    global _browser_to_esp32_forwarded
    period = BROWSER_TX_FRAME_MS / 1000.0
    while True:
        try:
            frame = _pop_browser_to_esp32_frame()
            if frame is not None:
                sent = _forward_audio(_esp32_rx_clients, frame)
                if sent:
                    _browser_to_esp32_forwarded += len(frame)
            eventlet.sleep(period)
        except Exception as e:
            print(f'[AUDIO] browser_tx pacer error: {e}')
            eventlet.sleep(period)


def _hold_audio_rx_socket(ws, bucket, label, single=False):
    _register_audio_ws(bucket, ws, label, single=single)
    try:
        while True:
            msg = ws.receive()
            if msg is None:
                break
    except Exception as e:
        print(f'[AUDIO] {label} cerrado/error: {e}')
    finally:
        _unregister_audio_ws(bucket, ws, label)


@sock.route('/esp32_tx')
def ws_esp32_tx(ws):
    _register_audio_ws(_esp32_tx_clients, ws, 'esp32_tx', single=True)
    try:
        while True:
            payload = ws.receive()
            if payload is None:
                break
            _forward_audio(_browser_rx_clients, payload)
    except Exception as e:
        print(f'[AUDIO] esp32_tx cerrado/error: {e}')
    finally:
        _unregister_audio_ws(_esp32_tx_clients, ws, 'esp32_tx')


@sock.route('/esp32_rx')
def ws_esp32_rx(ws):
    _hold_audio_rx_socket(ws, _esp32_rx_clients, 'esp32_rx', single=True)


@sock.route('/browser_rx')
def ws_browser_rx(ws):
    _hold_audio_rx_socket(ws, _browser_rx_clients, 'browser_rx', single=False)


@sock.route('/browser_tx')
def ws_browser_tx(ws):
    _ensure_browser_to_esp32_pacer()
    _register_audio_ws(_browser_tx_clients, ws, 'browser_tx', single=False)
    try:
        while True:
            payload = ws.receive()
            if payload is None:
                break
            _enqueue_browser_audio_for_esp32(payload)
    except Exception as e:
        print(f'[AUDIO] browser_tx cerrado/error: {e}')
    finally:
        _unregister_audio_ws(_browser_tx_clients, ws, 'browser_tx')


@app.route('/api/esp32/audio-status', methods=['GET'])
def esp32_audio_status():
    _audio_lock.acquire()
    try:
        return jsonify(_audio_counts_unsafe())
    finally:
        _audio_lock.release()


@app.route('/api/esp32/poll', methods=['GET'])
def esp32_poll_call_state():
    device_id = request.args.get('device_id', CITOFONO_DEVICE_ID).strip() or CITOFONO_DEVICE_ID
    current_call_id = request.args.get('call_id', '').strip()

    _citofono_lock.acquire()
    try:
        call = _expire_citofono_call_if_needed(device_id)
        last_ended = _citofono_last_ended_calls.get(device_id)
        if last_ended:
            last_ended = last_ended.copy()
        call_copy = call.copy() if call else None
    finally:
        _citofono_lock.release()

    if call_copy and call_copy.get('device_id') == device_id:
        state = call_copy.get('state')
        direction = call_copy.get('direction')
        if direction == 'app_to_citofono' and state == 'ringing':
            payload = _public_citofono_call(call_copy)
            payload['success'] = True
            payload['action'] = 'incoming_call'
            return jsonify(payload)
        if state == 'active':
            payload = _public_citofono_call(call_copy)
            payload['success'] = True
            payload['action'] = 'active'
            return jsonify(payload)
        payload = _public_citofono_call(call_copy)
        payload['success'] = True
        payload['action'] = 'none'
        return jsonify(payload)

    if last_ended and current_call_id and last_ended.get('device_id') == device_id:
        if last_ended.get('call_id') == current_call_id:
            payload = _public_citofono_call(last_ended)
            payload['success'] = True
            payload['action'] = 'end_call'
            return jsonify(payload)

    return jsonify({'success': True, 'action': 'idle', 'device_id': device_id})


@app.route('/api/esp32/answer-call', methods=['POST'])
def esp32_answer_call():
    data = request.get_json(silent=True) or {}
    call_id = (data.get('call_id') or '').strip()
    call, err = _answer_citofono_call(call_id, answered_by='esp32')
    if err:
        return jsonify({'success': False, 'error': err}), 409
    return jsonify({'success': True, 'call': _public_citofono_call(call)})


@app.route('/api/citofono/app-answer', methods=['POST'])
def citofono_app_answer():
    data = request.get_json(silent=True) or {}
    call_id = (data.get('call_id') or '').strip()
    call, err = _answer_citofono_call(call_id, answered_by='app')
    if err:
        return jsonify({'success': False, 'error': err}), 409
    return jsonify({'success': True, 'call': _public_citofono_call(call)})


@app.route('/api/esp32/reject-call', methods=['POST'])
def esp32_reject_call():
    data = request.get_json(silent=True) or {}
    call_id = (data.get('call_id') or '').strip()
    ended = _end_citofono_call(call_id=call_id, reason='rejected', estado='rechazada', duracion=0)
    if not ended:
        return jsonify({'success': False, 'error': 'No hay llamada para rechazar'}), 404
    return jsonify({'success': True, 'call': _public_citofono_call(ended)})


@app.route('/api/citofono/state', methods=['GET'])
def citofono_state():
    call_id = (request.args.get('call_id') or '').strip()
    _citofono_lock.acquire()
    try:
        device_id = _find_device_id_for_call(call_id) if call_id else CITOFONO_DEVICE_ID
        call = _expire_citofono_call_if_needed(device_id) if device_id else None
        call_copy = call.copy() if call else None
        if not call_copy and call_id:
            for did, ended in _citofono_last_ended_calls.items():
                if ended.get('call_id') == call_id:
                    call_copy = ended.copy()
                    break
    finally:
        _citofono_lock.release()
    return jsonify({'success': True, 'call': _public_citofono_call(call_copy)})


@app.route('/api/esp32/end-call', methods=['POST'])
def esp32_end_call():
    data = request.get_json(silent=True) or {}
    call_id = (data.get('call_id') or '').strip()
    room = (data.get('room') or data.get('rut') or data.get('rut_receptor') or '').strip().upper()
    rut_emisor = (data.get('rut_emisor') or '').strip().upper()
    rut_receptor = (data.get('rut_receptor') or room or '').strip().upper()
    tipo = data.get('tipo_llamada', 'audio')
    estado = data.get('estado', 'finalizada')
    duracion = int(data.get('duracion_segundos') or 0)
    reason = data.get('reason') or estado or 'finalizada'

    ended = None
    if call_id or _is_citofono_value(room) or _is_citofono_value(rut_emisor) or _is_citofono_value(rut_receptor):
        ended = _end_citofono_call(call_id=call_id or None, reason=reason, estado=estado, duracion=duracion)

    if room:
        socketio.emit('end-call', {'call_id': call_id, 'room': room}, to=room)
        ruts_en_llamada.discard(room)
        socketio.emit('user-status', {'rut': room, 'ocupado': False})

    history_id = ended.get('history_id') if ended else None
    if not ended and rut_emisor and rut_receptor:
        try:
            nueva_llamada = HistorialLlamadas(
                rut_emisor=rut_emisor,
                rut_receptor=rut_receptor,
                tipo_llamada=tipo,
                estado=estado,
                duracion_segundos=duracion
            )
            db.session.add(nueva_llamada)
            db.session.commit()
            history_id = nueva_llamada.id
        except Exception as e:
            db.session.rollback()
            print(f'[ESP32] No se pudo guardar historial: {e}')

    return jsonify({'success': True, 'history_id': history_id, 'citofono_ended': bool(ended)})


@socketio.on('citofono-end-call')
def handle_citofono_end_call(data):
    data = data or {}
    call_id = (data.get('call_id') or '').strip()
    _end_citofono_call(call_id=call_id or None, reason=data.get('reason', 'finalizada'), estado=data.get('estado', 'finalizada'))


@socketio.on('citofono-app-answer')
def handle_citofono_app_answer(data):
    data = data or {}
    call_id = (data.get('call_id') or '').strip()
    _answer_citofono_call(call_id, answered_by='app')


# ─── WEB (HTML TEMPLATES) ────────────────────
@app.route('/')
def index():
    return render_template('login.html')

@app.route('/conserje')
def conserje():
    return render_template('conserje.html')

@app.route('/residente')
def residente():
    return render_template('residente.html')

@app.route('/llamada')
def llamada():
    return render_template('llamada.html')

@app.route('/static/<path:filename>')
def serve_static(filename):
    return send_from_directory(app.static_folder, filename)

# ─── NGROK ────────────────────────────────────
@app.route("/ngrok-url", methods=["GET"])
def get_ngrok_url():
    try:
        res = requests.get("http://127.0.0.1:4040/api/tunnels")
        for tunnel in res.json()["tunnels"]:
            if tunnel["proto"] == "https":
                return jsonify({"url": tunnel["public_url"]})
        return jsonify({"error": "No HTTPS tunnel activo"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/redirigir-ngrok")
def redirigir_ngrok():
    try:
        res = requests.get("http://127.0.0.1:4040/api/tunnels")
        for tunnel in res.json()["tunnels"]:
            if tunnel["proto"] == "https":
                return redirect(tunnel["public_url"] + "/conserje")
        return "No hay túnel HTTPS activo", 404
    except Exception as e:
        return f"Error: {e}", 500
@app.route('/apps')
def apps_store():
    return render_template('apps.html')
# ─── TWILIO ICE ───────────────────────────────
TWILIO_ACCOUNT_SID = os.getenv("TWILIO_ACCOUNT_SID", "TU_TWILIO_ACCOUNT_SID")
TWILIO_AUTH_TOKEN = os.getenv("TWILIO_AUTH_TOKEN", "TU_TWILIO_AUTH_TOKEN")

@app.route("/twilio-ice", methods=["GET"])
def get_twilio_ice():
    try:
        res = requests.post(
            f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_ACCOUNT_SID}/Tokens.json",
            auth=(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN),
        )
        if res.status_code == 201:
            data = res.json()
            ice_servers = data.get("ice_servers", [])
            print("✅ ICE servers generados con Twilio")
            return jsonify({"iceServers": ice_servers})
        else:
            print(f"❌ Error al generar ICE: {res.status_code} - {res.text}")
            return jsonify({"error": "Falló generación ICE"}), 500
    except Exception as e:
        print(f"❌ Excepción al obtener ICE: {e}")
        return jsonify({"error": str(e)}), 500

# ─── MAIN ─────────────────────────────────────
if __name__ == "__main__":
    os.makedirs(os.path.join(app.static_folder, 'uploads', 'chat'), exist_ok=True)
    with app.app_context():
        db.create_all()  # crea chat_mensajes si aun no existe
        try:
            db.session.execute(text('ALTER TABLE chat_mensajes ADD COLUMN es_imagen BOOLEAN DEFAULT FALSE'))
            db.session.commit()
            print("Columna es_imagen añadida a chat_mensajes.")
        except Exception:
            db.session.rollback()
    print("🔵 Servidor Flask App Residentes corriendo en puerto 6667...")
    print(f"🔊 ESP32 audio bridge: PCM16 mono {BROWSER_TX_SAMPLE_RATE} Hz, frame={BROWSER_TX_FRAME_BYTES}B/{BROWSER_TX_FRAME_MS}ms")
    socketio.run(app, host="0.0.0.0", port=6666)
