import Flutter
import UIKit
import NetworkExtension
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, CLLocationManagerDelegate {
  private var locationManager: CLLocationManager?
  private var pendingWifiConnection: (() -> Void)?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let wifiChannel = FlutterMethodChannel(
        name: "com.snapable.wifi",
        binaryMessenger: controller.binaryMessenger
      )

      wifiChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "connectToWifi":
          self.handleConnectToWifi(call: call, result: result)
        case "clearWifiConfiguration":
          self.handleClearWifiConfiguration(call: call, result: result)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func requestLocationPermissionIfNeeded(completion: @escaping () -> Void) {
    let locationManager = CLLocationManager()
    self.locationManager = locationManager
    locationManager.delegate = self
    self.pendingWifiConnection = completion

    // Use static method for iOS 13 compatibility, instance property for iOS 14+
    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = locationManager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }
    
    if status == .authorizedWhenInUse || status == .authorizedAlways {
      // Already authorized, proceed
      completion()
      self.pendingWifiConnection = nil
    } else {
      // Request permission
      locationManager.requestWhenInUseAuthorization()
      // Completion will be called in locationManagerDidChangeAuthorization
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    // Use static method for iOS 13 compatibility, instance property for iOS 14+
    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = manager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }
    
    if status == .authorizedWhenInUse || status == .authorizedAlways {
      // Permission granted, proceed with WiFi connection
      if let completion = pendingWifiConnection {
        completion()
        pendingWifiConnection = nil
      }
    } else if status == .denied || status == .restricted {
      // Permission denied - this will be handled by the WiFi connection attempt
      if let completion = pendingWifiConnection {
        completion()
        pendingWifiConnection = nil
      }
    }
    // .notDetermined case will be handled when user responds
  }

  private func handleConnectToWifi(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let ssid = args["ssid"] as? String,
          !ssid.isEmpty else {
      result(
        FlutterError(
          code: "INVALID_ARGS",
          message: "SSID is required",
          details: nil
        )
      )
      return
    }

    let password = (args["password"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let joinOnce = args["joinOnce"] as? Bool ?? true

    // iOS 13+ requires location permission to configure WiFi
    requestLocationPermissionIfNeeded {
      self.applyWifiConfiguration(ssid: ssid, password: password, joinOnce: joinOnce, result: result)
    }
  }

  private func handleClearWifiConfiguration(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let ssid = args["ssid"] as? String,
          !ssid.isEmpty else {
      result(
        FlutterError(
          code: "INVALID_ARGS",
          message: "SSID is required",
          details: nil
        )
      )
      return
    }

    if #available(iOS 11.0, *) {
      NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
      result(["success": true])
    } else {
      result(
        FlutterError(
          code: "IOS_VERSION_UNSUPPORTED",
          message: "NEHotspotConfiguration is only available on iOS 11+",
          details: nil
        )
      )
    }
  }

  private func applyWifiConfiguration(ssid: String, password: String?, joinOnce: Bool, result: @escaping FlutterResult) {
    let configuration: NEHotspotConfiguration
    if let password, !password.isEmpty {
      configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
    } else {
      configuration = NEHotspotConfiguration(ssid: ssid)
    }
    configuration.joinOnce = joinOnce

    NEHotspotConfigurationManager.shared.apply(configuration) { error in
      if let error = error {
        // Cast to NSError to access domain and code
        let nsError = error as NSError
        
        // Check if it's a NEHotspotConfiguration error
        if nsError.domain == "NEHotspotConfigurationErrorDomain" {
          // Error codes: 0 = alreadyAssociated, 1 = userDenied, 2 = invalid, 3 = invalidSSID, 4 = invalidWPAPassphrase, 5 = invalidWEPPassphrase, 6 = invalidEAPSettings, 7 = invalidHS20Settings, 8 = invalidHS20DomainName, 9 = pendingSystemAuthorization, 10 = systemConfigurationDenied
          switch nsError.code {
          case 0: // alreadyAssociated
            result(["success": true, "status": "already_connected"])
            return
          case 1: // userDenied
            result(["success": false, "status": "user_denied"])
            return
          case 10: // systemConfigurationDenied - capability not available (personal dev account)
            result([
              "success": false,
              "status": "capability_not_available",
              "message": "Hotspot Configuration capability is not available with personal Apple Developer accounts. Please connect manually via Settings > Wi-Fi."
            ])
            return
          default:
            result(
              FlutterError(
                code: "IOS_WIFI_ERROR",
                message: nsError.localizedDescription,
                details: nsError.code
              )
            )
            return
          }
        }

        // Check for XPC/helper communication errors (also indicates missing capability)
        if nsError.localizedDescription.contains("nehelper") || 
           nsError.localizedDescription.contains("Connection invalid") ||
           nsError.localizedDescription.contains("internal error") {
          result([
            "success": false,
            "status": "capability_not_available",
            "message": "Wi-Fi configuration requires a paid Apple Developer account. Please connect manually via Settings > Wi-Fi."
          ])
          return
        }

        result(
          FlutterError(
            code: "IOS_WIFI_ERROR",
            message: nsError.localizedDescription,
            details: nil
          )
        )
      } else {
        result(["success": true, "status": "connected"])
      }
    }
  }
}
