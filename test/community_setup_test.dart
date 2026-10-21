import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/main.dart' as community;
import 'package:syncnote/core/community_config.dart';
import 'package:syncnote/features/settings/community_setup_screen.dart';

void main() {
  testWidgets('application bootstrap does not create Firebase before setup', (
    tester,
  ) async {
    final previousOverrides = HttpOverrides.current;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    FlutterSecureStorage.setMockInitialValues({});
    community.main();
    await tester.pumpAndSettle();
    expect(find.byType(CommunitySetupScreen), findsOneWidget);
    expect(Firebase.apps, isEmpty);
    expect(tester.takeException(), isNull);
  });

  Map<String, dynamic> config() => {
    'firebase': {
      'projectId': 'example-project',
      'apiKey': 'example-public-identifier',
      'appId': 'example-application',
      'messagingSenderId': '123456',
    },
    'google': {
      'serverClientId': 'example-server',
      'desktopClientId': 'example-desktop',
      'desktopClientSecret': 'example-desktop-value',
    },
  };

  test('empty or placeholder config cannot initialize a backend', () {
    expect(
      CommunityConfig.validate({}, platform: TargetPlatform.windows),
      isNotNull,
    );
    final values = config();
    (values['firebase'] as Map)['projectId'] = 'YOUR_PROJECT_ID';
    expect(
      CommunityConfig.validate(values, platform: TargetPlatform.android),
      isNotNull,
    );
  });

  test('platform login fields and safe optional WebDAV are validated', () {
    final values = config();
    expect(
      CommunityConfig.validate(values, platform: TargetPlatform.windows),
      isNull,
    );
    expect(
      CommunityConfig.validate(values, platform: TargetPlatform.android),
      isNull,
    );
    (values['google'] as Map).remove('desktopClientId');
    expect(
      CommunityConfig.validate(values, platform: TargetPlatform.windows),
      isNotNull,
    );
    expect(
      CommunityConfig.validate(values, platform: TargetPlatform.android),
      isNull,
    );
    values['webdav'] = {'url': 'http://example.com/dav/'};
    expect(
      CommunityConfig.validate(values, platform: TargetPlatform.android),
      isNotNull,
    );
    values['webdav'] = {'url': 'https://user:password@example.com/dav/'};
    expect(
      CommunityConfig.validate(values, platform: TargetPlatform.android),
      isNotNull,
    );
    values['webdav'] = {'url': 'https://example.com/dav/'};
    expect(
      CommunityConfig.validate(values, platform: TargetPlatform.android),
      isNull,
    );
  });

  testWidgets(
    'fresh installer displays setup without Firebase initialization',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CommunitySetupScreen()));
      await tester.pumpAndSettle();
      expect(find.text('连接你自己的服务'), findsOneWidget);
      expect(find.text('1. Firebase（必填）'), findsOneWidget);
      final firebaseKey = find.widgetWithText(TextField, 'Firebase API Key');
      expect(tester.widget<TextField>(firebaseKey).obscureText, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
