import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/cloud_accounts_page.dart';
import 'package:asterlink/ui/cloud_favorites_page.dart';
import 'package:asterlink/ui/common.dart';
import 'package:asterlink/ui/native_password_login_page.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'package:asterlink/ui/recent_playback_page.dart';
import 'browser_test_support.dart';

class _SwitchConnector extends BrowserTestConnector {
  _SwitchConnector() : super(CloudPlatform.tianyi);
  String? failOwner;
  final pendingRoots = <String, Completer<List<CloudFile>>>{};
  final accountReads = <(String, String, String)>[];
  final shares = <(String, ParsedLink)>[];

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    shares.add((credential!.label, link));
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '分享文件',
      rootId: 'share-root',
      metadata: {'token': 'fixture-${credential.updatedAt}'},
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    final account = credential!;
    accountReads.add((account.label, session.familyId, parentId));
    if (account.label == failOwner) throw const AppException('测试账号暂时无法读取');
    if (parentId == session.rootId && pendingRoots[account.label] != null) {
      return pendingRoots[account.label]!.future;
    }
    return [
      ...await super.list(session, parentId, credential),
      CloudFile(
        id: 'owner-file',
        name: '${account.label}-${account.updatedAt}.mp4',
        parentId: parentId,
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platform = CloudPlatform.tianyi;

  Future<void> tap(
    WidgetTester tester,
    Finder finder, {
    bool settle = true,
  }) async {
    await tester.tap(finder);
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(tester.takeException(), isNull);
  }

  Future<void> scenario(
    WidgetTester tester,
    Future<void> Function(BrowserUiFixture fixture, _SwitchConnector connector)
    body,
  ) async {
    final fixture = await BrowserUiFixture.create();
    final connector = _SwitchConnector();
    fixture.services.cloud.connectors[platform] = connector;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    try {
      await body(fixture, connector);
    } finally {
      for (final pending in connector.pendingRoots.values) {
        if (!pending.isCompleted) pending.complete([]);
      }
      if (connector.pendingFolder case final pending?
          when !pending.isCompleted) {
        pending.complete([]);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.close();
    }
  }

  testWidgets(
    'Home favorites open their stored directory and stay separate from recent playback',
    (tester) => scenario(tester, (fixture, connector) async {
      final services = fixture.services;
      final session = services.cloud.bindSession(connector.personalSession());
      await services.favorites.toggle(
        session,
        const CloudFile(
          id: 'nested-video',
          name: '旧目录视频.mp4',
          parentId: 'photos',
        ),
        [('personal-root', '全部文件'), ('photos', '假期相册')],
      );
      final favorite = services.favorites.all.single;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 864);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(body: ParsePage(services)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(ValueKey('home-favorite-${favorite.id}')),
      );
      expect(find.byIcon(CupertinoIcons.star_fill), findsOneWidget);
      await tap(tester, find.byKey(ValueKey('home-favorite-${favorite.id}')));
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(connector.accountReads.last.$3, 'photos');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '旧目录视频.mp4',
      );
      // The first back leaves the restored folder; the second leaves the browser.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('parse-favorites')));
      await tap(tester, find.byKey(const Key('parse-favorites')));
      expect(find.byType(CloudFavoritesPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('parse-recent')));
      await tap(tester, find.byKey(const Key('parse-recent')));
      expect(find.byType(RecentPlaybackPage), findsOneWidget);
      expect(find.byType(CloudFavoritesPage), findsNothing);
    }),
  );

  testWidgets(
    'Cloud account management opens from the top right menu',
    (tester) => scenario(tester, (fixture, _) async {
      await tester.pumpWidget(AsterLinkApp(fixture.services, initialTab: 2));
      await tester.pumpAndSettle();
      expect(find.text('账号管理'), findsNothing);
      expect(find.text('网盘收藏'), findsNothing);
      await tap(tester, find.byTooltip('更多操作'));
      await tap(tester, find.text('账号管理'));
      expect(find.byType(CloudAccountsPage), findsOneWidget);
      final vault = fixture.services.vault;
      final previous = vault.activeAccountId(platform);
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('account-add-${platform.key}')),
        180,
        scrollable: find.descendant(
          of: find.byType(CloudAccountsPage),
          matching: find.byType(Scrollable),
        ),
      );
      await tap(tester, find.byKey(ValueKey('account-add-${platform.key}')));
      expect(find.byType(NativePasswordLoginPage), findsOneWidget);
      final owner = tester
          .widget<NativePasswordLoginPage>(find.byType(NativePasswordLoginPage))
          .accountId;
      expect(owner, isNotNull);
      expect(owner, isNot(previous));
      expect(vault.activeAccountId(platform), previous);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(CloudAccountsPage), findsOneWidget);
      expect(vault.credentialFor(platform, previous), isNotNull);
      expect(
        vault.store.data
            .obj('cloudAccounts')
            .obj(platform.key)
            .containsKey(owner),
        isFalse,
      );
    }),
  );

  testWidgets(
    'Busy progress survives cancellation, late work and a new small-screen dialog',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 420);
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final old = Completer<void>(), current = Completer<void>();
      final results = <int?>[];
      var runs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('执行'),
                onPressed: () async {
                  final run = ++runs;
                  final result = await busy(context, () async {
                    await OperationProgress.step(
                      OperationStage.verifyShare,
                      () async {},
                    );
                    await OperationProgress.step(
                      OperationStage.createTemporary,
                      () async {},
                    );
                    await OperationProgress.step(
                      run == 1
                          ? OperationStage.transfer
                          : OperationStage.downloadLink,
                      () => (run == 1 ? old : current).future,
                    );
                    return run;
                  }, label: '正在加载网盘文件…');
                  results.add(result);
                },
              ),
            ),
          ),
        ),
      );
      await tap(tester, find.text('执行'), settle: false);
      expect(find.text('正在转存文件…'), findsOneWidget);
      await tap(tester, find.text('取消'));
      await tap(tester, find.text('执行'), settle: false);
      old.complete();
      await tester.pump();
      expect(find.text('正在获取下载链接…'), findsOneWidget);
      expect(find.text('正在转存文件…'), findsNothing);
      current.complete();
      await tester.pumpAndSettle();
      expect(results, [null, 2]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
