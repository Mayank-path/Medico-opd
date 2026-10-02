import Flutter
import UIKit
import AVFoundation

/// Handles native iOS AVAudioSession configuration, interruption handling,
/// audio route change monitoring, and media services reset resilience for Medico-OPD.
public class IosRecordingResilienceHandler: NSObject {
  public static let channelName = "com.medico.opd/ios_recording_resilience"

  private let channel: FlutterMethodChannel
  private var activeSessionId: String?
  private var isProtectionActive: Bool = false
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?
  private var mediaResetObserver: NSObjectProtocol?
  private var mediaLostObserver: NSObjectProtocol?

  public init(binaryMessenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: binaryMessenger)
    super.init()
    self.channel.setMethodCallHandler(self.handleMethodCall)
    self.registerNotificationObservers()
  }

  public static func register(with binaryMessenger: FlutterBinaryMessenger) -> IosRecordingResilienceHandler {
    return IosRecordingResilienceHandler(binaryMessenger: binaryMessenger)
  }

  deinit {
    removeNotificationObservers()
  }

  // MARK: - MethodChannel Handler

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startAudioSessionProtection":
      let args = call.arguments as? [String: Any]
      let sessionId = args?["recordingSessionId"] as? String
      let consultationId = args?["consultationId"] as? String
      let success = self.startAudioSessionProtection(sessionId: sessionId, consultationId: consultationId)
      result(success)

    case "updateProtectionState":
      let args = call.arguments as? [String: Any]
      let state = args?["state"] as? String ?? "recording"
      self.updateProtectionState(state: state)
      result(true)

    case "stopAudioSessionProtection":
      let success = self.stopAudioSessionProtection()
      result(success)

    case "getAudioSessionState":
      let state = self.getAudioSessionState()
      result(state)

    case "checkPermission":
      let status = self.checkMicrophonePermission()
      result(status)

    case "requestPermission":
      self.requestMicrophonePermission(result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - AVAudioSession Management

  public func startAudioSessionProtection(sessionId: String?, consultationId: String?) -> Bool {
    self.activeSessionId = sessionId
    let session = AVAudioSession.sharedInstance()
    do {
      // Category: playAndRecord allows concurrent playback and background microphone recording.
      // Options: allowBluetooth enables Bluetooth headsets/stethoscopes,
      // defaultToSpeaker routes audio playback to speaker when headphones are not connected.
      // Mode: spokenAudio optimizes voice isolation and system DSP for clinical dictation.
      try session.setCategory(
        .playAndRecord,
        mode: .spokenAudio,
        options: [.allowBluetooth, .defaultToSpeaker]
      )
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      self.isProtectionActive = true
      NSLog("[IosRecordingResilience] AVAudioSession activated for session: %@", sessionId ?? "unknown")
      return true
    } catch {
      NSLog("[IosRecordingResilience] Failed to activate AVAudioSession: %@", error.localizedDescription)
      self.isProtectionActive = false
      return false
    }
  }

  public func updateProtectionState(state: String) {
    NSLog("[IosRecordingResilience] Protection state updated: %@", state)
  }

  public func stopAudioSessionProtection() -> Bool {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setActive(false, options: .notifyOthersOnDeactivation)
      self.isProtectionActive = false
      self.activeSessionId = nil
      NSLog("[IosRecordingResilience] AVAudioSession deactivated.")
      return true
    } catch {
      NSLog("[IosRecordingResilience] Failed to deactivate AVAudioSession: %@", error.localizedDescription)
      self.isProtectionActive = false
      self.activeSessionId = nil
      return false
    }
  }

  public func getAudioSessionState() -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    return [
      "category": session.category.rawValue,
      "mode": session.mode.rawValue,
      "isOtherAudioPlaying": session.isOtherAudioPlaying,
      "recordPermission": checkMicrophonePermission(),
      "activeSessionId": activeSessionId ?? "",
      "isProtectionActive": isProtectionActive
    ]
  }

  public func checkMicrophonePermission() -> String {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: return "granted"
      case .denied: return "denied"
      case .undetermined: return "undetermined"
      @unknown default: return "unknown"
      }
    } else {
      switch AVAudioSession.sharedInstance().recordPermission {
      case .granted: return "granted"
      case .denied: return "denied"
      case .undetermined: return "undetermined"
      @unknown default: return "unknown"
      }
    }
  }

  public func requestMicrophonePermission(result: @escaping FlutterResult) {
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission { granted in
        DispatchQueue.main.async { result(granted) }
      }
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async { result(granted) }
      }
    }
  }

  // MARK: - Notifications

  private func registerNotificationObservers() {
    let center = NotificationCenter.default

    // 1. AVAudioSession.interruptionNotification
    interruptionObserver = center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: OperationQueue.main
    ) { [weak self] notification in
      self?.handleAudioInterruption(notification: notification)
    }

    // 2. AVAudioSession.routeChangeNotification
    routeChangeObserver = center.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: OperationQueue.main
    ) { [weak self] notification in
      self?.handleAudioRouteChange(notification: notification)
    }

    // 3. AVAudioSession.mediaServicesWereResetNotification
    mediaResetObserver = center.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: nil,
      queue: OperationQueue.main
    ) { [weak self] notification in
      self?.handleMediaServicesReset(notification: notification)
    }

    // 4. AVAudioSession.mediaServicesWereLostNotification
    mediaLostObserver = center.addObserver(
      forName: AVAudioSession.mediaServicesWereLostNotification,
      object: nil,
      queue: OperationQueue.main
    ) { [weak self] notification in
      self?.handleMediaServicesLost(notification: notification)
    }
  }

  private func removeNotificationObservers() {
    let center = NotificationCenter.default
    if let obs = interruptionObserver { center.removeObserver(obs) }
    if let obs = routeChangeObserver { center.removeObserver(obs) }
    if let obs = mediaResetObserver { center.removeObserver(obs) }
    if let obs = mediaLostObserver { center.removeObserver(obs) }
  }

  private func handleAudioInterruption(notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }

    switch type {
    case .began:
      var reasonStr = "AUDIO_INTERRUPTION_BEGAN"
      if #available(iOS 14.5, *),
         let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
         let reason = AVAudioSession.InterruptionReason(rawValue: reasonValue) {
        switch reason {
        case .appWasSuspended:
          reasonStr = "INTERRUPTION_APP_SUSPENDED"
        case .builtInMicMuted:
          reasonStr = "INTERRUPTION_BUILT_IN_MIC_MUTED"
        default:
          reasonStr = "AUDIO_INTERRUPTION_BEGAN"
        }
      }

      NSLog("[IosRecordingResilience] Audio interruption began: %@", reasonStr)
      channel.invokeMethod("onAudioInterruption", [
        "type": "began",
        "reason": reasonStr,
        "sessionId": activeSessionId as Any
      ])

    case .ended:
      var shouldResume = false
      if let optValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optValue)
        shouldResume = options.contains(.shouldResume)
      }

      NSLog("[IosRecordingResilience] Audio interruption ended: shouldResume=%d", shouldResume ? 1 : 0)
      channel.invokeMethod("onAudioInterruption", [
        "type": "ended",
        "reason": "AUDIO_INTERRUPTION_ENDED",
        "shouldResume": shouldResume,
        "sessionId": activeSessionId as Any
      ])

    @unknown default:
      break
    }
  }

  private func handleAudioRouteChange(notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return
    }

    var reasonStr = "unknown"
    switch reason {
    case .newDeviceAvailable: reasonStr = "newDeviceAvailable"
    case .oldDeviceUnavailable: reasonStr = "oldDeviceUnavailable"
    case .categoryChange: reasonStr = "categoryChange"
    case .override: reasonStr = "override"
    case .wakeFromSleep: reasonStr = "wakeFromSleep"
    case .noSuitableRouteForCategory: reasonStr = "noSuitableRouteForCategory"
    case .routeConfigurationChange: reasonStr = "routeConfigurationChange"
    case .unknown: reasonStr = "unknown"
    @unknown default: reasonStr = "unknown"
    }

    let prevRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
    let prevInputs = prevRoute?.inputs.map { $0.portType.rawValue }.joined(separator: ",") ?? "none"
    let currInputs = AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")

    NSLog("[IosRecordingResilience] Route changed: %@ (prev: %@, curr: %@)", reasonStr, prevInputs, currInputs)

    channel.invokeMethod("onAudioRouteChange", [
      "reason": reasonStr,
      "previousRoute": prevInputs,
      "currentRoute": currInputs,
      "sessionId": activeSessionId as Any
    ])
  }

  private func handleMediaServicesReset(notification: Notification) {
    NSLog("[IosRecordingResilience] Media services were reset by OS!")
    isProtectionActive = false
    channel.invokeMethod("onMediaServicesReset", [
      "reason": "MEDIA_SERVICES_RESET",
      "sessionId": activeSessionId as Any
    ])
  }

  private func handleMediaServicesLost(notification: Notification) {
    NSLog("[IosRecordingResilience] Media services were lost!")
    channel.invokeMethod("onMediaServicesLost", [
      "reason": "MEDIA_SERVICES_LOST",
      "sessionId": activeSessionId as Any
    ])
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var resilienceHandler: IosRecordingResilienceHandler?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as? FlutterViewController
    if let messenger = controller?.binaryMessenger {
      resilienceHandler = IosRecordingResilienceHandler.register(with: messenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if resilienceHandler == nil {
      resilienceHandler = IosRecordingResilienceHandler.register(with: engineBridge.engine.binaryMessenger)
    }
  }
}
