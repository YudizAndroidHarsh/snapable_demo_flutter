import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wifi_iot/wifi_iot.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GIF Uploader',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const GifUploadPage(),
    );
  }
}

/// Upload state enum to track the current status of the upload operation
enum UploadState {
  idle,
  uploading,
  success,
  error,
}

/// Main page widget for uploading GIF files to ESP32
class GifUploadPage extends StatefulWidget {
  const GifUploadPage({super.key});

  @override
  State<GifUploadPage> createState() => _GifUploadPageState();
}

class _GifUploadPageState extends State<GifUploadPage>
    with WidgetsBindingObserver {
  UploadState _uploadState = UploadState.idle;
  String? _errorMessage;

  /// ESP32 Wi-Fi configuration
  static const String _uploadUrl = 'http://192.168.4.1/upload';
  static const String _wifiSSID = 'ESP32-GIF-Display';
  static const String _defaultWifiPassword = '12345678';

  late final TextEditingController _ssidController;
  late final TextEditingController _passwordController;
  bool _isConnectingToWifi = false;
  String _wifiStatusMessage = 'Not connected';
  bool _waitingForManualConnection = false;
  String? _pendingSsid;
  String? _pendingPassword;

  static const MethodChannel _wifiChannel = MethodChannel('com.snapable.wifi');

  void _log(String message) {
    debugPrint('[GifUploadPage] $message');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ssidController = TextEditingController(text: _wifiSSID);
    _passwordController = TextEditingController(text: _defaultWifiPassword);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForManualConnection) {
      _log('App resumed - verifying ESP32 connectivity after manual action');
      _checkManualConnectionStatus();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // When app goes to background / becomes inactive, disconnect from ESP Wi-Fi
      _log('App moved to background/inactive - disconnecting from ESP32 Wi-Fi');
      _disconnectFromEspWifi();
    }
  }

  /// Disconnects from the ESP32 Wi-Fi when the app goes to background
  Future<void> _disconnectFromEspWifi() async {
    _log('Attempting to disconnect from ESP32 Wi-Fi...');
    try {
      if (Platform.isAndroid) {
        // Stop forcing traffic over Wi-Fi and disconnect from current network
        try {
          WiFiForIoTPlugin.forceWifiUsage(false);
        } catch (e) {
          _log('Warning: forceWifiUsage(false) failed: $e');
        }
        try {
          await WiFiForIoTPlugin.disconnect();
          _log('Wi-Fi disconnect() called on Android');
        } catch (e) {
          _log('Warning: Wi-Fi disconnect() failed: $e');
        }
      } else if (Platform.isIOS) {
        // Ask iOS to remove the hotspot configuration for the ESP32 SSID
        final ssid = _ssidController.text.trim();
        if (ssid.isNotEmpty) {
          try {
            await _wifiChannel.invokeMethod(
              'clearWifiConfiguration',
              {'ssid': ssid},
            );
            _log('Requested iOS to clear Wi-Fi configuration for SSID=$ssid');
          } on PlatformException catch (e) {
            _log('iOS clearWifiConfiguration failed: $e');
          }
        }
      }
    } catch (e, stack) {
      _log('Error while disconnecting Wi-Fi: $e\n$stack');
    } finally {
      if (!mounted) return;
      setState(() {
        _wifiStatusMessage = 'Not connected';
        _waitingForManualConnection = false;
      });
    }
  }

  /// Connects the device to the ESP32 SoftAP network
  Future<void> _connectToEspWifi() async {
    final ssid = _ssidController.text.trim();
    final password = _passwordController.text;

    if (ssid.isEmpty) {
      setState(() {
        _wifiStatusMessage = 'Please enter the ESP32 SSID.';
      });
      return;
    }

    setState(() {
      _isConnectingToWifi = true;
      _waitingForManualConnection = false;
      _wifiStatusMessage = 'Connecting to $ssid…';
      _pendingSsid = ssid;
      _pendingPassword = password.isEmpty ? null : password;
    });

    _log(
        'Attempting Wi-Fi connect -> ssid=$ssid, passwordEmpty=${password.isEmpty}');

    try {
      if (Platform.isIOS) {
        await _connectToEspWifiIos(ssid, password);
      } else {
        await _connectToEspWifiAndroid(ssid, password);
      }
    } finally {
      if (!mounted) return;
      setState(() {
        _isConnectingToWifi = false;
      });
    }
  }

  Future<void> _connectToEspWifiAndroid(String ssid, String password) async {
    try {
      try {
        if (!(await WiFiForIoTPlugin.isEnabled())) {
          await WiFiForIoTPlugin.setEnabled(true);
          _log('Wi-Fi adapter enabled via plugin');
        }
      } catch (e) {
        _log('Warning: Could not check/enable Wi-Fi: $e');
      }

      bool connected = false;
      try {
        final result = await WiFiForIoTPlugin.connect(
          ssid,
          password: password.isEmpty ? null : password,
          joinOnce: true,
          withInternet: false,
          security:
              password.isEmpty ? NetworkSecurity.NONE : NetworkSecurity.WPA,
          isHidden: false,
        );
        connected = result == true;
        _log('connect() completed with result=$connected');
      } catch (e) {
        _log('Wi-Fi connect() threw exception: $e');
        connected = false;
      }

      try {
        WiFiForIoTPlugin.forceWifiUsage(true);
      } catch (e) {
        _log('Warning: forceWifiUsage failed: $e');
      }

      if (!mounted) return;

      if (connected) {
        setState(() {
          _wifiStatusMessage = 'Connected to $ssid. You can upload a GIF now.';
        });
      } else {
        setState(() {
          _wifiStatusMessage =
              'Unable to connect to $ssid. Double-check the password and try again.';
        });
      }
    } catch (e, stack) {
      _log('Wi-Fi connection failed: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _wifiStatusMessage = 'Connection failed: $e';
      });
    }
  }

  Future<void> _connectToEspWifiIos(String ssid, String password) async {
    try {
      final response = await _wifiChannel.invokeMethod<Map<dynamic, dynamic>>(
        'connectToWifi',
        {
          'ssid': ssid,
          'password': password.isEmpty ? null : password,
          'joinOnce': true,
        },
      );

      final success = response?['success'] == true;
      final status = (response?['status'] as String?) ?? '';
      _log('iOS Wi-Fi channel result: success=$success, status=$status');

      if (success || status == 'already_connected') {
        // Give iOS time to establish network connectivity after WiFi connection
        // iOS needs time to: associate, get IP via DHCP, establish routes
        _log('Waiting for network to be fully established...');
        await Future.delayed(const Duration(seconds: 2));

        // Retry connectivity check with exponential backoff
        bool connected = false;
        for (int attempt = 1; attempt <= 3; attempt++) {
          _log('Connectivity check attempt $attempt/3...');
          connected = await _ensureConnectedToEsp();
          if (connected) {
            break;
          }
          if (attempt < 3) {
            // Wait longer between retries: 2s, 3s
            await Future.delayed(Duration(seconds: 1 + attempt));
          }
        }

        if (!mounted) return;
        if (connected) {
          setState(() {
            _wifiStatusMessage =
                'Connected to $ssid. You can upload a GIF now.';
            _waitingForManualConnection = false;
          });
          return;
        } else {
          // Even if connectivity check fails, WiFi might still be connecting
          // Show a message that connection is in progress
          setState(() {
            _wifiStatusMessage =
                'WiFi connected to $ssid, but ESP32 not reachable yet. Please wait a moment and try again, or verify ESP32 is running.';
            _waitingForManualConnection = false;
          });
        }
      }

      if (status == 'user_denied') {
        _promptManualConnection(
          ssid,
          password,
          reason:
              'iOS blocked the automatic connection request. Please connect manually.',
        );
        return;
      }

      if (status == 'capability_not_available') {
        final message = response?['message'] as String?;
        _promptManualConnection(
          ssid,
          password,
          reason: message ??
              'Automatic WiFi connection requires a paid Apple Developer account. Please connect manually via Settings > Wi-Fi.',
        );
        return;
      }

      _promptManualConnection(
        ssid,
        password,
        reason:
            'Automatic connection did not succeed. Please connect manually.',
      );
    } on PlatformException catch (e) {
      _log('iOS Wi-Fi connection failed: $e');
      if (!mounted) return;
      _promptManualConnection(
        ssid,
        password,
        reason: e.message ?? 'iOS returned an error.',
      );
    } catch (e, stack) {
      _log('iOS Wi-Fi connection threw: $e\n$stack');
      if (!mounted) return;
      _promptManualConnection(
        ssid,
        password,
        reason: 'Unexpected error: $e',
      );
    }
  }

  void _promptManualConnection(
    String ssid,
    String password, {
    String? reason,
  }) {
    final displayPassword = password.isEmpty ? 'none' : password;
    setState(() {
      _waitingForManualConnection = true;
      _pendingSsid = ssid;
      _pendingPassword = password.isEmpty ? null : password;
      _wifiStatusMessage = [
        'Manual Wi-Fi connection to "$ssid" is required.',
        if (reason != null) reason,
        'Password: $displayPassword',
        'Open Settings > Wi-Fi and connect, then return to the app.',
      ].join('\n');
    });
  }

  Future<void> _checkManualConnectionStatus() async {
    final isConnected = await _ensureConnectedToEsp();
    if (!mounted) return;
    if (isConnected) {
      setState(() {
        _waitingForManualConnection = false;
        _wifiStatusMessage =
            'Connected to ${_pendingSsid ?? _ssidController.text.trim()}. You can upload a GIF now.';
      });
    } else {
      setState(() {
        _wifiStatusMessage =
            'Still not connected to ${_pendingSsid ?? _ssidController.text.trim()}. Please verify in Settings.';
      });
    }
  }

  Future<void> _openWifiSettings() async {
    final ssid = _pendingSsid ?? _ssidController.text.trim();
    final password = _pendingPassword ?? _passwordController.text;
    _promptManualConnection(
      ssid,
      password,
      reason: 'Opening Wi-Fi settings…',
    );

    // Try to open Wi-Fi / Settings screen using url_launcher on both platforms
    final List<Uri> candidateUris = [];

    if (Platform.isAndroid) {
      // Some Android devices may support a generic Wi-Fi URI.
      // Fallback is app settings screen using `app-settings:`.
      candidateUris.addAll([
        Uri.parse('wifi:'), // may open Wi-Fi settings on some devices
        Uri.parse('app-settings:'), // app-specific settings as a fallback
      ]);
    } else if (Platform.isIOS) {
      candidateUris.addAll([
        Uri.parse('App-Prefs:WIFI'),
        Uri.parse('App-Prefs:root=WIFI'),
        Uri.parse('App-Prefs:root=General&path=ManagedConfigurationList'),
        Uri.parse('app-settings:'), // iOS general settings as a fallback
      ]);
    }

    for (final uri in candidateUris) {
      try {
        if (await canLaunchUrl(uri)) {
          final launched =
              await launchUrl(uri, mode: LaunchMode.externalApplication);
          if (launched) return;
        }
      } catch (e) {
        _log('Failed to launch settings URI $uri: $e');
      }
    }

    setState(() {
      _wifiStatusMessage =
          'Could not open Wi-Fi settings automatically. Please open Settings > Wi-Fi manually.';
    });
  }

  /// Checks connectivity to ESP32 by attempting a lightweight HTTP request
  /// This is more reliable than SSID check on Android (which returns "<unknown ssid>" for networks without internet)
  Future<bool> _ensureConnectedToEsp() async {
    try {
      _log('Checking ESP32 connectivity...');

      // First, try a TCP socket connection to verify basic network reachability
      try {
        final socket = await Socket.connect('192.168.4.1', 80,
            timeout: const Duration(seconds: 2));
        socket.destroy();
        _log('✓ TCP connection to ESP32 successful');
      } catch (e) {
        _log('✗ TCP connection failed: $e');
        // TCP failure is a clear sign we're not connected
        return false;
      }

      // Then try a lightweight HTTP request
      final uri = Uri.parse(_uploadUrl);
      final client = http.Client();
      try {
        final response =
            await client.head(uri).timeout(const Duration(seconds: 3));
        _log('ESP32 HTTP connectivity check: ${response.statusCode}');
        // Any response (even 404/405) means we're connected to the ESP32 network
        return true;
      } on TimeoutException {
        _log('ESP32 HTTP check timed out - but TCP worked, so allowing upload');
        // TCP worked but HTTP timed out - might be slow, but allow upload
        return true;
      } on SocketException catch (e) {
        _log('ESP32 HTTP check failed: $e');
        // Even though TCP worked, HTTP failed - but allow upload to try
        return true;
      } finally {
        client.close();
      }
    } catch (e) {
      _log('Connectivity check error: $e. Allowing upload to proceed.');
      // If check fails for any other reason, allow upload anyway - let the actual upload request handle the error
      return true;
    }
  }

  /// Picks a GIF file and uploads it to the ESP32
  Future<void> _pickAndUploadGif() async {
    try {
      final isConnected = await _ensureConnectedToEsp();
      if (!isConnected) {
        setState(() {
          _uploadState = UploadState.error;
          _errorMessage =
              'Device not connected to ${_ssidController.text.trim()}. Please connect first.';
        });
        return;
      }

      // Open file picker limited to GIF files
      // On iOS, use FileType.image to access Photos library (not Files app)
      // On Android, use FileType.custom with allowedExtensions
      FilePickerResult? result;
      try {
        if (Platform.isIOS) {
          // iOS: Use FileType.image to open Photos library instead of Files app
          result = await FilePicker.platform.pickFiles(
            type: FileType.image,
            allowMultiple: false,
          );
        } else {
          // Android: Use FileType.custom with GIF filter
          result = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['gif'],
            allowMultiple: false,
          );
        }
      } catch (e) {
        _log('File picker error: $e');
        setState(() {
          _uploadState = UploadState.error;
          _errorMessage = 'Failed to open file picker. '
              '${Platform.isIOS ? "Please ensure photo library permissions are granted in Settings > Privacy > Photos." : ""}';
        });
        return;
      }

      // Handle user cancellation
      if (result == null ||
          result.files.isEmpty ||
          result.files.single.path == null) {
        _log('File picking cancelled or no file selected');
        return; // User cancelled file picking
      }

      final filePath = result.files.single.path!;
      final file = File(filePath);

      // Verify file exists
      if (!await file.exists()) {
        setState(() {
          _uploadState = UploadState.error;
          _errorMessage = 'Selected file does not exist';
        });
        return;
      }

      // Validate file extension (extra check, especially important on iOS)
      final fileName = filePath.toLowerCase();
      if (!fileName.endsWith('.gif')) {
        setState(() {
          _uploadState = UploadState.error;
          _errorMessage =
              'Please select a GIF file from your ${Platform.isIOS ? "Photos" : "files"}. '
              'Selected file: ${filePath.split('/').last}';
        });
        return;
      }

      final fileLength = await file.length();
      _log('Picked file: path=$filePath, size=${fileLength} bytes');

      // Test basic network connectivity to ESP32 IP
      _log('Testing network connectivity to ESP32 (192.168.4.1)...');
      try {
        final socket = await Socket.connect('192.168.4.1', 80,
            timeout: const Duration(seconds: 3));
        socket.destroy();
        _log('✓ TCP connection to ESP32 successful');
      } catch (e) {
        _log('✗ TCP connection to ESP32 failed: $e');
        _log(
            'This suggests the device may not be on the ESP32 network or ESP32 is not running');
        setState(() {
          _uploadState = UploadState.error;
          _errorMessage = 'Cannot reach ESP32 at 192.168.4.1. Please verify:\n'
              '1. Device is connected to ESP32_VIDEO_AP Wi-Fi\n'
              '2. ESP32 server is running\n'
              '3. ESP32 IP is 192.168.4.1';
        });
        return;
      }

      // Update state to uploading
      setState(() {
        _uploadState = UploadState.uploading;
        _errorMessage = null;
      });
      _log('Starting upload to $_uploadUrl');
      _log('File size: ${(fileLength / 1024).toStringAsFixed(2)} KB');

      // Build multipart request with the GIF file
      // Using MultipartFile.fromPath streams the file instead of loading it fully into memory
      _log('Building multipart request...');
      final uri = Uri.parse(_uploadUrl);
      _log('Target URI: $uri');

      final request = http.MultipartRequest('POST', uri);

      // Read file as bytes to ensure it's accessible
      _log('Reading file into memory...');
      final fileBytes = await file.readAsBytes();
      _log('File read: ${fileBytes.length} bytes');

      final multipartFile = http.MultipartFile.fromBytes(
        'file', // Field name expected by ESP32
        fileBytes,
        filename: file.path.split('/').last,
        contentType: MediaType('image', 'gif'),
      );
      request.files.add(multipartFile);
      _log(
          'Multipart request built. Field name: "file", filename: ${file.path.split('/').last}, content-type: image/gif');

      // Calculate timeout based on file size (minimum 30s, +1s per 10KB)
      final timeoutSeconds = (30 + (fileLength / 10240)).ceil().clamp(30, 120);
      _log('Upload timeout set to ${timeoutSeconds}s');

      // Use explicit HTTP client for better control
      final client = http.Client();
      http.StreamedResponse streamedResponse;
      try {
        _log('Sending request to ESP32 at $uri...');
        _log('Request method: POST, Content-Type: multipart/form-data');
        final sendStartTime = DateTime.now();

        // Send the request with explicit timeout
        streamedResponse = await client
            .send(request)
            .timeout(Duration(seconds: timeoutSeconds));

        final sendDuration = DateTime.now().difference(sendStartTime);
        _log(
            'Request sent successfully in ${sendDuration.inMilliseconds}ms. Status code: ${streamedResponse.statusCode}');
        _log('Response headers: ${streamedResponse.headers}');
      } on TimeoutException catch (e) {
        _log('Upload timed out after ${timeoutSeconds}s. Error: $e');
        client.close();
        setState(() {
          _uploadState = UploadState.error;
          _errorMessage =
              'Upload timed out after ${timeoutSeconds}s. The file might be too large, or the ESP32 may be slow. Try a smaller file or check ESP32 connection.';
        });
        return;
      } on SocketException catch (e) {
        _log('Network error during upload: $e');
        client.close();
        setState(() {
          _uploadState = UploadState.error;
          _errorMessage =
              'Network error: Unable to reach ESP32. Check Wi-Fi connection.';
        });
        return;
      } catch (e, stack) {
        _log('Unexpected error during send: $e\n$stack');
        client.close();
        setState(() {
          _uploadState = UploadState.error;
          _errorMessage = 'Error sending request: ${e.toString()}';
        });
        return;
      }

      // Read the response
      _log('Reading response from ESP32...');
      final responseStartTime = DateTime.now();
      http.Response response;
      try {
        response = await http.Response.fromStream(streamedResponse)
            .timeout(Duration(seconds: 10));
        final responseDuration = DateTime.now().difference(responseStartTime);
        _log(
            'Response received in ${responseDuration.inMilliseconds}ms: status=${response.statusCode}, body length=${response.body.length}');
        if (response.body.isNotEmpty && response.body.length < 200) {
          _log('Response body: ${response.body}');
        }
      } catch (e) {
        _log('Error reading response: $e');
        client.close();
        setState(() {
          _uploadState = UploadState.error;
          _errorMessage = 'Error reading response from ESP32: ${e.toString()}';
        });
        return;
      } finally {
        client.close();
      }

      // Handle response
      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _uploadState = UploadState.success;
          _errorMessage = null;
        });
      } else {
        setState(() {
          _uploadState = UploadState.error;
          _errorMessage =
              'Server error: ${response.statusCode} - ${response.body}';
        });
      }
    } catch (e, stack) {
      // Handle any errors during the upload process
      _log('Upload failed with error: $e\n$stack');
      setState(() {
        _uploadState = UploadState.error;
        _errorMessage = 'Error: ${e.toString()}';
      });
    }
  }

  /// Renders the Wi-Fi connection instructions at the top
  Widget _renderInstructions() {
    final isIOS = Platform.isIOS;
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi, color: Colors.blue.shade700),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Connect to Wi-Fi: $_wifiSSID',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue.shade900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isIOS
                ? 'Default password: $_defaultWifiPassword.\n'
                    'Note: Automatic WiFi connection requires a paid Apple Developer account. '
                    'With a personal/free account, tap "Open Wi-Fi Settings" to connect manually. '
                    'The app will detect when you return and verify the connection.'
                : 'Default password: $_defaultWifiPassword. You can use the form below to connect directly from the app.',
            style: TextStyle(color: Colors.blueGrey.shade700),
          ),
        ],
      ),
    );
  }

  /// Renders the Wi-Fi connect form and action button
  Widget _renderWifiConnectCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Wi-Fi quick connect',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ssidController,
              decoration: const InputDecoration(
                labelText: 'SSID',
                hintText: 'ESP32 AP name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                hintText: 'Enter password (if required)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _isConnectingToWifi ? null : _connectToEspWifi,
                icon: _isConnectingToWifi
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: Text(
                  _isConnectingToWifi
                      ? 'Connecting…'
                      : 'Connect to ESP32 Wi-Fi',
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _openWifiSettings,
                icon: const Icon(Icons.settings),
                label: const Text('Open Wi-Fi Settings'),
              ),
            ),
            const SizedBox(height: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _wifiStatusMessage.startsWith('Connected')
                    ? Colors.green.shade50
                    : _waitingForManualConnection
                        ? Colors.orange.shade50
                        : Colors.blueGrey.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _wifiStatusMessage.startsWith('Connected')
                        ? Icons.check_circle
                        : _waitingForManualConnection
                            ? Icons.info
                            : Icons.wifi,
                    color: _wifiStatusMessage.startsWith('Connected')
                        ? Colors.green.shade700
                        : _waitingForManualConnection
                            ? Colors.orange.shade700
                            : Colors.blueGrey.shade700,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _wifiStatusMessage,
                      style: TextStyle(
                        color: _wifiStatusMessage.startsWith('Connected')
                            ? Colors.green.shade800
                            : Colors.blueGrey.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Renders the upload button
  Widget _renderUploadButton() {
    final isUploading = _uploadState == UploadState.uploading;

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: isUploading ? null : _pickAndUploadGif,
        icon: isUploading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.upload_file),
        label: const Text(
          'Pick & Upload GIF',
          style: TextStyle(fontSize: 18),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.deepPurple,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade300,
          disabledForegroundColor: Colors.grey.shade600,
        ),
      ),
    );
  }

  /// Renders the status message based on current upload state
  Widget _renderStatusMessage() {
    String message;
    Color messageColor;

    switch (_uploadState) {
      case UploadState.idle:
        message = 'No upload in progress';
        messageColor = Colors.grey;
        break;
      case UploadState.uploading:
        message = 'Uploading…';
        messageColor = Colors.blue;
        break;
      case UploadState.success:
        message = 'Upload complete';
        messageColor = Colors.green;
        break;
      case UploadState.error:
        message = 'Error: ${_errorMessage ?? 'Unknown error'}';
        messageColor = Colors.red;
        break;
    }

    return Text(
      message,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: messageColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('GIF Uploader'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _renderInstructions(),
              const SizedBox(height: 16),
              _renderWifiConnectCard(),
              const SizedBox(height: 24),
              _renderUploadButton(),
              const SizedBox(height: 16),
              _renderStatusMessage(),
            ],
          ),
        ),
      ),
    );
  }
}
