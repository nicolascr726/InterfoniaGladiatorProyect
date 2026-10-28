import UIKit
import Flutter
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var audioEngine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var audioFormat8k: AVAudioFormat?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    let registrar = self.registrar(forPlugin: "CitofonoAudioPlugin")!
    let audioChannel = FlutterMethodChannel(name: "gladiator/citofono_audio_track",
                                            binaryMessenger: registrar.messenger())

    audioChannel.setMethodCallHandler({
      [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      guard let self = self else { return }
      
      switch call.method {
      case "initAudio":
        self.setupAudioSession()
        self.setupAudioEngine()
        result(true)
      case "writeAudio":
        if let args = call.arguments as? [String: Any],
           let typedData = args["data"] as? FlutterStandardTypedData {
          self.playPCMData(typedData.data)
        }
        result(true)
      case "stopAudio":
        self.stopAudioEngine()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    })

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func setupAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
      try session.setActive(true)
    } catch {
      print("Error AVAudioSession: \(error.localizedDescription)")
    }
  }

  private func setupAudioEngine() {
    audioEngine = AVAudioEngine()
    playerNode = AVAudioPlayerNode()

    guard let engine = audioEngine, let player = playerNode else { return }

    engine.attach(player)

    // Entrada PCM ESP32: 8 kHz, 16 bits Mono
    audioFormat8k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000.0, channels: 1, interleaved: false)
    
    guard let format8k = audioFormat8k else { return }

    engine.connect(player, to: engine.mainMixerNode, format: format8k)

    do {
      try engine.start()
      player.play()
    } catch {
      print("Error iniciando AVAudioEngine: \(error.localizedDescription)")
    }
  }

  private func playPCMData(_ pcmData: Data) {
    guard let player = playerNode, let format8k = audioFormat8k else { return }

    let frameCount = UInt32(pcmData.count / 2)
    guard frameCount > 0 else { return }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format8k, frameCapacity: frameCount) else { return }
    buffer.frameLength = frameCount

    pcmData.withUnsafeBytes { rawBuffer in
        if let sourceAddress = rawBuffer.baseAddress,
           let destinationAddress = buffer.int16ChannelData?[0] {
            memcpy(destinationAddress, sourceAddress, pcmData.count)
        }
    }

    player.scheduleBuffer(buffer, completionHandler: nil)
    
    if !player.isPlaying {
      player.play()
    }
  }

  private func stopAudioEngine() {
    playerNode?.stop()
    audioEngine?.stop()
  }
}