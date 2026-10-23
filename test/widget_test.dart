import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roomplan_device_test/main.dart';
import 'package:roomplan_device_test/room_plan_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> status;
  late List<String> calls;
  late Future<Object?> Function() start;

  Map<String, dynamic> summary() => {
    'scanId': 'test-scan',
    'completedAt': '2026-10-22T09:00:00.000Z',
    'counts': {'walls': 4, 'doors': 1, 'windows': 2, 'objects': 3},
  };

  setUp(() {
    status = {
      'supported': true,
      'supportMessage': 'RoomPlan is supported on this device.',
      'cameraPermission': 'not_determined',
      'buildLabel': '0.1.1 (2)',
      'hasDiagnostics': false,
    };
    calls = [];
    start = () async {
      status['latestScan'] = summary();
      status['hasDiagnostics'] = true;
      status['latestAttemptState'] = 'completed';
      return {'status': 'completed', 'scan': summary()};
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RoomPlanService.channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'getStatus':
              return status;
            case 'startScan':
              return start();
            case 'retryLatestExport':
              final result = await start();
              status['canRetryExport'] = false;
              return result;
            case 'shareLatestResult':
            case 'shareDiagnostics':
              return null;
            case 'deleteAllScans':
              status.remove('latestScan');
              status['hasDiagnostics'] = false;
              return null;
            default:
              throw MissingPluginException();
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RoomPlanService.channel, null);
  });

  Future<void> open(WidgetTester tester, {bool authorise = true}) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RoomPlanTestApp(service: RoomPlanService(isIOS: true)),
    );
    await tester.pumpAndSettle();
    if (authorise) {
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('recording needs explicit space authorisation each launch', (
    tester,
  ) async {
    await open(tester, authorise: false);
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((widget) => widget is FilledButton),
          )
          .onPressed,
      isNull,
    );
    expect(calls, ['getStatus']);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((widget) => widget is FilledButton),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'failed export can be retried from saved files without starting the camera',
    (tester) async {
      status['canRetryExport'] = true;
      await open(tester, authorise: false);
      await tester.tap(find.text('Retry saving last scan'));
      await tester.pumpAndSettle();
      expect(calls, contains('retryLatestExport'));
      expect(calls, isNot(contains('startScan')));
      expect(find.text('Latest saved scan'), findsOneWidget);
      expect(find.text('Retry saving last scan'), findsNothing);
    },
  );

  testWidgets(
    'retry export failure remains visible and keeps saved data retryable',
    (tester) async {
      status['canRetryExport'] = true;
      start = () async => throw PlatformException(
        code: 'file_write_failed',
        message: 'Missing depth/frame-000075.f32',
      );
      await open(tester);
      await tester.tap(find.text('Retry saving last scan'));
      await tester.pumpAndSettle();
      expect(find.text('Missing depth/frame-000075.f32'), findsOneWidget);
      expect(find.text('Retry saving last scan'), findsOneWidget);
      expect(calls, isNot(contains('startScan')));
    },
  );

  testWidgets('new package summary shows roles after restart and shares ZIP', (
    tester,
  ) async {
    status['latestScan'] = {
      ...summary(),
      'pipelineReady': true,
      'capture': {'train_frames': 40, 'validation_frames': 12},
    };
    await open(tester);
    expect(
      find.textContaining('40 training frames, 12 check frames'),
      findsOneWidget,
    );
    await tester.tap(find.text('Share scan files'));
    await tester.pumpAndSettle();
    expect(calls, contains('shareLatestResult'));
  });

  testWidgets(
    'continuous scan restores coverage warning without test controls',
    (tester) async {
      status['latestScan'] = {
        ...summary(),
        'pipelineReady': true,
        'capture': {
          'capture_mode': 'continuous_guided',
          'capture_frames': 85,
          'guidance': {'coverage_passed': false},
        },
      };
      await open(tester);
      expect(find.textContaining('85 usable views saved.'), findsOneWidget);
      expect(
        find.textContaining('Coverage warning: more views'),
        findsOneWidget,
      );
      expect(find.textContaining('record a check pass'), findsNothing);
      await tester.tap(find.text('Share scan files'));
      await tester.pumpAndSettle();
      expect(calls, contains('shareLatestResult'));
    },
  );

  testWidgets(
    'continuous coverage pass still describes reconstruction as unverified',
    (tester) async {
      status['latestScan'] = {
        ...summary(),
        'pipelineReady': true,
        'capture': {
          'capture_mode': 'continuous_guided',
          'capture_frames': 100,
          'guidance': {'coverage_passed': true},
        },
      };
      await open(tester);
      expect(
        find.textContaining('Detected walls and floor have overlapping views.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Reconstruction quality still needs verification.'),
        findsOneWidget,
      );
      expect(find.textContaining('Coverage warning:'), findsNothing);
    },
  );

  testWidgets('capture condition warning survives a passing surface estimate', (
    tester,
  ) async {
    status['latestScan'] = {
      ...summary(),
      'pipelineReady': true,
      'capture': {
        'capture_mode': 'continuous_guided',
        'capture_frames': 100,
        'guidance': {'coverage_passed': true},
        'image_quality_warning_at_finish': 'Increase the room lighting.',
      },
    };
    await open(tester);
    expect(
      find.textContaining('Capture warning: Increase the room lighting.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Reconstruction quality still needs verification.'),
      findsOneWidget,
    );
  });

  testWidgets('local deletion requires confirmation and clears restored scan', (
    tester,
  ) async {
    status['latestScan'] = summary();
    status['hasDiagnostics'] = true;
    await open(tester);
    await tester.tap(find.text('Delete all local scans'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep scans'));
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('deleteAllScans')));
    await tester.tap(find.text('Delete all local scans'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete scans'));
    await tester.pumpAndSettle();
    expect(calls, contains('deleteAllScans'));
    expect(find.text('Latest saved scan'), findsNothing);
  });

  testWidgets(
    'ready device offers scan and disables sharing before an attempt',
    (tester) async {
      await open(tester);
      expect(find.text('Start scan'), findsOneWidget);
      expect(find.text('App version: 0.1.1 (2)'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byWidgetPredicate((widget) => widget is FilledButton),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.ancestor(
                of: find.text('Share scan files'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is OutlinedButton,
                ),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.ancestor(
                of: find.text('Share diagnostics'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is OutlinedButton,
                ),
              ),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('unsupported device disables capture with an explanation', (
    tester,
  ) async {
    status['supported'] = false;
    status['supportMessage'] = 'A real LiDAR iPhone is required.';
    await open(tester);
    expect(find.text('A real LiDAR iPhone is required.'), findsWidgets);
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((widget) => widget is FilledButton),
          )
          .onPressed,
      isNull,
    );
    expect(calls, ['getStatus']);
  });

  testWidgets('completion displays saved counts and shares both export types', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Start scan'));
    await tester.pumpAndSettle();
    expect(find.text('Walls: 4  •  Doors: 1'), findsOneWidget);
    expect(find.text('Windows: 2  •  Objects: 3'), findsOneWidget);
    await tester.tap(find.text('Share scan files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share diagnostics'));
    await tester.pumpAndSettle();
    expect(
      calls,
      containsAllInOrder([
        'startScan',
        'getStatus',
        'shareLatestResult',
        'shareDiagnostics',
      ]),
    );
  });

  testWidgets(
    'permission denial stays actionable and enables diagnostic sharing',
    (tester) async {
      start = () async {
        status['cameraPermission'] = 'denied';
        status['hasDiagnostics'] = true;
        throw PlatformException(
          code: 'permission_denied',
          message: 'Enable Camera in Settings, then retry.',
        );
      };
      await open(tester);
      await tester.tap(find.text('Start scan'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enable Camera in Settings, then retry.'),
        findsOneWidget,
      );
      expect(find.text('Camera permission: denied'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byWidgetPredicate((widget) => widget is FilledButton),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.ancestor(
                of: find.text('Share diagnostics'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is OutlinedButton,
                ),
              ),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'cancel preserves the previous result and does not claim completion',
    (tester) async {
      status['latestScan'] = summary();
      start = () async {
        status['hasDiagnostics'] = true;
        return {'status': 'cancelled'};
      };
      await open(tester);
      await tester.tap(find.text('Start scan'));
      await tester.pumpAndSettle();
      expect(
        find.text('Scan cancelled. Diagnostic logs are available.'),
        findsOneWidget,
      );
      expect(find.text('Walls: 4  •  Doors: 1'), findsOneWidget);
    },
  );

  testWidgets('native file failure is shown without a saved scan', (
    tester,
  ) async {
    start = () async => throw PlatformException(
      code: 'file_write_failed',
      message: 'Not enough storage.',
    );
    await open(tester);
    await tester.tap(find.text('Start scan'));
    await tester.pumpAndSettle();
    expect(find.text('Not enough storage.'), findsOneWidget);
    expect(find.text('Latest saved scan'), findsNothing);
  });

  testWidgets('existing native result is restored when the screen opens', (
    tester,
  ) async {
    status['latestScan'] = summary();
    status['hasDiagnostics'] = true;
    await open(tester);
    expect(find.text('Walls: 4  •  Doors: 1'), findsOneWidget);
    expect(calls, ['getStatus']);
  });

  testWidgets('missing native bridge gives rebuild instructions', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          RoomPlanService.channel,
          (_) async => throw MissingPluginException(),
        );
    await open(tester);
    expect(
      find.text(
        'The native scanner is missing. Rebuild the iOS app in Codemagic.',
      ),
      findsOneWidget,
    );
  });

  test('non-iOS status does not invoke a native channel', () async {
    final result = await RoomPlanService(isIOS: false).getStatus();
    expect(result.supported, isFalse);
    expect(calls, isEmpty);
  });

  test('unknown native result is rejected', () async {
    start = () async => {'status': 'unknown'};
    expect(RoomPlanService(isIOS: true).startScan(), throwsFormatException);
  });
}
