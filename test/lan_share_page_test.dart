import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/lan_shares.dart';
import 'package:asterlink/ui/lan_share_browser_page.dart';
import 'package:asterlink/ui/lan_share_edit_page.dart';
import 'package:asterlink/ui/lan_tab_page.dart';
import 'support.dart';

/// 组件侧共享接口的桩：返回固定的共享名、目录与流地址。
class _LanShareNative extends FakeNative {
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    switch (method) {
      case 'lanShareProbe':
        return {'ok': true, 'shares': ['media', 'photos']};
      case 'lanShareList':
        if (args.str('path').isEmpty) {
          return {
            'ok': true,
            'entries': [
              {'name': '电影', 'dir': true, 'size': 0, 'modified': 1700000000000},
              {
                'name': 'sample.mp4',
                'dir': false,
                'size': 1024000,
                'modified': 1700000000000,
              },
              {'name': 'readme.txt', 'dir': false, 'size': 12, 'modified': 0},
            ],
          };
        }
        return {
          'ok': true,
          'entries': [
            {
              'name': 'movie.mkv',
              'dir': false,
              'size': 999999,
              'modified': 1700000000000,
            },
          ],
        };
      case 'lanShareStreamStart':
        return {
          'ok': true,
          'id': args.str('id'),
          'url': 'http://127.0.0.1:51999/token/sample.mp4',
          'size': 1024000,
          'name': 'sample.mp4',
        };
    }
    return super.call(method, args);
  }
}

const _server = LanShareServer(
  id: 'srv-1',
  kind: LanShareKind.smb,
  name: '家庭NAS',
  host: '192.168.1.10',
  port: 445,
  share: 'media',
);

Future<AppServices> _services(
  WidgetTester tester,
  _LanShareNative native, {
  Map<String, Object?> seed = const {},
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final root = Directory.systemTemp.createTempSync('aster-lan-share-');
  addTearDown(() => root.deleteSync(recursive: true));
  final store = StateStore.memory(seed);
  return AppServices(
    store: store,
    dataDirectory: Directory('${root.path}/data'),
    cacheDirectory: Directory('${root.path}/cache'),
    files: FakeFiles(Directory('${root.path}/saved')),
    transport: native,
    platformFeatures: false,
    controlEnabled: false,
  );
}

Future<void> _render(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('空列表显示引导并打开添加表单', (tester) async {
    final services = await _services(tester, _LanShareNative());
    await _render(tester, LanTabPage(services));
    expect(find.text('局域网文件共享'), findsOneWidget);
    await tester.tap(find.byKey(const Key('lan-share-add')));
    await tester.pumpAndSettle();
    expect(find.byType(LanShareEditPage), findsOneWidget);
  });

  testWidgets('服务器卡片进入浏览页并可进入文件夹', (tester) async {
    final services = await _services(
      tester,
      _LanShareNative(),
      seed: {'lanShares': [_server.toJson()]},
    );
    await _render(tester, LanTabPage(services));
    expect(find.text('家庭NAS'), findsOneWidget);
    await tester.tap(find.byKey(const Key('lan-share-server-srv-1')));
    await tester.pumpAndSettle();
    expect(find.byType(LanShareBrowserPage), findsOneWidget);
    expect(find.text('电影'), findsOneWidget);
    expect(find.text('sample.mp4'), findsOneWidget);
    expect(find.text('readme.txt'), findsOneWidget);
    await tester.tap(find.byKey(const Key('lan-share-entry-电影')));
    await tester.pumpAndSettle();
    expect(find.text('movie.mkv'), findsOneWidget);
    expect(find.text('根目录'), findsOneWidget);
    await tester.tap(find.text('根目录'));
    await tester.pumpAndSettle();
    expect(find.text('sample.mp4'), findsOneWidget);
  });

  testWidgets('不支持在线打开的类型给出提示', (tester) async {
    final services = await _services(
      tester,
      _LanShareNative(),
      seed: {'lanShares': [_server.toJson()]},
    );
    await _render(tester, LanTabPage(services));
    await tester.tap(find.byKey(const Key('lan-share-server-srv-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('lan-share-entry-readme.txt')));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂不支持在线打开'), findsOneWidget);
  });

  testWidgets('添加表单可测试连接并保存服务器', (tester) async {
    final services = await _services(tester, _LanShareNative());
    await _render(tester, LanShareEditPage(services));
    await tester.enterText(find.byType(TextField).at(0), '192.168.1.10');
    await tester.tap(find.byKey(const Key('lan-share-test')));
    await tester.pumpAndSettle();
    expect(find.textContaining('连接成功'), findsOneWidget);
    await tester.tap(find.text('media'));
    await tester.ensureVisible(find.byKey(const Key('lan-share-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('lan-share-save')));
    await tester.pumpAndSettle();
    expect(services.lanShares.servers, hasLength(1));
    expect(services.lanShares.servers.single.host, '192.168.1.10');
    expect(services.lanShares.servers.single.share, 'media');
    expect(
      services.store.data['lanShares'],
      isA<List>().having((list) => list, 'persisted', hasLength(1)),
    );
  });
}
