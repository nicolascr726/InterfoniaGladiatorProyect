<div align="center">

# 🛡️ Interfonía Gladiator
### Sistema Inteligente de Citofonía, Comunicación y Control de Acceso para Condominios

[![Descargar APK](https://img.shields.io/badge/📲_DESCARGAR_APP_ANDROID-Última_Versión_(APK)-2ea44f?style=for-the-badge&logo=android&logoColor=white)](https://github.com/nicolascr726/InterfoniaGladiatorProyect/releases/latest/download/app-release.apk)
[![Release Version](https://img.shields.io/github/v/release/nicolascr726/InterfoniaGladiatorProyect?style=for-the-badge&label=Versión&color=007ec6)](https://github.com/nicolascr726/InterfoniaGladiatorProyect/releases/latest)
[![Plataformas](https://img.shields.io/badge/Plataformas-Android_%7C_iOS_(TestFlight)-blue?style=for-the-badge&logo=flutter)](https://github.com/nicolascr726/InterfoniaGladiatorProyect)

*Haz clic en el botón verde de arriba para iniciar la descarga directa del instalador `.apk` más reciente para dispositivos Android.*

</div>

---

## 📋 Descripción General

**Interfonía Gladiator** es una plataforma integral diseñada para modernizar la comunicación y seguridad dentro de comunidades y condominios. El ecosistema conecta en tiempo real **kits físicos de citofonía (basados en microcontroladores ESP32-S3)**, **aplicaciones móviles nativas para residentes y conserjería (iOS y Android)** y un **servidor central de alta disponibilidad**.

Permite atender llamadas desde los accesos peatonales o vehiculares, realizar videollamadas entre unidades, gestionar mensajería interna, administrar recados y controlar la apertura de puertas directamente desde el teléfono móvil.

---

## ✨ Funciones y Puntos Clave

### 📞 1. Citofonía IP y Llamadas en Tiempo Real
* **Puente de Audio Bidireccional (ESP32-S3 ↔ App):** Comunicación fluida de baja latencia mediante canales WebSocket dedicados (`RX`/`TX`) con procesamiento de audio PCM16 a 8 kHz.
* **Videollamadas y Audio entre Unidades (WebRTC):** Comunicación directa entre residentes y conserjería con soporte de servidores STUN/TURN (Twilio ICE) para garantizar la conexión en redes móviles o Wi-Fi.
* **Marcación Inteligente y Directorio:** Búsqueda rápida por bloques y departamentos, marcación directa a Conserjería (`000`) e indicador en tiempo real de citófonos y usuarios conectados u ocupados.
* **Notificaciones Push de Alta Prioridad:** Integración con **Firebase Cloud Messaging (FCM)** y **Apple Push Notification service (APNs)** para despertar el dispositivo de inmediato ante llamadas entrantes.

### 💬 2. Mensajería Instantánea (Chat Interno)
* **Chat Residente – Conserjería:** Envío de mensajes de texto y fotografías en tiempo real mediante Socket.IO.
* **Confirmación y Estado de Lectura:** Indicadores de mensajes no leídos, vista previa del último mensaje por contacto y marca de tiempo local.
* **Gestión de Conversaciones:** Opciones para eliminar mensajes individuales o vaciar el historial de chat de forma sincronizada.

### 📝 3. Gestión de Recados, Avisos y Control de Puertas
* **Módulo de Recados Digitales:** Creación, seguimiento y resolución de recados o incidencias entre residentes y administración.
* **Integración con "Botón Negro" en Hardware:** Alerta física mediante LED en el citófono ante llamadas no contestadas y devolución automática de llamada hacia conserjería con un solo toque.
* **Avisos Directos al Citófono:** Envío de mensajes de texto desde la aplicación de conserjería directamente hacia el kit físico ESP32.
* **Control de Accesos y Puertas:** Interfaz dedicada según el rol del usuario para el accionamiento y registro de apertura de puertas/accesos.

### 📊 4. Historial y Reportes Exportables
* **Registro Detallado de Llamadas:** Visualización de llamadas entrantes, salientes y perdidas con cálculo de duración legible y hora local.
* **Exportación a Excel (`.xlsx`):** Generación y descarga directa de reportes en formato Excel tanto para el historial de llamadas como para la bitácora de recados.

---

## 🛠️ Arquitectura y Tecnologías Utilizadas

* **Aplicación Móvil:** Flutter / Dart (Compilación nativa para **Android** e **iOS**).
* **Backend y Señalización:** Python 3, Flask, Flask-SocketIO, Flask-Sock, Eventlet, NumPy.
* **Base de Datos y Seguridad:** MySQL + SQLAlchemy ORM, encriptación de credenciales mediante Argon2.
* **Hardware / IoT:** Microcontroladores ESP32-S3 programados en C++ (Arduino IDE).
* **Infraestructura Cloud y CI/CD:** Servidor VPS Linux (Ubuntu en IONOS), Firebase Admin SDK, GitHub y **Codemagic** (automatización de compilación y despliegue hacia App Store Connect / TestFlight).

---

## 📲 Instalación

### En Android
1. Presiona el botón **[📲 DESCARGAR APP ANDROID](https://github.com/nicolascr726/InterfoniaGladiatorProyect/releases/latest/download/app-release.apk)** ubicado al inicio de este documento.
2. Abre el archivo `app-release.apk` descargado en tu teléfono (si el sistema lo solicita, autoriza la instalación de aplicaciones de orígenes conocidos).
3. Inicia sesión con tu RUT y clave asignada por la administración.

### En iOS (iPhone)
1. Descarga la aplicación oficial **TestFlight** desde la App Store.
2. Acepta la invitación enviada a tu correo electrónico corporativo o de residente.
3. Instala **Interfonia Gladiator** directamente desde TestFlight para recibir las actualizaciones automáticas compiladas vía Codemagic.
