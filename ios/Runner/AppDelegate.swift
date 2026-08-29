import Flutter
import UIKit
import BackgroundTasks
import UserNotifications
import ActivityKit
import EventKit
import CoreLocation
import HealthKit
import SwiftUI
import Translation

private let backgroundRefreshIdentifier = "psyche.kelivo.background-generation.refresh"
private let backgroundProcessingIdentifier = "psyche.kelivo.background-generation.processing"

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let fileSaveHandler = NativeFileSaveHandler()
  private let backgroundGenerationHandler = IosBackgroundGenerationHandler()
   private let iosTranslationHandler = IosTranslationHandler()
   private let deviceLocalToolsHandler = DeviceLocalToolsHandler()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    backgroundGenerationHandler.registerBackgroundTasks()
    if let controller = window?.rootViewController as? FlutterViewController {
      let clipboardChannel = FlutterMethodChannel(name: "app.clipboard", binaryMessenger: controller.binaryMessenger)
      clipboardChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        if call.method == "getClipboardImages" {
          var paths: [String] = []
          if let image = UIPasteboard.general.image {
            if let data = image.pngData() ?? image.jpegData(compressionQuality: 0.95) {
              let tmp = NSTemporaryDirectory()
              let filename = "pasted_\(Int(Date().timeIntervalSince1970 * 1000)).png"
              let url = URL(fileURLWithPath: tmp).appendingPathComponent(filename)
              do {
                try data.write(to: url)
                paths.append(url.path)
              } catch {
                // ignore write error
              }
            }
          }
          result(paths)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }

      let fileSaveChannel = FlutterMethodChannel(name: "app.file_save", binaryMessenger: controller.binaryMessenger)
      fileSaveHandler.presentingViewController = controller
      fileSaveChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
        guard call.method == "saveFileFromPath" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.fileSaveHandler.handle(call: call, result: result)
      }

      let iosBackgroundChannel = FlutterMethodChannel(name: "app.ios_background_generation", binaryMessenger: controller.binaryMessenger)
      iosBackgroundChannel.setMethodCallHandler { [weak self] call, result in
        self?.backgroundGenerationHandler.handle(call: call, result: result)
      }

      let iosTranslationChannel = FlutterMethodChannel(name: "app.ios_translation", binaryMessenger: controller.binaryMessenger)
      iosTranslationHandler.presentingViewController = controller
      iosTranslationChannel.setMethodCallHandler { [weak self] call, result in
        self?.iosTranslationHandler.handle(call: call, result: result)
      }

      let deviceToolsChannel = FlutterMethodChannel(name: "app.device_tools", binaryMessenger: controller.binaryMessenger)
      deviceToolsChannel.setMethodCallHandler { [weak self] call, result in
        self?.deviceLocalToolsHandler.handle(call: call, result: result)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    backgroundGenerationHandler.dismissFinishedLiveActivityIfNeeded()
  }
}

private final class IosBackgroundGenerationHandler {
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var notificationsEnabled = false
  private var refreshEnabled = false
  private var liveActivity: Any?
  private var liveActivityRefreshTimer: Timer?
  private var liveActivityDisplayTitle = ""
  private var liveActivityDetail = ""
  private var liveActivityTokenCount = 0
  private var liveActivityTokenLabel = ""
  private var liveActivityStartedAt = Date()
  private var liveActivityFinishedAt: Date?
  private var liveActivityFinishedDetail = ""
  private var liveActivityFinished = false
  private var liveActivityWavePhase = 0

  func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundRefreshIdentifier, using: nil) { task in
      self.handleBackgroundTask(task)
    }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundProcessingIdentifier, using: nil) { task in
      self.handleBackgroundTask(task)
    }
  }

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getStatus":
      getStatus(result: result)
    case "requestNotificationAuthorization":
      requestNotificationAuthorization(result: result)
    case "openAppSettings":
      openAppSettings(result: result)
    case "openNotificationSettings":
      openNotificationSettings(result: result)
    case "start":
      start(arguments: call.arguments, result: result)
    case "update":
      update(arguments: call.arguments, result: result)
    case "finish":
      finish(arguments: call.arguments, result: result)
    case "cancel":
      cancel(arguments: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any] ?? [:]
    notificationsEnabled = args["notificationsEnabled"] as? Bool ?? false
    refreshEnabled = args["refreshEnabled"] as? Bool ?? false
    beginBackgroundTask()
    if refreshEnabled { scheduleBackgroundTasks() }
    if args["liveActivityEnabled"] as? Bool ?? false {
      startLiveActivity(
        title: args["title"] as? String ?? "Kelivo",
        detail: args["detail"] as? String ?? "",
        tokenCount: args["tokenCount"] as? Int ?? 0,
        tokenLabel: args["tokenLabel"] as? String ?? ""
      )
    }
    result(true)
  }

  private func update(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any] ?? [:]
    updateLiveActivity(
      detail: args["detail"] as? String ?? "",
      tokenCount: args["tokenCount"] as? Int ?? 0,
      tokenLabel: args["tokenLabel"] as? String ?? ""
    )
    result(true)
  }

  private func finish(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any] ?? [:]
    let title = args["title"] as? String ?? "Kelivo"
    let detail = args["detail"] as? String ?? ""
    finishLiveActivity(title: title, detail: detail)
    if notificationsEnabled { showCompletionNotification(title: title, body: detail) }
    endBackgroundTask()
    resetGenerationOptions()
    result(true)
  }

  private func cancel(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any] ?? [:]
    finishLiveActivity(
      title: liveActivityDisplayTitle.isEmpty ? "Kelivo" : liveActivityDisplayTitle,
      detail: args["detail"] as? String ?? ""
    )
    endBackgroundTask()
    resetGenerationOptions()
    result(true)
  }

  private func resetGenerationOptions() {
    notificationsEnabled = false
    refreshEnabled = false
  }

  private func getStatus(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        var liveActivitiesEnabled = false
        if #available(iOS 16.1, *) {
          liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        }
        result([
          "backgroundTaskActive": self.backgroundTask != .invalid,
          "liveActivityActive": self.isLiveActivityActive(),
          "notificationsAuthorized": settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
          "liveActivitiesEnabled": liveActivitiesEnabled,
        ])
      }
    }
  }

  private func requestNotificationAuthorization(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      DispatchQueue.main.async { result(granted) }
    }
  }

  private func openAppSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      result(opened)
    }
  }

  private func openNotificationSettings(result: @escaping FlutterResult) {
    let url: URL?
    if #available(iOS 16.0, *) {
      url = URL(string: UIApplication.openNotificationSettingsURLString)
    } else {
      url = URL(string: UIApplication.openSettingsURLString)
    }
    guard let url else {
      result(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      result(opened)
    }
  }

  private func beginBackgroundTask() {
    if backgroundTask != .invalid { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "KelivoBackgroundGeneration") { [weak self] in
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  private func scheduleBackgroundTasks() {
    let refresh = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
    refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
      try BGTaskScheduler.shared.submit(refresh)
    } catch {
      NSLog("Kelivo background refresh schedule failed: \(error)")
    }

    let processing = BGProcessingTaskRequest(identifier: backgroundProcessingIdentifier)
    processing.requiresNetworkConnectivity = true
    processing.requiresExternalPower = false
    processing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
      try BGTaskScheduler.shared.submit(processing)
    } catch {
      NSLog("Kelivo background processing schedule failed: \(error)")
    }
  }

  private func handleBackgroundTask(_ task: BGTask) {
    if refreshEnabled { scheduleBackgroundTasks() }
    task.expirationHandler = { task.setTaskCompleted(success: false) }
    task.setTaskCompleted(success: true)
  }

  private func showCompletionNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(identifier: "kelivo.background-generation.\(Date().timeIntervalSince1970)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  private func isLiveActivityActive() -> Bool {
    if #available(iOS 16.1, *) {
      return liveActivity as? Activity<KelivoGenerationActivityAttributes> != nil
    }
    return false
  }

  private func startLiveActivity(title: String, detail: String, tokenCount: Int, tokenLabel: String) {
    if #available(iOS 16.1, *) {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      liveActivityDisplayTitle = title
      liveActivityDetail = detail
      liveActivityStartedAt = Date()
      liveActivityFinishedAt = nil
      liveActivityFinishedDetail = ""
      liveActivityFinished = false
      liveActivityWavePhase = 0
      liveActivityTokenCount = tokenCount
      liveActivityTokenLabel = tokenLabel
      let state = liveActivityState(
        displayTitle: title,
        detail: detail,
        tokenCount: tokenCount,
        tokenLabel: tokenLabel,
        finishedAt: nil,
        isFinished: false
      )
      do {
        if #available(iOS 16.2, *) {
          liveActivity = try Activity<KelivoGenerationActivityAttributes>.request(attributes: KelivoGenerationActivityAttributes(title: title), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        } else {
          liveActivity = try Activity<KelivoGenerationActivityAttributes>.request(attributes: KelivoGenerationActivityAttributes(title: title), contentState: state, pushType: nil)
        }
        startLiveActivityRefreshTimer()
      } catch {
        NSLog("Kelivo live activity start failed: \(error)")
        liveActivity = nil
      }
    }
  }

  private func updateLiveActivity(detail: String, tokenCount: Int, tokenLabel: String) {
    guard isLiveActivityActive(), !liveActivityFinished else { return }
    liveActivityTokenCount = tokenCount
    liveActivityTokenLabel = tokenLabel
    liveActivityDetail = detail
    liveActivityFinishedAt = nil
    liveActivityFinishedDetail = ""
  }

  func dismissFinishedLiveActivityIfNeeded() {
    guard liveActivityFinished else { return }
    endLiveActivity(detail: liveActivityFinishedDetail)
  }

  private func finishLiveActivity(title: String, detail: String) {
    liveActivityDisplayTitle = title
    liveActivityDetail = detail
    stopLiveActivityRefreshTimer()
    if UIApplication.shared.applicationState == .active {
      liveActivityFinishedAt = Date()
      liveActivityFinishedDetail = detail
      liveActivityFinished = true
      endLiveActivity(detail: detail)
      return
    }
    markLiveActivityFinished(title: title, detail: detail)
  }

  private func markLiveActivityFinished(title: String, detail: String) {
    if #available(iOS 16.1, *), let activity = liveActivity as? Activity<KelivoGenerationActivityAttributes> {
      let finishedAt = Date()
      liveActivityDisplayTitle = title
      liveActivityDetail = detail
      liveActivityFinishedAt = finishedAt
      liveActivityFinishedDetail = detail
      liveActivityFinished = true
      let state = liveActivityState(
        displayTitle: title,
        detail: detail,
        tokenCount: liveActivityTokenCount,
        tokenLabel: liveActivityTokenLabel,
        finishedAt: finishedAt,
        isFinished: true
      )
      Task {
        if #available(iOS 16.2, *) {
          await activity.update(ActivityContent(state: state, staleDate: nil))
        } else {
          await activity.update(using: state)
        }
      }
    }
  }

  private func endLiveActivity(detail: String) {
    if #available(iOS 16.1, *), let activity = liveActivity as? Activity<KelivoGenerationActivityAttributes> {
      let state = liveActivityState(
        displayTitle: liveActivityDisplayTitle,
        detail: detail,
        tokenCount: liveActivityTokenCount,
        tokenLabel: liveActivityTokenLabel,
        finishedAt: liveActivityFinishedAt,
        isFinished: liveActivityFinished
      )
      Task {
        if #available(iOS 16.2, *) {
          await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        } else {
          await activity.end(using: state, dismissalPolicy: .immediate)
        }
      }
      liveActivity = nil
      stopLiveActivityRefreshTimer()
      liveActivityDisplayTitle = ""
      liveActivityDetail = ""
      liveActivityTokenCount = 0
      liveActivityTokenLabel = ""
      liveActivityStartedAt = Date()
      liveActivityFinishedAt = nil
      liveActivityFinishedDetail = ""
      liveActivityFinished = false
      liveActivityWavePhase = 0
    }
  }

  private func startLiveActivityRefreshTimer() {
    stopLiveActivityRefreshTimer()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      self?.refreshLiveActivity()
    }
    liveActivityRefreshTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopLiveActivityRefreshTimer() {
    liveActivityRefreshTimer?.invalidate()
    liveActivityRefreshTimer = nil
  }

  private func refreshLiveActivity() {
    guard #available(iOS 16.1, *), let activity = liveActivity as? Activity<KelivoGenerationActivityAttributes> else { return }
    guard !liveActivityFinished else { return }
    liveActivityWavePhase += 1
    let state = liveActivityState(
      displayTitle: liveActivityDisplayTitle,
      detail: liveActivityDetail,
      tokenCount: liveActivityTokenCount,
      tokenLabel: liveActivityTokenLabel,
      finishedAt: nil,
      isFinished: false
    )
    Task {
      if #available(iOS 16.2, *) {
        await activity.update(ActivityContent(state: state, staleDate: nil))
      } else {
        await activity.update(using: state)
      }
    }
  }

  @available(iOS 16.1, *)
  private func liveActivityState(
    displayTitle: String,
    detail: String,
    tokenCount: Int,
    tokenLabel: String,
    finishedAt: Date?,
    isFinished: Bool
  ) -> KelivoGenerationActivityAttributes.ContentState {
    let startedAt = liveActivityStartedAt
    let effectiveFinishedAt = finishedAt ?? Date()
    return KelivoGenerationActivityAttributes.ContentState(
      displayTitle: displayTitle,
      detail: detail,
      tokenCount: tokenCount,
      tokenLabel: tokenLabel,
      startedAt: startedAt,
      finishedAt: finishedAt,
      elapsedSeconds: isFinished
        ? elapsedSeconds(from: startedAt, to: effectiveFinishedAt)
        : elapsedSeconds(since: startedAt),
      wavePhase: liveActivityWavePhase,
      isFinished: isFinished
    )
  }

  private func elapsedSeconds(since startedAt: Date) -> Int {
    elapsedSeconds(from: startedAt, to: Date())
  }

  private func elapsedSeconds(from startedAt: Date, to endedAt: Date) -> Int {
    max(0, Int(endedAt.timeIntervalSince(startedAt)))
  }
}

private final class NativeFileSaveHandler: NSObject, UIDocumentPickerDelegate {
  weak var presentingViewController: UIViewController?
  private var pendingResult: FlutterResult?

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if pendingResult != nil {
      result(FlutterError(code: "busy", message: "Another save operation is already in progress.", details: nil))
      return
    }

    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "invalid_args", message: "Arguments must be a map.", details: nil))
      return
    }

    let rawSourcePath = (args["sourcePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !rawSourcePath.isEmpty else {
      result(FlutterError(code: "invalid_args", message: "Missing sourcePath.", details: nil))
      return
    }

    let sourceURL = URL(fileURLWithPath: rawSourcePath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      result(FlutterError(code: "not_found", message: "Source file does not exist.", details: nil))
      return
    }

    guard let presenter = topViewController(from: presentingViewController) else {
      result(FlutterError(code: "unavailable", message: "Unable to present document picker.", details: nil))
      return
    }

    pendingResult = result

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }

      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(forExporting: [sourceURL], asCopy: true)
      } else {
        picker = UIDocumentPickerViewController(url: sourceURL, in: .exportToService)
      }

      picker.delegate = self
      picker.modalPresentationStyle = .formSheet
      if let popover = picker.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        popover.permittedArrowDirections = []
      }

      presenter.present(picker, animated: true)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(with: false)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finish(with: !urls.isEmpty)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
    finish(with: true)
  }

  private func finish(with value: Bool) {
    let result = pendingResult
    pendingResult = nil
    result?(value)
  }

  private func topViewController(from controller: UIViewController?) -> UIViewController? {
    if let navigation = controller as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = controller as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    if let presented = controller?.presentedViewController {
      return topViewController(from: presented)
    }
    return controller
  }
}

private final class IosTranslationHandler {
  weak var presentingViewController: UIViewController?
  private var hostingController: UIViewController?

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      if #available(iOS 17.4, *) { result(true) } else { result(false) }
    case "present":
      guard #available(iOS 17.4, *) else { result(false); return }
      let arguments = call.arguments as? [String: Any]
      guard
        let text = arguments?["text"] as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let anchorX = arguments?["anchorX"] as? Double,
        let anchorY = arguments?["anchorY"] as? Double,
        let presenter = presentingViewController,
        presenter.viewIfLoaded?.window != nil
      else { result(false); return }
      present(text: text, anchor: CGPoint(x: anchorX, y: anchorY), in: presenter)
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 17.4, *)
  private func present(text: String, anchor: CGPoint, in presenter: UIViewController) {
    removeHostingController()
    let bounds = presenter.view.bounds
    let point = CGPoint(
      x: min(max(anchor.x, bounds.minX + 1), bounds.maxX - 1),
      y: min(max(anchor.y, bounds.minY + 1), bounds.maxY - 1))
    let hc = UIHostingController(rootView: NativeTranslationPresenter(text: text) { [weak self] in
      self?.removeHostingController()
    })
    hc.view.backgroundColor = .clear
    hc.view.frame = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
    presenter.addChild(hc)
    presenter.view.addSubview(hc.view)
    hc.didMove(toParent: presenter)
    self.hostingController = hc
  }

  private func removeHostingController() {
    guard let hostingController else { return }
    hostingController.willMove(toParent: nil)
    hostingController.view.removeFromSuperview()
    hostingController.removeFromParent()
    self.hostingController = nil
  }
}

@available(iOS 17.4, *)
private struct NativeTranslationPresenter: View {
  let text: String
  let onDismiss: () -> Void
  @State private var isPresented = false
  var body: some View {
    Color.clear
      .translationPresentation(isPresented: $isPresented, text: text)
      .onAppear { DispatchQueue.main.async { isPresented = true } }
      .onChange(of: isPresented) { visible in if !visible { onDismiss() } }
  }
}

 private final class DeviceLocalToolsHandler {
   private let eventStore = EKEventStore()
   private let locationHandler = LocationToolHandler()
   private let healthHandler = HealthToolHandler()
   private lazy var weatherHandler = OpenMeteoWeatherHandler(locationHandler: locationHandler)
   private lazy var remindersHandler = RemindersToolHandler(eventStore: eventStore)
 
   func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
     let args = Self.parseArgs(call.arguments)
     switch call.method {
     case "hasUsageStatsPermission":
       result(false)
     case "openUsageAccessSettings":
       result(nil)
     case "hasCalendarPermission":
       result(hasCalendarPermission())
     case "requestCalendarPermission":
       requestCalendarPermission(result: result)
     case "queryCalendar":
       ensureCalendarAccess { [weak self] granted in
         guard let self else { return }
         guard granted else {
           result(Self.noPermissionPayload)
           return
         }
         DispatchQueue.global(qos: .userInitiated).async {
           let payload = self.queryCalendar(args: args)
           DispatchQueue.main.async { result(payload) }
         }
       }
     case "createCalendarEvent":
       ensureCalendarAccess { [weak self] granted in
         guard let self else { return }
         guard granted else {
           result(Self.noPermissionPayload)
           return
         }
         DispatchQueue.global(qos: .userInitiated).async {
           let payload = self.createCalendarEvent(args: args)
           DispatchQueue.main.async { result(payload) }
         }
       }
     case "getScreenTime":
       result(Self.errorPayload(
         "UNSUPPORTED_PLATFORM",
         "Screen time queries are not available on iOS; Apple does not provide a general-purpose API for this."
       ))
     case "hasLocationPermission":
       result(locationHandler.hasPermission())
     case "requestLocationPermission":
       locationHandler.requestPermission { granted in result(granted) }
     case "getCurrentLocation":
       locationHandler.getCurrentLocation(args: args) { payload in result(payload) }
     case "isWeatherKitAvailable":
       result(OpenMeteoWeatherHandler.isAvailable)
     case "getWeather":
       weatherHandler.getWeather(args: args) { payload in result(payload) }
     case "hasRemindersPermission":
       result(remindersHandler.hasPermission())
     case "requestRemindersPermission":
       remindersHandler.requestPermission { granted in result(granted) }
     case "queryReminders":
       remindersHandler.ensureAccess { [weak self] granted in
         guard let self else { return }
         guard granted else {
           result(Self.noRemindersPermissionPayload)
           return
         }
         self.remindersHandler.query(args: args) { payload in result(payload) }
       }
     case "createReminder":
       remindersHandler.ensureAccess { [weak self] granted in
         guard let self else { return }
         guard granted else {
           result(Self.noRemindersPermissionPayload)
           return
         }
         DispatchQueue.global(qos: .userInitiated).async {
           let payload = self.remindersHandler.create(args: args)
           DeviceToolsSupport.finishOnMain { result(payload) }
         }
       }
     case "completeReminder":
       remindersHandler.ensureAccess { [weak self] granted in
         guard let self else { return }
         guard granted else {
           result(Self.noRemindersPermissionPayload)
           return
         }
         DispatchQueue.global(qos: .userInitiated).async {
           let payload = self.remindersHandler.complete(args: args)
           DeviceToolsSupport.finishOnMain { result(payload) }
         }
       }
     case "isHealthDataAvailable":
       result(healthHandler.isAvailable())
     case "requestHealthPermission":
       healthHandler.requestPermission { granted in result(granted) }
     case "getHealthSummary":
       healthHandler.getHealthSummary(args: args) { payload in result(payload) }
     default:
       result(FlutterMethodNotImplemented)
     }
   }
 
   // MARK: - Permission
 
   private static let noPermissionPayload = errorPayload(
     "NO_PERMISSION",
     "Calendar permission is not granted. Please ask the user to allow full calendar access "
       + "for this app in the system Settings and try again."
   )

   private static let noRemindersPermissionPayload = DeviceToolsSupport.noPermissionPayload(
     "Reminders permission is not granted. Please ask the user to allow full reminders access "
       + "for this app in the system Settings and try again."
   )

   private func hasCalendarPermission() -> Bool {
     let status = EKEventStore.authorizationStatus(for: .event)
     if #available(iOS 17.0, *) {
       return status == .fullAccess
     }
     return status == .authorized
   }

   /// Used by the assistant settings toggle. Prompts when undetermined; opens
   /// Settings when previously denied/restricted/write-only.
   private func requestCalendarPermission(result: @escaping FlutterResult) {
     let finish: (Bool) -> Void = { granted in
       DispatchQueue.main.async { result(granted) }
     }
     let status = EKEventStore.authorizationStatus(for: .event)
     if #available(iOS 17.0, *) {
       switch status {
       case .fullAccess:
         finish(true)
       case .notDetermined:
         eventStore.requestFullAccessToEvents { granted, _ in finish(granted) }
       default:
         openAppSettings()
         finish(false)
       }
     } else {
       switch status {
       case .authorized:
         finish(true)
       case .notDetermined:
         eventStore.requestAccess(to: .event) { granted, _ in finish(granted) }
       default:
         openAppSettings()
         finish(false)
       }
     }
   }

   private func openAppSettings() {
     guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
     UIApplication.shared.open(url)
   }
 
   private func ensureCalendarAccess(completion: @escaping (Bool) -> Void) {
     let finish: (Bool) -> Void = { granted in
       DispatchQueue.main.async { completion(granted) }
     }
     let status = EKEventStore.authorizationStatus(for: .event)
     if #available(iOS 17.0, *) {
       switch status {
       case .fullAccess:
         finish(true)
       case .notDetermined:
         eventStore.requestFullAccessToEvents { granted, _ in finish(granted) }
       default:
         finish(false)
       }
     } else {
       switch status {
       case .authorized:
         finish(true)
       case .notDetermined:
         eventStore.requestAccess(to: .event) { granted, _ in finish(granted) }
       default:
         finish(false)
       }
     }
   }
 
   // MARK: - Calendar query
 
   private func queryCalendar(args: [String: Any]) -> String {
     let limit = min(max(Self.intArg(args["limit"]) ?? 20, 1), 100)
     let keyword = (args["query"] as? String)?
       .trimmingCharacters(in: .whitespacesAndNewlines)
       .lowercased()
     let rangePreset = (args["range"] as? String)?.lowercased() ?? "today"
 
     // ISO 8601 calendar so week presets start on Monday, matching Android.
     var calendar = Calendar(identifier: .iso8601)
     calendar.timeZone = .current
     let now = Date()
     let startOfToday = calendar.startOfDay(for: now)
 
     let startDate: Date
     let endDate: Date
     if let beginRaw = args["begin"] as? String, !beginRaw.isEmpty {
       guard let parsedStart = Self.parseTime(beginRaw, calendar: calendar) else {
         return Self.invalidTimePayload(beginRaw)
       }
       startDate = parsedStart
       if let endRaw = args["end"] as? String, !endRaw.isEmpty {
         guard let parsedEnd = Self.parseTime(endRaw, calendar: calendar) else {
           return Self.invalidTimePayload(endRaw)
         }
         endDate = parsedEnd
       } else {
         endDate = now
       }
     } else {
       switch rangePreset {
       case "week":
         let weekStart = calendar.date(
           from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
         ) ?? startOfToday
         startDate = weekStart
         endDate = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? now
       case "month":
         let monthStart = calendar.date(
           from: calendar.dateComponents([.year, .month], from: now)
         ) ?? startOfToday
         startDate = monthStart
         endDate = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now
       default:
         startDate = startOfToday
         endDate = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
       }
     }
 
     guard startDate < endDate else {
       return Self.errorPayload("INVALID_RANGE", "begin must be earlier than end.")
     }
 
     let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
     var events = eventStore.events(matching: predicate)
     if let keyword, !keyword.isEmpty {
       events = events.filter { ($0.title ?? "").lowercased().contains(keyword) }
     }
     events.sort { $0.startDate < $1.startDate }
 
     var items: [[String: Any]] = []
     for event in events.prefix(limit) {
       var item: [String: Any] = [
         "id": event.eventIdentifier ?? "",
         "title": event.title ?? "",
         "description": event.notes ?? "",
         "location": event.location ?? "",
         "all_day": event.isAllDay,
         "calendar": event.calendar?.title ?? "",
       ]
       if event.isAllDay {
         item["start"] = Self.formatDateOnly(event.startDate, calendar: calendar)
         // Report the exclusive end date (tool convention, matches Android);
         // EventKit stores all-day ends inside the last included day.
         item["end"] = event.endDate.map {
           Self.formatDateOnly(Self.exclusiveAllDayEnd($0, calendar: calendar), calendar: calendar)
         } ?? ""
       } else {
         item["start"] = Self.formatDateTime(event.startDate)
         item["end"] = event.endDate.map(Self.formatDateTime) ?? ""
       }
       items.append(item)
     }
 
     return Self.jsonString([
       "range_start": Self.formatDateTime(startDate),
       "range_end": Self.formatDateTime(endDate),
       "count": items.count,
       "events": items,
     ])
   }
 
   // MARK: - Calendar create
 
   private func createCalendarEvent(args: [String: Any]) -> String {
     let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
     let startRaw = (args["start"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
     guard !title.isEmpty, !startRaw.isEmpty else {
       return Self.errorPayload("MISSING_REQUIRED", "Both 'title' and 'start' are required.")
     }
     let allDay = Self.boolArg(args["all_day"]) ?? false
 
     var calendar = Calendar(identifier: .iso8601)
     calendar.timeZone = .current
 
     guard let startDate = Self.parseTime(startRaw, calendar: calendar) else {
       return Self.invalidTimePayload(startRaw)
     }
     let endDate: Date
     if let endRaw = args["end"] as? String, !endRaw.isEmpty {
       guard let parsedEnd = Self.parseTime(endRaw, calendar: calendar) else {
         return Self.invalidTimePayload(endRaw)
       }
       endDate = parsedEnd
     } else if allDay {
       let dayStart = calendar.startOfDay(for: startDate)
       endDate = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? startDate.addingTimeInterval(86400)
     } else {
       endDate = startDate.addingTimeInterval(3600)
     }
     guard startDate < endDate else {
       return Self.errorPayload("INVALID_RANGE", "end must be later than start.")
     }
 
     // For all-day events, normalize both ends to day boundaries first (like
     // Android's LocalDate comparison), so e.g. a 12:00-18:00 same-day range is
     // rejected instead of silently producing a degenerate event.
     let allDayStart = calendar.startOfDay(for: startDate)
     let allDayEndExclusive = calendar.startOfDay(for: endDate)
     if allDay, allDayStart >= allDayEndExclusive {
       return Self.errorPayload("INVALID_RANGE", "all-day event end date must be later than start date.")
     }
 
     guard let targetCalendar = eventStore.defaultCalendarForNewEvents else {
       return Self.errorPayload(
         "NO_CALENDAR",
         "No calendar account found on this device. Please add a calendar account first."
       )
     }
 
     let event = EKEvent(eventStore: eventStore)
     event.calendar = targetCalendar
     event.title = title
     if let notes = args["description"] as? String, !notes.isEmpty {
       event.notes = notes
     }
     if let location = args["location"] as? String, !location.isEmpty {
       event.location = location
     }
     if allDay {
       event.isAllDay = true
       event.startDate = allDayStart
       // The tool's 'end' is exclusive (next-day midnight); EventKit treats the
       // end date's day as included, so step back one second to avoid spilling
       // into an extra day. Payloads convert back to the exclusive date.
       event.endDate = allDayEndExclusive.addingTimeInterval(-1)
     } else {
       event.startDate = startDate
       event.endDate = endDate
     }
 
     // Reminders are minutes before the event start; EKAlarm takes a negative
     // offset in seconds relative to the start date.
     let reminderMinutes = Self.reminderMinutesArg(args["reminders"])
     for minutes in reminderMinutes {
       event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
     }
 
     do {
       try eventStore.save(event, span: .thisEvent, commit: true)
     } catch {
       return Self.errorPayload("INSERT_FAILED", "Failed to save calendar event: \(error.localizedDescription)")
     }
 
     var payload: [String: Any] = [
       "success": true,
       "event_id": event.eventIdentifier ?? "",
       "title": title,
       "all_day": allDay,
       "location": event.location ?? "",
       "reminders": reminderMinutes,
     ]
     if allDay {
       payload["start"] = Self.formatDateOnly(allDayStart, calendar: calendar)
       payload["end"] = Self.formatDateOnly(allDayEndExclusive, calendar: calendar)
     } else {
       payload["start"] = Self.formatDateTime(startDate)
       payload["end"] = Self.formatDateTime(endDate)
     }
     return Self.jsonString(payload)
   }
 
   // MARK: - Argument/JSON helpers
 
   private static func parseArgs(_ arguments: Any?) -> [String: Any] {
     guard
       let json = arguments as? String,
       let data = json.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
     else {
       return [:]
     }
     return parsed
   }
 
   private static func intArg(_ value: Any?) -> Int? {
     if let number = value as? Int { return number }
     if let number = value as? Double { return Int(number) }
     if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
     return nil
   }
 
   /// Reminder offsets in minutes before the event start. Accepts a JSON array,
   /// or a single number/string for convenience. Negative values (models
   /// sometimes send "-10" for "10 minutes before") are folded to positive;
   /// duplicates are dropped and at most 5 are kept, matching EventKit's
   /// practical limit for well-behaved events.
   private static func reminderMinutesArg(_ value: Any?) -> [Int] {
     let raw: [Any]
     if let list = value as? [Any] {
       raw = list
     } else if let value, !(value is NSNull) {
       raw = [value]
     } else {
       return []
     }
     var seen = Set<Int>()
     var minutes: [Int] = []
     for item in raw {
       guard let normalized = clampedMinutes(item) else { continue }
       if seen.insert(normalized).inserted {
         minutes.append(normalized)
       }
       if minutes.count == 5 { break }
     }
     return minutes
   }
 
   /// Clamps one reminder offset into 0...40320 minutes (4 weeks). Parsed as a
   /// Double throughout: an out-of-range or Int.min value would trap on the
   /// Int conversion, and these values come straight from model output.
   private static func clampedMinutes(_ value: Any?) -> Int? {
     let raw: Double
     if let number = value as? NSNumber {
       raw = number.doubleValue
     } else if let text = (value as? String)?.trimmingCharacters(in: .whitespaces),
               let parsed = Double(text) {
       raw = parsed
     } else {
       return nil
     }
     guard raw.isFinite else { return nil }
     return Int(min(abs(raw), 40320))
   }
 
   private static func boolArg(_ value: Any?) -> Bool? {
     if let flag = value as? Bool { return flag }
     if let text = (value as? String)?.lowercased() {
       if text == "true" { return true }
       if text == "false" { return false }
     }
     return nil
   }
 
   private static func jsonString(_ payload: [String: Any]) -> String {
     guard
       let data = try? JSONSerialization.data(withJSONObject: payload),
       let text = String(data: data, encoding: .utf8)
     else {
       return "{\"error\":\"ENCODING_ERROR\",\"message\":\"Failed to encode tool result.\"}"
     }
     return text
   }
 
   private static func errorPayload(_ error: String, _ message: String) -> String {
     jsonString(["error": error, "message": message])
   }
 
   private static func invalidTimePayload(_ raw: String) -> String {
     errorPayload(
       "INVALID_TIME",
       "Invalid time format: '\(raw)'. Use ISO-8601 date/date-time or epoch milliseconds."
     )
   }
 
   // MARK: - Time parsing/formatting
 
   /// Parses epoch milliseconds, offset date-times, local date-times, and
   /// plain dates (interpreted at local midnight), mirroring the Android tool.
   private static func parseTime(_ raw: String, calendar: Calendar) -> Date? {
     let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
     if !text.isEmpty, text.allSatisfy({ $0.isNumber }), let millis = Double(text) {
       return Date(timeIntervalSince1970: millis / 1000.0)
     }
 
     let isoWithFraction = ISO8601DateFormatter()
     isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
     if let date = isoWithFraction.date(from: text) { return date }
 
     let iso = ISO8601DateFormatter()
     iso.formatOptions = [.withInternetDateTime]
     if let date = iso.date(from: text) { return date }
 
     for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
       let formatter = DateFormatter()
       formatter.locale = Locale(identifier: "en_US_POSIX")
       formatter.timeZone = calendar.timeZone
       formatter.dateFormat = format
       if let date = formatter.date(from: text) { return date }
     }
     return nil
   }
 
   private static func formatDateTime(_ date: Date) -> String {
     let formatter = ISO8601DateFormatter()
     formatter.formatOptions = [.withInternetDateTime]
     formatter.timeZone = .current
     return formatter.string(from: date)
   }
 
   private static func formatDateOnly(_ date: Date, calendar: Calendar) -> String {
     let formatter = DateFormatter()
     formatter.locale = Locale(identifier: "en_US_POSIX")
     formatter.timeZone = calendar.timeZone
     formatter.dateFormat = "yyyy-MM-dd"
     return formatter.string(from: date)
   }
 
   /// Converts a stored all-day end date to the tool's exclusive end date.
   /// EventKit keeps the end inside the last included day (e.g. 23:59:59),
   /// while the tool reports the next-day midnight boundary. Ends already at
   /// an exact midnight are treated as exclusive and returned unchanged.
   private static func exclusiveAllDayEnd(_ end: Date, calendar: Calendar) -> Date {
     calendar.startOfDay(for: end.addingTimeInterval(1))
   }
 }

import Foundation
import UIKit

/// Shared JSON, time, and permission helpers for device-local tools.
enum DeviceToolsSupport {
  static func parseArgs(_ arguments: Any?) -> [String: Any] {
    guard
      let json = arguments as? String,
      let data = json.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }
    return parsed
  }

  static func intArg(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? Double { return Int(number) }
    if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
    return nil
  }

  static func doubleArg(_ value: Any?) -> Double? {
    if let number = value as? Double { return number }
    if let number = value as? Int { return Double(number) }
    if let number = value as? NSNumber { return number.doubleValue }
    if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
    return nil
  }

  static func boolArg(_ value: Any?) -> Bool? {
    if let flag = value as? Bool { return flag }
    if let text = (value as? String)?.lowercased() {
      if text == "true" { return true }
      if text == "false" { return false }
    }
    return nil
  }

  static func jsonString(_ payload: [String: Any]) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload),
      let text = String(data: data, encoding: .utf8)
    else {
      return "{\"error\":\"ENCODING_ERROR\",\"message\":\"Failed to encode tool result.\"}"
    }
    return text
  }

  static func errorPayload(_ error: String, _ message: String) -> String {
    jsonString(["error": error, "message": message])
  }

  static func invalidTimePayload(_ raw: String) -> String {
    errorPayload(
      "INVALID_TIME",
      "Invalid time format: '\(raw)'. Use ISO-8601 date/date-time or epoch milliseconds."
    )
  }

  static func noPermissionPayload(_ message: String) -> String {
    errorPayload("NO_PERMISSION", message)
  }

  static func isoCalendar() -> Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = .current
    return calendar
  }

  /// True when the raw string is a date-only `yyyy-MM-dd` (no time).
  static func isDateOnly(_ raw: String) -> Bool {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count == 10 else { return false }
    let parts = text.split(separator: "-")
    return parts.count == 3
      && parts[0].count == 4 && parts[0].allSatisfy(\.isNumber)
      && parts[1].count == 2 && parts[1].allSatisfy(\.isNumber)
      && parts[2].count == 2 && parts[2].allSatisfy(\.isNumber)
  }

  /// Parses epoch milliseconds, offset date-times, local date-times, and
  /// plain dates (interpreted at local midnight).
  static func parseTime(_ raw: String, calendar: Calendar) -> Date? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty, text.allSatisfy({ $0.isNumber }), let millis = Double(text) {
      return Date(timeIntervalSince1970: millis / 1000.0)
    }

    let isoWithFraction = ISO8601DateFormatter()
    isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoWithFraction.date(from: text) { return date }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: text) { return date }

    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = calendar.timeZone
      formatter.dateFormat = format
      if let date = formatter.date(from: text) { return date }
    }
    return nil
  }

  static func formatDateTime(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = .current
    return formatter.string(from: date)
  }

  static func formatDateOnly(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  /// Resolves a begin/end or range preset into `[start, end)`.
  /// On failure, `error` is a ready-to-return JSON payload.
  static func resolveDateRange(
    args: [String: Any],
    defaultPreset: String,
    allowedPresets: Set<String>
  ) -> (start: Date, end: Date, error: String?) {
    let calendar = isoCalendar()
    let now = Date()
    let startOfToday = calendar.startOfDay(for: now)
    let rangePreset = (args["range"] as? String)?.lowercased() ?? defaultPreset

    if let beginRaw = args["begin"] as? String, !beginRaw.isEmpty {
      guard let parsedStart = parseTime(beginRaw, calendar: calendar) else {
        return (now, now, invalidTimePayload(beginRaw))
      }
      if let endRaw = args["end"] as? String, !endRaw.isEmpty {
        guard let parsedEnd = parseTime(endRaw, calendar: calendar) else {
          return (now, now, invalidTimePayload(endRaw))
        }
        guard parsedStart < parsedEnd else {
          return (now, now, errorPayload("INVALID_RANGE", "begin must be earlier than end."))
        }
        return (parsedStart, parsedEnd, nil)
      }
      guard parsedStart < now else {
        return (now, now, errorPayload("INVALID_RANGE", "begin must be earlier than end."))
      }
      return (parsedStart, now, nil)
    }

    let preset = allowedPresets.contains(rangePreset) ? rangePreset : defaultPreset
    let startDate: Date
    let endDate: Date
    switch preset {
    case "week":
      let weekStart = calendar.date(
        from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
      ) ?? startOfToday
      startDate = weekStart
      endDate = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? now
    case "month":
      let monthStart = calendar.date(
        from: calendar.dateComponents([.year, .month], from: now)
      ) ?? startOfToday
      startDate = monthStart
      endDate = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now
    default:
      startDate = startOfToday
      endDate = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
    }
    return (startDate, endDate, nil)
  }

  static func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  static func finishOnMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }
}

import CoreLocation
import Foundation

/// One-shot When-In-Use location for `get_current_location` and WeatherKit.
final class LocationToolHandler: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()

  /// iOS 13-compatible authorization status accessor.
  private var currentAuthStatus: CLAuthorizationStatus {
    if #available(iOS 14.0, *) {
      return manager.authorizationStatus
    } else {
      return CLLocationManager.authorizationStatus()
    }
  }
  private var pendingLocation: ((Result<CLLocation, LocationToolError>) -> Void)?
  private var pendingAuth: [(CLAuthorizationStatus) -> Void] = []
  private var locationTimeout: DispatchWorkItem?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.distanceFilter = kCLDistanceFilterNone
  }

  func hasPermission() -> Bool {
    isAuthorized(currentAuthStatus)
  }

  /// Settings toggle: prompt when undetermined; open Settings when denied.
  func requestPermission(completion: @escaping (Bool) -> Void) {
    DeviceToolsSupport.finishOnMain { [weak self] in
      guard let self else {
        completion(false)
        return
      }
      guard CLLocationManager.locationServicesEnabled() else {
        completion(false)
        return
      }
      let status = self.currentAuthStatus
      if self.isAuthorized(status) {
        completion(true)
        return
      }
      switch status {
      case .notDetermined:
        self.enqueueAuthorization { next in completion(self.isAuthorized(next)) }
      default:
        DeviceToolsSupport.openAppSettings()
        completion(false)
      }
    }
  }

  func getCurrentLocation(args: [String: Any], completion: @escaping (String) -> Void) {
    requestOneShotLocation(openSettingsIfDenied: false) { [weak self] result in
      switch result {
      case .failure(let error):
        completion(error.payload)
      case .success(let location):
        self?.buildPayload(location: location, completion: completion)
      }
    }
  }

  /// Resolves a `CLLocation` from explicit coordinates or a one-shot GPS fix.
  func resolveLocation(
    latitude: Double?,
    longitude: Double?,
    completion: @escaping (Result<CLLocation, LocationToolError>) -> Void
  ) {
    if let latitude, let longitude {
      guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
        completion(.failure(.invalidCoordinates))
        return
      }
      completion(.success(CLLocation(latitude: latitude, longitude: longitude)))
      return
    }
    if (latitude == nil) != (longitude == nil) {
      completion(.failure(.invalidCoordinates))
      return
    }
    requestOneShotLocation(openSettingsIfDenied: false, completion: completion)
  }

  func requestOneShotLocation(
    openSettingsIfDenied: Bool,
    completion: @escaping (Result<CLLocation, LocationToolError>) -> Void
  ) {
    DeviceToolsSupport.finishOnMain { [weak self] in
      guard let self else {
        completion(.failure(.unavailable))
        return
      }
      guard CLLocationManager.locationServicesEnabled() else {
        completion(.failure(.servicesDisabled))
        return
      }
      if self.pendingLocation != nil {
        completion(.failure(.busy))
        return
      }

      let deliver: (Result<CLLocation, LocationToolError>) -> Void = { result in
        DeviceToolsSupport.finishOnMain { completion(result) }
      }

      let startRequest = { [weak self] in
        guard let self else {
          deliver(.failure(.unavailable))
          return
        }
        if self.pendingLocation != nil {
          deliver(.failure(.busy))
          return
        }
        self.pendingLocation = deliver
        let timeout = DispatchWorkItem { [weak self] in
          guard let self, let pending = self.pendingLocation else { return }
          self.pendingLocation = nil
          pending(.failure(.timeout))
        }
        self.locationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        self.manager.requestLocation()
      }

      let status = self.currentAuthStatus
      if self.isAuthorized(status) {
        startRequest()
        return
      }
      if status == .notDetermined {
        self.enqueueAuthorization { [weak self] next in
          guard let self else { return }
          if self.isAuthorized(next) {
            startRequest()
          } else {
            deliver(.failure(.denied))
          }
        }
        return
      }
      if openSettingsIfDenied {
        DeviceToolsSupport.openAppSettings()
      }
      deliver(.failure(.denied))
    }
  }

  private func buildPayload(location: CLLocation, completion: @escaping (String) -> Void) {
    var payload: [String: Any] = [
      "latitude": location.coordinate.latitude,
      "longitude": location.coordinate.longitude,
      "accuracy_m": location.horizontalAccuracy,
      "timestamp": DeviceToolsSupport.formatDateTime(location.timestamp),
      "timestamp_ms": Int(location.timestamp.timeIntervalSince1970 * 1000),
    ]
    if location.verticalAccuracy >= 0 {
      payload["altitude_m"] = location.altitude
    }

    let geocoder = CLGeocoder()
    geocoder.reverseGeocodeLocation(location) { marks, _ in
      if let mark = marks?.first {
        if let city = mark.locality, !city.isEmpty { payload["city"] = city }
        if let region = mark.administrativeArea, !region.isEmpty { payload["region"] = region }
        if let country = mark.country, !country.isEmpty { payload["country"] = country }
        if let name = mark.name, !name.isEmpty { payload["place_name"] = name }
      }
      completion(DeviceToolsSupport.jsonString(payload))
    }
  }

  private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
    status == .authorizedWhenInUse || status == .authorizedAlways
  }

  private func enqueueAuthorization(_ completion: @escaping (CLAuthorizationStatus) -> Void) {
    let alreadyWaiting = !pendingAuth.isEmpty
    pendingAuth.append(completion)
    if !alreadyWaiting {
      manager.requestWhenInUseAuthorization()
    }
  }

  private func finishLocation(_ result: Result<CLLocation, LocationToolError>) {
    locationTimeout?.cancel()
    locationTimeout = nil
    let pending = pendingLocation
    pendingLocation = nil
    pending?(result)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let pending = pendingAuth
    pendingAuth.removeAll()
    for completion in pending {
      completion(currentAuthStatus)
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else {
      finishLocation(.failure(.unavailable))
      return
    }
    finishLocation(.success(location))
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    if let clError = error as? CLError, clError.code == .denied {
      finishLocation(.failure(.denied))
      return
    }
    finishLocation(.failure(.unavailable))
  }
}

enum LocationToolError: Error {
  case denied
  case servicesDisabled
  case timeout
  case busy
  case unavailable
  case invalidCoordinates

  var payload: String {
    switch self {
    case .denied:
      return DeviceToolsSupport.noPermissionPayload(
        "Location permission is not granted. Please allow Location While Using the App "
          + "in system Settings and try again."
      )
    case .servicesDisabled:
      return DeviceToolsSupport.errorPayload(
        "LOCATION_DISABLED",
        "Location services are turned off on this device."
      )
    case .timeout:
      return DeviceToolsSupport.errorPayload(
        "LOCATION_TIMEOUT",
        "Timed out waiting for a location fix. Please try again."
      )
    case .busy:
      return DeviceToolsSupport.errorPayload(
        "LOCATION_BUSY",
        "A location request is already in progress. Please try again."
      )
    case .unavailable:
      return DeviceToolsSupport.errorPayload(
        "LOCATION_UNAVAILABLE",
        "Could not determine the current location."
      )
    case .invalidCoordinates:
      return DeviceToolsSupport.errorPayload(
        "INVALID_COORDINATES",
        "latitude must be between -90 and 90, longitude between -180 and 180. "
          + "Provide both, or omit both to use the current location."
      )
    }
  }
}

import Foundation
import HealthKit

/// HealthKit summary for `get_health_summary`.
///
/// Read authorization cannot be distinguished from "no samples" on iOS, so
/// missing metrics are returned as `{ "status": "unavailable" }` rather than 0.
final class HealthToolHandler {
  private let store = HKHealthStore()

  func isAvailable() -> Bool {
    HKHealthStore.isHealthDataAvailable()
  }

  /// Settings toggle: presents the Health read sheet. The completion flag is
  /// only "the sheet finished"; iOS does not reveal per-type read grants.
  func requestPermission(completion: @escaping (Bool) -> Void) {
    DeviceToolsSupport.finishOnMain { [weak self] in
      guard let self else {
        completion(false)
        return
      }
      guard self.isAvailable() else {
        completion(false)
        return
      }
      self.store.requestAuthorization(toShare: [], read: self.readTypes) { success, _ in
        DeviceToolsSupport.finishOnMain { completion(success) }
      }
    }
  }

  func getHealthSummary(args: [String: Any], completion: @escaping (String) -> Void) {
    guard isAvailable() else {
      completion(
        DeviceToolsSupport.errorPayload(
          "HEALTH_UNAVAILABLE",
          "Health data is not available on this device."
        )
      )
      return
    }

    store.requestAuthorization(toShare: [], read: readTypes) { [weak self] _, _ in
      guard let self else { return }
      self.buildSummary(completion: completion)
    }
  }

  private var readTypes: Set<HKObjectType> {
    var types = Set<HKObjectType>()
    if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
      types.insert(steps)
    }
    if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
      types.insert(energy)
    }
    if let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
      types.insert(distance)
    }
    if let heart = HKObjectType.quantityType(forIdentifier: .heartRate) {
      types.insert(heart)
    }
    if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
      types.insert(sleep)
    }
    types.insert(HKObjectType.workoutType())
    return types
  }

  private func buildSummary(completion: @escaping (String) -> Void) {
    let calendar = DeviceToolsSupport.isoCalendar()
    let now = Date()
    let startOfToday = calendar.startOfDay(for: now)
    // Last night: yesterday 18:00 → today noon (not yesterday 06:00).
    let lastNightStart = calendar.date(byAdding: .hour, value: -6, to: startOfToday) ?? startOfToday
    let lastNightEnd = calendar.date(byAdding: .hour, value: 12, to: startOfToday) ?? now
    let workoutLookback = calendar.date(byAdding: .day, value: -14, to: now) ?? now
    let updatedAt = DeviceToolsSupport.formatDateTime(now)

    let group = DispatchGroup()
    var steps: [String: Any] = Self.unavailable(startOfToday, now)
    var energy: [String: Any] = Self.unavailable(startOfToday, now)
    var distance: [String: Any] = Self.unavailable(startOfToday, now)
    var sleep: [String: Any] = Self.unavailable(lastNightStart, lastNightEnd)
    var heartRate: [String: Any] = ["status": "unavailable"]
    var workouts: [String: Any] = ["status": "unavailable"]

    if let type = HKQuantityType.quantityType(forIdentifier: .stepCount) {
      group.enter()
      querySum(type: type, unit: .count(), start: startOfToday, end: now) { metric in
        steps = metric
        group.leave()
      }
    }
    if let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
      group.enter()
      querySum(type: type, unit: .kilocalorie(), start: startOfToday, end: now) { metric in
        energy = metric
        group.leave()
      }
    }
    if let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
      group.enter()
      querySum(type: type, unit: .meter(), start: startOfToday, end: now) { metric in
        distance = metric
        group.leave()
      }
    }
    group.enter()
    querySleep(start: lastNightStart, end: lastNightEnd) { metric in
      sleep = metric
      group.leave()
    }
    group.enter()
    queryLatestHeartRate { metric in
      heartRate = metric
      group.leave()
    }
    group.enter()
    queryWorkouts(start: workoutLookback, end: now, limit: 5) { metric in
      workouts = metric
      group.leave()
    }

    group.notify(queue: .global(qos: .userInitiated)) {
      let payload: [String: Any] = [
        "updated_at": updatedAt,
        "interval": [
          "start": DeviceToolsSupport.formatDateTime(startOfToday),
          "end": DeviceToolsSupport.formatDateTime(now),
        ],
        "steps": steps,
        "active_energy_kcal": energy,
        "walking_running_distance_m": distance,
        "sleep_last_night": sleep,
        "heart_rate": heartRate,
        "workouts": workouts,
      ]
      DeviceToolsSupport.finishOnMain {
        completion(DeviceToolsSupport.jsonString(payload))
      }
    }
  }

  private func querySum(
    type: HKQuantityType,
    unit: HKUnit,
    start: Date,
    end: Date,
    completion: @escaping ([String: Any]) -> Void
  ) {
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
    let query = HKStatisticsQuery(
      quantityType: type,
      quantitySamplePredicate: predicate,
      options: .cumulativeSum
    ) { _, statistics, _ in
      guard let quantity = statistics?.sumQuantity() else {
        completion(Self.unavailable(start, end))
        return
      }
      var metric = Self.interval(start, end)
      metric["status"] = "ok"
      metric["value"] = (quantity.doubleValue(for: unit) * 10).rounded() / 10
      completion(metric)
    }
    store.execute(query)
  }

  private func querySleep(start: Date, end: Date, completion: @escaping ([String: Any]) -> Void) {
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
      completion(Self.unavailable(start, end))
      return
    }
    // Default options: samples that overlap the window, not only those that start in it.
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
    let query = HKSampleQuery(
      sampleType: sleepType,
      predicate: predicate,
      limit: HKObjectQueryNoLimit,
      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]
    ) { _, samples, _ in
      let categorySamples = samples as? [HKCategorySample] ?? []
      guard let asleep = Self.mergedAsleepInterval(
        categorySamples,
        windowStart: start,
        windowEnd: end
      ) else {
        completion(Self.unavailable(start, end))
        return
      }
      var metric = Self.interval(start, end)
      metric["status"] = "ok"
      metric["duration_minutes"] = Int((asleep.duration / 60).rounded())
      metric["sleep_start"] = DeviceToolsSupport.formatDateTime(asleep.start)
      metric["sleep_end"] = DeviceToolsSupport.formatDateTime(asleep.end)
      completion(metric)
    }
    store.execute(query)
  }

  private func queryLatestHeartRate(completion: @escaping ([String: Any]) -> Void) {
    guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
      completion(["status": "unavailable"])
      return
    }
    let query = HKSampleQuery(
      sampleType: type,
      predicate: nil,
      limit: 1,
      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
    ) { _, samples, _ in
      guard let sample = samples?.first as? HKQuantitySample else {
        completion(["status": "unavailable"])
        return
      }
      let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
      completion([
        "status": "ok",
        "bpm": (bpm * 10).rounded() / 10,
        "measured_at": DeviceToolsSupport.formatDateTime(sample.endDate),
      ])
    }
    store.execute(query)
  }

  private func queryWorkouts(
    start: Date,
    end: Date,
    limit: Int,
    completion: @escaping ([String: Any]) -> Void
  ) {
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
    let query = HKSampleQuery(
      sampleType: .workoutType(),
      predicate: predicate,
      limit: limit,
      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
    ) { _, samples, _ in
      let workouts = samples as? [HKWorkout] ?? []
      guard !workouts.isEmpty else {
        var metric = Self.unavailable(start, end)
        metric["items"] = []
        completion(metric)
        return
      }
      let items: [[String: Any]] = workouts.map { workout in
        var item: [String: Any] = [
          "type": Self.workoutName(workout.workoutActivityType),
          "start": DeviceToolsSupport.formatDateTime(workout.startDate),
          "end": DeviceToolsSupport.formatDateTime(workout.endDate),
          "duration_minutes": Int((workout.duration / 60).rounded()),
        ]
        if let energy = workout.totalEnergyBurned {
          item["active_energy_kcal"] =
            (energy.doubleValue(for: .kilocalorie()) * 10).rounded() / 10
        }
        if let distance = workout.totalDistance {
          item["distance_m"] = (distance.doubleValue(for: .meter()) * 10).rounded() / 10
        }
        return item
      }
      var metric = Self.interval(start, end)
      metric["status"] = "ok"
      metric["items"] = items
      completion(metric)
    }
    store.execute(query)
  }

  /// Clips asleep samples to the query window, then unions overlaps so Watch
  /// + third-party sources are not double-counted.
  private static func mergedAsleepInterval(
    _ samples: [HKCategorySample],
    windowStart: Date,
    windowEnd: Date
  ) -> (duration: TimeInterval, start: Date, end: Date)? {
    var intervals: [(start: Date, end: Date)] = []
    for sample in samples where isAsleep(sample) {
      let clippedStart = max(sample.startDate, windowStart)
      let clippedEnd = min(sample.endDate, windowEnd)
      guard clippedStart < clippedEnd else { continue }
      intervals.append((clippedStart, clippedEnd))
    }
    guard !intervals.isEmpty else { return nil }
    intervals.sort { $0.start < $1.start }

    var merged: [(start: Date, end: Date)] = [intervals[0]]
    for interval in intervals.dropFirst() {
      let lastIndex = merged.count - 1
      if interval.start <= merged[lastIndex].end {
        merged[lastIndex].end = max(merged[lastIndex].end, interval.end)
      } else {
        merged.append(interval)
      }
    }

    let duration = merged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
    guard duration > 0 else { return nil }
    let start = merged[0].start
    let end = merged.map(\.end).max() ?? merged[0].end
    return (duration, start, end)
  }

  private static func isAsleep(_ sample: HKCategorySample) -> Bool {
    if #available(iOS 16.0, *) {
      switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
      case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM:
        return true
      default:
        return false
      }
    }
    return sample.value == 1
  }

  private static func unavailable(_ start: Date, _ end: Date) -> [String: Any] {
    var metric = interval(start, end)
    metric["status"] = "unavailable"
    return metric
  }

  private static func interval(_ start: Date, _ end: Date) -> [String: Any] {
    [
      "start": DeviceToolsSupport.formatDateTime(start),
      "end": DeviceToolsSupport.formatDateTime(end),
    ]
  }

  private static func workoutName(_ type: HKWorkoutActivityType) -> String {
    if #available(iOS 16.0, *) {
      switch type {
      case .running: return "running"
      case .walking: return "walking"
      case .cycling: return "cycling"
      case .swimming: return "swimming"
      case .yoga: return "yoga"
      case .functionalStrengthTraining: return "strength"
      case .traditionalStrengthTraining: return "strength"
      case .coreTraining: return "core"
      case .elliptical: return "elliptical"
      case .rowing: return "rowing"
      case .hiking: return "hiking"
      case .dance: return "dance"
      case .cooldown: return "cooldown"
      case .mixedCardio: return "cardio"
      case .highIntensityIntervalTraining: return "hiit"
      default: return "other"
      }
    }
    return "other"
  }
}

import EventKit
import Foundation

/// EventKit reminders backend. Shares `EKEventStore` with calendar tools.
final class RemindersToolHandler {
  private let eventStore: EKEventStore

  init(eventStore: EKEventStore) {
    self.eventStore = eventStore
  }

  func hasPermission() -> Bool {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if #available(iOS 17.0, *) {
      return status == .fullAccess
    }
    return status == .authorized
  }

  func requestPermission(completion: @escaping (Bool) -> Void) {
    let finish: (Bool) -> Void = { granted in
      DeviceToolsSupport.finishOnMain { completion(granted) }
    }
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if hasPermission() {
      finish(true)
      return
    }
    if status == .notDetermined {
      requestAccess { granted in finish(granted) }
      return
    }
    DeviceToolsSupport.openAppSettings()
    finish(false)
  }

  func ensureAccess(completion: @escaping (Bool) -> Void) {
    let finish: (Bool) -> Void = { granted in
      DeviceToolsSupport.finishOnMain { completion(granted) }
    }
    if hasPermission() {
      finish(true)
      return
    }
    if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
      requestAccess { granted in finish(granted) }
      return
    }
    finish(false)
  }

  func query(args: [String: Any], completion: @escaping (String) -> Void) {
    let range = DeviceToolsSupport.resolveDateRange(
      args: args,
      defaultPreset: "today",
      allowedPresets: ["today", "week", "month"]
    )
    if let error = range.error {
      completion(error)
      return
    }

    let limit = min(max(DeviceToolsSupport.intArg(args["limit"]) ?? 20, 1), 100)
    let keyword = (args["query"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let completedFilter = completedArg(args["completed"])
    let calendar = DeviceToolsSupport.isoCalendar()

    let predicate = eventStore.predicateForReminders(in: nil)
    eventStore.fetchReminders(matching: predicate) { reminders in
      var items = reminders ?? []
      items = items.filter { reminder in
        if let completedFilter {
          if reminder.isCompleted != completedFilter { return false }
        }
        if let keyword, !keyword.isEmpty {
          let title = (reminder.title ?? "").lowercased()
          let notes = (reminder.notes ?? "").lowercased()
          if !title.contains(keyword) && !notes.contains(keyword) { return false }
        }
        if let due = Self.dueDate(reminder, calendar: calendar) {
          return due >= range.start && due < range.end
        }
        // Undated reminders are included only when no explicit begin/end
        // was given (preset query), so "today's list" still shows inbox items.
        return args["begin"] == nil
      }
      items.sort { lhs, rhs in
        let left = Self.dueDate(lhs, calendar: calendar) ?? .distantFuture
        let right = Self.dueDate(rhs, calendar: calendar) ?? .distantFuture
        if left != right { return left < right }
        return (lhs.title ?? "") < (rhs.title ?? "")
      }

      let payloadItems: [[String: Any]] = items.prefix(limit).map { reminder in
        var item: [String: Any] = [
          "id": reminder.calendarItemIdentifier,
          "title": reminder.title ?? "",
          "notes": reminder.notes ?? "",
          "completed": reminder.isCompleted,
          "priority": reminder.priority,
          "list": reminder.calendar?.title ?? "",
        ]
        Self.applyDue(reminder, to: &item, calendar: calendar)
        if reminder.isCompleted, let completedAt = reminder.completionDate {
          item["completed_at"] = DeviceToolsSupport.formatDateTime(completedAt)
        }
        return item
      }

      completion(
        DeviceToolsSupport.jsonString([
          "range_start": DeviceToolsSupport.formatDateTime(range.start),
          "range_end": DeviceToolsSupport.formatDateTime(range.end),
          "count": payloadItems.count,
          "reminders": payloadItems,
        ])
      )
    }
  }

  func create(args: [String: Any]) -> String {
    let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !title.isEmpty else {
      return DeviceToolsSupport.errorPayload("MISSING_REQUIRED", "'title' is required.")
    }
    guard let calendar = eventStore.defaultCalendarForNewReminders() else {
      return DeviceToolsSupport.errorPayload(
        "NO_REMINDERS_LIST",
        "No reminders list found on this device. Please add a Reminders account first."
      )
    }

    let reminder = EKReminder(eventStore: eventStore)
    reminder.calendar = calendar
    reminder.title = title
    if let notes = args["notes"] as? String, !notes.isEmpty {
      reminder.notes = notes
    } else if let notes = args["description"] as? String, !notes.isEmpty {
      reminder.notes = notes
    }
    reminder.priority = normalizedPriority(args["priority"])

    if let dueRaw = (args["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !dueRaw.isEmpty {
      let calendar = DeviceToolsSupport.isoCalendar()
      guard let due = DeviceToolsSupport.parseTime(dueRaw, calendar: calendar) else {
        return DeviceToolsSupport.invalidTimePayload(dueRaw)
      }
      // EventKit requires startDateComponents whenever dueDateComponents is set.
      // Date-only `yyyy-MM-dd` is an all-day reminder (no time components).
      let units: Set<Calendar.Component> = DeviceToolsSupport.isDateOnly(dueRaw)
        ? [.year, .month, .day]
        : [.year, .month, .day, .hour, .minute, .second, .timeZone]
      let components = calendar.dateComponents(units, from: due)
      reminder.startDateComponents = components
      reminder.dueDateComponents = components
    }

    do {
      try eventStore.save(reminder, commit: true)
    } catch {
      return DeviceToolsSupport.errorPayload(
        "INSERT_FAILED",
        "Failed to save reminder: \(error.localizedDescription)"
      )
    }

    var payload: [String: Any] = [
      "success": true,
      "id": reminder.calendarItemIdentifier,
      "title": reminder.title ?? title,
      "notes": reminder.notes ?? "",
      "priority": reminder.priority,
      "completed": false,
      "list": reminder.calendar?.title ?? "",
    ]
    Self.applyDue(reminder, to: &payload, calendar: DeviceToolsSupport.isoCalendar())
    return DeviceToolsSupport.jsonString(payload)
  }

  func complete(args: [String: Any]) -> String {
    let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !id.isEmpty else {
      return DeviceToolsSupport.errorPayload("MISSING_REQUIRED", "'id' is required.")
    }
    guard let item = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
      return DeviceToolsSupport.errorPayload(
        "NOT_FOUND",
        "No reminder found with id '\(id)'."
      )
    }
    if item.isCompleted {
      return DeviceToolsSupport.jsonString([
        "success": true,
        "id": item.calendarItemIdentifier,
        "title": item.title ?? "",
        "completed": true,
        "already_completed": true,
      ])
    }
    item.isCompleted = true
    do {
      try eventStore.save(item, commit: true)
    } catch {
      return DeviceToolsSupport.errorPayload(
        "UPDATE_FAILED",
        "Failed to complete reminder: \(error.localizedDescription)"
      )
    }
    var payload: [String: Any] = [
      "success": true,
      "id": item.calendarItemIdentifier,
      "title": item.title ?? "",
      "completed": true,
    ]
    if let completedAt = item.completionDate {
      payload["completed_at"] = DeviceToolsSupport.formatDateTime(completedAt)
    }
    return DeviceToolsSupport.jsonString(payload)
  }

  private func requestAccess(completion: @escaping (Bool) -> Void) {
    if #available(iOS 17.0, *) {
      eventStore.requestFullAccessToReminders { granted, _ in completion(granted) }
    } else {
      eventStore.requestAccess(to: .reminder) { granted, _ in completion(granted) }
    }
  }

  /// `true`/`false` filter, or nil for all. Also accepts "all".
  private func completedArg(_ value: Any?) -> Bool? {
    if let flag = DeviceToolsSupport.boolArg(value) { return flag }
    if let text = (value as? String)?.lowercased() {
      if text == "all" { return nil }
    }
    return nil
  }

  private static func dueDate(_ reminder: EKReminder, calendar: Calendar) -> Date? {
    guard var components = reminder.dueDateComponents else { return nil }
    if components.calendar == nil {
      components.calendar = calendar
    }
    return components.date
  }

  /// All-day when EventKit stored a date with no hour/minute components.
  private static func isAllDay(_ reminder: EKReminder) -> Bool {
    guard let components = reminder.dueDateComponents else { return false }
    return components.hour == nil && components.minute == nil
  }

  private static func applyDue(
    _ reminder: EKReminder,
    to payload: inout [String: Any],
    calendar: Calendar
  ) {
    guard let due = dueDate(reminder, calendar: calendar) else { return }
    if isAllDay(reminder) {
      payload["due"] = DeviceToolsSupport.formatDateOnly(due, calendar: calendar)
      payload["all_day"] = true
    } else {
      payload["due"] = DeviceToolsSupport.formatDateTime(due)
      payload["all_day"] = false
    }
  }

  /// EventKit: 0 none, 1 high, 5 medium, 9 low. Also accepts those labels.
  private func normalizedPriority(_ value: Any?) -> Int {
    if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      switch text {
      case "high": return 1
      case "medium": return 5
      case "low": return 9
      case "none", "": return 0
      default: break
      }
    }
    guard let raw = DeviceToolsSupport.intArg(value) else { return 0 }
    return min(max(raw, 0), 9)
  }
}

/// Open-Meteo backend for `get_weather`.
///
/// Free, keyless, and needs no entitlement — a drop-in replacement for the
/// WeatherKit handler that keeps the exact same JSON payload shape so the
/// Flutter weather card renders unchanged. Data: https://open-meteo.com
final class OpenMeteoWeatherHandler {
  private let locationHandler: LocationToolHandler

  init(locationHandler: LocationToolHandler) {
    self.locationHandler = locationHandler
  }

  static var isAvailable: Bool { true }

  func getWeather(args: [String: Any], completion: @escaping (String) -> Void) {
    let latitude = DeviceToolsSupport.doubleArg(args["latitude"])
    let longitude = DeviceToolsSupport.doubleArg(args["longitude"])
    locationHandler.resolveLocation(latitude: latitude, longitude: longitude) { result in
      switch result {
      case .failure(let error):
        completion(error.payload)
      case .success(let location):
        self.fetch(
          latitude: location.coordinate.latitude,
          longitude: location.coordinate.longitude,
          completion: completion
        )
      }
    }
  }

  private func fetch(
    latitude: Double,
    longitude: Double,
    completion: @escaping (String) -> Void
  ) {
    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    components.queryItems = [
      URLQueryItem(name: "latitude", value: String(latitude)),
      URLQueryItem(name: "longitude", value: String(longitude)),
      URLQueryItem(
        name: "current",
        value:
          "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,cloud_cover,uv_index,precipitation_probability"
      ),
      URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
      URLQueryItem(
        name: "daily",
        value:
          "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"
      ),
      URLQueryItem(name: "timezone", value: "auto"),
      URLQueryItem(name: "forecast_days", value: "7"),
      URLQueryItem(name: "forecast_hours", value: "13"),
    ]
    guard let url = components.url else {
      completion(DeviceToolsSupport.errorPayload("BAD_URL", "Failed to build the weather request."))
      return
    }
    let task = URLSession.shared.dataTask(with: url) { data, response, error in
      if let error {
        completion(
          DeviceToolsSupport.errorPayload(
            "NETWORK_ERROR", "Weather request failed: \(error.localizedDescription)"))
        return
      }
      guard
        let data,
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else {
        completion(
          DeviceToolsSupport.errorPayload("BAD_RESPONSE", "Weather service returned invalid data."))
        return
      }
      if let reason = json["reason"] as? String {
        completion(DeviceToolsSupport.errorPayload("SERVICE_ERROR", reason))
        return
      }
      let payload = Self.buildPayload(json: json, latitude: latitude, longitude: longitude)
      completion(DeviceToolsSupport.jsonString(payload))
    }
    task.resume()
  }

  private static func buildPayload(
    json: [String: Any], latitude: Double, longitude: Double
  ) -> [String: Any] {
    let timezoneId = json["timezone"] as? String
    let current = json["current"] as? [String: Any] ?? [:]

    var currentPayload: [String: Any] = [:]
    if let t = current["time"] as? String { currentPayload["observed_at"] = t }
    let code = (current["weather_code"] as? NSNumber)?.intValue ?? -1
    currentPayload["condition"] = conditionText(code)
    currentPayload["symbol_name"] = symbolName(code)
    if let v = current["temperature_2m"] as? NSNumber {
      currentPayload["temperature_c"] = round1(v.doubleValue)
    }
    if let v = current["apparent_temperature"] as? NSNumber {
      currentPayload["apparent_temperature_c"] = round1(v.doubleValue)
    }
    if let v = current["relative_humidity_2m"] as? NSNumber {
      currentPayload["humidity"] = round2(v.doubleValue / 100.0)
    }
    if let v = current["uv_index"] as? NSNumber {
      currentPayload["uv_index"] = Int(v.doubleValue.rounded())
    }
    if let v = current["cloud_cover"] as? NSNumber {
      currentPayload["cloud_cover"] = round2(v.doubleValue / 100.0)
    }
    if let v = current["precipitation_probability"] as? NSNumber {
      currentPayload["precipitation_chance"] = round2(v.doubleValue / 100.0)
    }

    var hourly: [[String: Any]] = []
    if let h = json["hourly"] as? [String: Any],
      let times = h["time"] as? [String]
    {
      let temps = h["temperature_2m"] as? [Any] ?? []
      let codes = h["weather_code"] as? [Any] ?? []
      let precs = h["precipitation_probability"] as? [Any] ?? []
      for (i, time) in times.enumerated() {
        if hourly.count >= 12 { break }
        var item: [String: Any] = ["time": time]
        let hCode = (codes.indices.contains(i) ? codes[i] as? NSNumber : nil)?.intValue ?? -1
        item["condition"] = conditionText(hCode)
        item["symbol_name"] = symbolName(hCode)
        if let v = (temps.indices.contains(i) ? temps[i] as? NSNumber : nil) {
          item["temperature_c"] = round1(v.doubleValue)
        }
        if let v = (precs.indices.contains(i) ? precs[i] as? NSNumber : nil) {
          item["precipitation_chance"] = round2(v.doubleValue / 100.0)
        }
        hourly.append(item)
      }
    }

    var daily: [[String: Any]] = []
    if let d = json["daily"] as? [String: Any],
      let dates = d["time"] as? [String]
    {
      let codes = d["weather_code"] as? [Any] ?? []
      let highs = d["temperature_2m_max"] as? [Any] ?? []
      let lows = d["temperature_2m_min"] as? [Any] ?? []
      let precs = d["precipitation_probability_max"] as? [Any] ?? []
      let sunrises = d["sunrise"] as? [String] ?? []
      let sunsets = d["sunset"] as? [String] ?? []
      for (i, date) in dates.enumerated() {
        if daily.count >= 7 { break }
        var item: [String: Any] = ["date": date]
        let dCode = (codes.indices.contains(i) ? codes[i] as? NSNumber : nil)?.intValue ?? -1
        item["condition"] = conditionText(dCode)
        item["symbol_name"] = symbolName(dCode)
        if let v = (highs.indices.contains(i) ? highs[i] as? NSNumber : nil) {
          item["high_c"] = round1(v.doubleValue)
        }
        if let v = (lows.indices.contains(i) ? lows[i] as? NSNumber : nil) {
          item["low_c"] = round1(v.doubleValue)
        }
        if let v = (precs.indices.contains(i) ? precs[i] as? NSNumber : nil) {
          item["precipitation_chance"] = round2(v.doubleValue / 100.0)
        }
        if sunrises.indices.contains(i) { item["sunrise"] = sunrises[i] }
        if sunsets.indices.contains(i) { item["sunset"] = sunsets[i] }
        daily.append(item)
      }
    }

    var payload: [String: Any] = [
      "latitude": latitude,
      "longitude": longitude,
      "updated_at": DeviceToolsSupport.formatDateTime(Date()),
      "current": currentPayload,
      "hourly": hourly,
      "daily": daily,
      "attribution": [
        "service_name": "Open-Meteo",
        "legal_page_url": "https://open-meteo.com/",
        "display_text": "Weather data from Open-Meteo",
      ],
    ]
    payload["location_timezone"] = timezoneId ?? NSNull()
    return payload
  }

  private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
  private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

  /// WMO weather interpretation codes → human readable condition.
  private static func conditionText(_ code: Int) -> String {
    switch code {
    case 0: return "Clear"
    case 1: return "Mostly Clear"
    case 2: return "Partly Cloudy"
    case 3: return "Cloudy"
    case 45, 48: return "Fog"
    case 51, 53, 55, 56, 57: return "Drizzle"
    case 61, 63: return "Rain"
    case 65: return "Heavy Rain"
    case 66, 67: return "Freezing Rain"
    case 71, 73: return "Snow"
    case 75, 77: return "Heavy Snow"
    case 80, 81: return "Rain Showers"
    case 82: return "Heavy Rain Showers"
    case 85, 86: return "Snow Showers"
    case 95: return "Thunderstorm"
    case 96, 99: return "Thunderstorm with Hail"
    default: return "Unknown"
    }
  }

  /// WMO codes → SF Symbols names (same family WeatherKit uses).
  private static func symbolName(_ code: Int) -> String {
    switch code {
    case 0: return "sun.max"
    case 1: return "sun.max"
    case 2: return "cloud.sun"
    case 3: return "cloud"
    case 45, 48: return "cloud.fog"
    case 51, 53, 55, 56, 57: return "cloud.drizzle"
    case 61, 63: return "cloud.rain"
    case 65: return "cloud.heavyrain"
    case 66, 67: return "cloud.sleet"
    case 71, 73, 75, 77: return "cloud.snow"
    case 80, 81: return "cloud.rain"
    case 82: return "cloud.heavyrain"
    case 85, 86: return "cloud.snow"
    case 95, 96, 99: return "cloud.bolt.rain"
    default: return "questionmark.circle"
    }
  }
}
