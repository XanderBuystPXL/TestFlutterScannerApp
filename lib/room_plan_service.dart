import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ScanSummary {
  const ScanSummary({
    required this.scanId,
    required this.completedAt,
    required this.counts,
    this.pipelineReady = false,
    this.capture = const {},
  });

  factory ScanSummary.fromMap(Map<String, dynamic> map) => ScanSummary(
    scanId: map['scanId'] as String,
    completedAt: DateTime.parse(map['completedAt'] as String),
    counts: Map<String, int>.from(map['counts'] as Map),
    pipelineReady: map['pipelineReady'] as bool? ?? false,
    capture: Map<String, dynamic>.from(map['capture'] as Map? ?? {}),
  );

  final String scanId;
  final DateTime completedAt;
  final Map<String, int> counts;
  final bool pipelineReady;
  final Map<String, dynamic> capture;
}

class RoomPlanStatus {
  const RoomPlanStatus({
    required this.supported,
    required this.supportMessage,
    required this.cameraPermission,
    this.latestScan,
    this.hasDiagnostics = false,
    this.latestAttemptState,
    this.storageWarning,
    this.buildLabel,
  });

  factory RoomPlanStatus.fromMap(Map<String, dynamic> map) => RoomPlanStatus(
    supported: map['supported'] as bool,
    supportMessage: map['supportMessage'] as String,
    cameraPermission: map['cameraPermission'] as String,
    latestScan: map['latestScan'] == null
        ? null
        : ScanSummary.fromMap(
            Map<String, dynamic>.from(map['latestScan'] as Map),
          ),
    hasDiagnostics: map['hasDiagnostics'] as bool? ?? false,
    latestAttemptState: map['latestAttemptState'] as String?,
    storageWarning: map['storageWarning'] as String?,
    buildLabel: map['buildLabel'] as String?,
  );

  final bool supported;
  final String supportMessage;
  final String cameraPermission;
  final ScanSummary? latestScan;
  final bool hasDiagnostics;
  final String? latestAttemptState;
  final String? storageWarning;
  final String? buildLabel;
}

class RoomPlanService {
  RoomPlanService({bool? isIOS})
    : _isIOS =
          isIOS ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  static const channel = MethodChannel(
    'be.aproxx.roomplan_device_test/scanner',
  );
  final bool _isIOS;

  Future<RoomPlanStatus> getStatus() async {
    if (!_isIOS) {
      return const RoomPlanStatus(
        supported: false,
        supportMessage:
            'Scanning needs a LiDAR iPhone running iOS 17 or later.',
        cameraPermission: 'unavailable',
      );
    }
    final map = await channel.invokeMapMethod<String, dynamic>('getStatus');
    if (map == null) {
      throw const FormatException('The scanner returned no device status.');
    }
    return RoomPlanStatus.fromMap(map);
  }

  Future<bool> startScan() async {
    final map = await channel.invokeMapMethod<String, dynamic>('startScan');
    switch (map?['status']) {
      case 'completed':
        return true;
      case 'cancelled':
        return false;
      default:
        throw const FormatException('The scanner returned an unknown result.');
    }
  }

  Future<void> shareLatestResult() =>
      channel.invokeMethod<void>('shareLatestResult');

  Future<void> shareDiagnostics() =>
      channel.invokeMethod<void>('shareDiagnostics');

  Future<void> deleteAllScans() => channel.invokeMethod<void>('deleteAllScans');
}
