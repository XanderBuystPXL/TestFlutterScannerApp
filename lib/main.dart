import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'room_plan_service.dart';

void main() => runApp(const RoomPlanTestApp());

class RoomPlanTestApp extends StatelessWidget {
  const RoomPlanTestApp({super.key, this.service});

  final RoomPlanService? service;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'RoomPlan device test',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF004AAD)),
      scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      useMaterial3: true,
    ),
    home: ScanTestPage(service: service ?? RoomPlanService()),
  );
}

class ScanTestPage extends StatefulWidget {
  const ScanTestPage({super.key, required this.service});

  final RoomPlanService service;

  @override
  State<ScanTestPage> createState() => _ScanTestPageState();
}

class _ScanTestPageState extends State<ScanTestPage>
    with WidgetsBindingObserver {
  RoomPlanStatus? _status;
  bool _busy = true;
  bool _authorised = false;
  String _message = 'Checking this device…';
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) {
      _loadStatus();
    }
  }

  String _errorMessage(Object error) {
    if (error is PlatformException) {
      return error.message ?? 'Scanner error: ${error.code}';
    }
    if (error is MissingPluginException) {
      return 'The native scanner is missing. Rebuild the iOS app in Codemagic.';
    }
    return 'Could not communicate with the scanner. $error';
  }

  Future<void> _loadStatus() async {
    try {
      final status = await widget.service.getStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _message = status.latestScan != null
            ? 'Your latest completed scan is saved on this iPhone.'
            : status.supported
            ? 'Ready. Capture the room, record a check pass, then Finish.'
            : status.supportMessage;
        _error = null;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _errorMessage(error);
        _busy = false;
      });
    }
  }

  Future<void> _scan() async {
    if (!_authorised) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = 'Scanning or processing. Use Finish or Cancel in the scanner.';
    });
    String message;
    String? errorMessage;
    try {
      final completed = await widget.service.startScan();
      message = completed
          ? 'Scan saved. Share the files to inspect them on Windows.'
          : 'Scan cancelled. Diagnostic logs are available.';
    } catch (error) {
      message =
          'The scan was not saved. Share diagnostics for troubleshooting.';
      errorMessage = _errorMessage(error);
    }
    RoomPlanStatus? updated;
    try {
      updated = await widget.service.getStatus();
    } catch (error) {
      errorMessage ??= _errorMessage(error);
    }
    if (!mounted) return;
    setState(() {
      if (updated != null) _status = updated;
      _message = message;
      _error = errorMessage;
      _busy = false;
    });
  }

  Future<void> _share({required bool diagnosticsOnly}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (diagnosticsOnly) {
        await widget.service.shareDiagnostics();
      } else {
        await widget.service.shareLatestResult();
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all local scans?'),
        content: const Text(
          'This removes completed and unfinished captures, photos, depth and logs from this app. Copies already shared must be deleted separately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep scans'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete scans'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.service.deleteAllScans();
      await _loadStatus();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _errorMessage(error);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final scan = status?.latestScan;
    return Scaffold(
      appBar: AppBar(
        title: const Text('RoomPlan device test'),
        actions: [
          IconButton(
            tooltip: 'Open source licences',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'RoomPlan device test',
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.view_in_ar,
                    size: 52,
                    color: Color(0xFF004AAD),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Capture a room for reconstruction.',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Walk slowly around the room with overlapping views of walls, floor and furniture. Then record a separate check pass. Avoid people, screens and private documents.',
                  ),
                  const SizedBox(height: 24),
                  if (_busy) const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(_message)),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (status?.storageWarning != null) ...[
                    const SizedBox(height: 12),
                    Text(status!.storageWarning!),
                  ],
                  const SizedBox(height: 20),
                  if (status != null) ...[
                    Text(status.supportMessage),
                    Text('Camera permission: ${status.cameraPermission}'),
                    if (status.buildLabel != null)
                      Text('App version: ${status.buildLabel}'),
                    if (status.latestAttemptState != null)
                      Text('Latest attempt: ${status.latestAttemptState}'),
                  ],
                  const SizedBox(height: 24),
                  CheckboxListTile(
                    value: _authorised,
                    onChanged: _busy
                        ? null
                        : (value) =>
                              setState(() => _authorised = value ?? false),
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'I am authorised to record this space and its contents.',
                    ),
                    subtitle: const Text(
                      'Saves interior photos, LiDAR depth and room geometry on this device. Nothing uploads automatically. Sharing sends the full unredacted capture to your chosen destination.',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed:
                        !_busy && _authorised && status?.supported == true
                        ? _scan
                        : null,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Start scan'),
                  ),
                  OutlinedButton.icon(
                    onPressed: !_busy && scan != null
                        ? () => _share(diagnosticsOnly: false)
                        : null,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share scan files'),
                  ),
                  OutlinedButton.icon(
                    onPressed: !_busy && status?.hasDiagnostics == true
                        ? () => _share(diagnosticsOnly: true)
                        : null,
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Share diagnostics'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _loadStatus,
                    child: const Text('Refresh device status'),
                  ),
                  TextButton(
                    onPressed: !_busy && status?.hasDiagnostics == true
                        ? _delete
                        : null,
                    child: const Text('Delete all local scans'),
                  ),
                  if (scan != null) ...[
                    const Divider(height: 36),
                    Text(
                      'Latest saved scan',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Walls: ${scan.counts['walls'] ?? 0}  •  Doors: ${scan.counts['doors'] ?? 0}',
                    ),
                    Text(
                      'Windows: ${scan.counts['windows'] ?? 0}  •  Objects: ${scan.counts['objects'] ?? 0}',
                    ),
                    const SizedBox(height: 8),
                    Text('Saved ${scan.completedAt.toLocal()}'),
                    SelectableText('Scan ID: ${scan.scanId}'),
                    const SizedBox(height: 8),
                    Text(
                      scan.pipelineReady
                          ? 'Capture ZIP: ${scan.capture['train_frames']} training frames, ${scan.capture['validation_frames']} check frames. Reconstruction quality still needs verification.'
                          : 'Older geometry-only scan. Record a new scan to capture photos and depth for reconstruction.',
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Text(
                    'Keep the app open while scanning and saving. Share scan files exports one ZIP with photos, camera calibration, depth, room geometry and diagnostics. Reconstruction runs separately. Delete local captures when they are no longer needed.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
