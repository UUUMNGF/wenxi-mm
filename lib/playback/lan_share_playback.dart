import 'dart:async';

import '../app_services.dart';
import '../core/json.dart';
import '../data/playback_store.dart';
import '../domain/file_types.dart';
import '../domain/lan_shares.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import '../domain/playback_source.dart';
import 'playback_backend_factory.dart';
import 'playback_controller.dart';

/// 局域网共享文件的在线播放：组件端为本机开一个带 Range 的回环地址，
/// 播放器与 BT 播放共用同一套缓冲与 seek 逻辑。
PlaybackController lanSharePlayback(
  AppServices services,
  LanShareServer server, {
  required String path,
  required String name,
  required int size,
  String? initialHistoryKey,
}) {
  final kind = fileKind(name);
  final entries = [
    PlaybackEntry(
      id: path,
      key:
          initialHistoryKey ?? playbackKey(['lanShare', server.id, path, size]),
      name: name,
      video: kind == FileKind.video,
      source: PlaybackSource.lanShare(server.id, path: path, size: size),
    ),
  ];
  var streamId = '';
  return PlaybackController(
    entries: entries,
    initialIndex: 0,
    history: PlaybackStore(services.store),
    prepare: (entry, scope) async {
      if (streamId.isNotEmpty) {
        unawaited(services.lanShares.streamStop(streamId));
        streamId = '';
      }
      final id = newId();
      final result = await services.lanShares.streamStart(server, path, id);
      require(!scope.token.isCancelled, '播放已取消');
      final uri = Uri.tryParse(result.str('url'));
      require(
        uri != null &&
            uri.scheme == 'http' &&
            uri.host == '127.0.0.1' &&
            uri.port > 0 &&
            result.integer('size') == size,
        '局域网播放地址无效',
      );
      streamId = id;
      return DownloadSpec(url: uri.toString(), fileName: name, expectedSize: size);
    },
    retain: (_) {},
    release: (source) async {
      final id = streamId;
      streamId = '';
      try {
        await services.lanShares.streamStop(id);
      } on Object {
        // Closing must not mask the player's own teardown errors.
      }
    },
    backendFactory:
        (entry, hardware) => createPlaybackBackend(
          video: entry.video,
          hardwareAcceleration: hardware,
        ),
  );
}
