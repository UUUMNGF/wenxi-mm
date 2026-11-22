import 'package:flutter/foundation.dart';

import '../core/json.dart';
import '../data/state_store.dart';
import '../domain/lan_shares.dart';
import '../platform/native_engine.dart';

/// 已保存的 SMB/FTP 服务器列表，以及到下载组件的共享浏览/流式调用。
/// 连接失败、登录失败等信息由组件在结果 JSON 中返回（桥接层会吞掉原生错误文本）。
class LanShareManager extends ChangeNotifier {
  LanShareManager(this.store, this.transport);

  final StateStore store;
  final NativeTransport transport;

  late List<LanShareServer> servers = [
    for (final value in store.data['lanShares'] as List? ?? const [])
      ?LanShareServer.tryFromJson(value),
  ];

  LanShareServer? server(String id) {
    for (final item in servers) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> save(LanShareServer server) async {
    final index = servers.indexWhere((item) => item.id == server.id);
    if (index >= 0) {
      servers[index] = server;
    } else {
      servers.add(server);
    }
    await _persist();
  }

  Future<void> remove(String id) async {
    servers.removeWhere((item) => item.id == id);
    await _persist();
  }

  Future<void> _persist() async {
    await store.put('lanShares', [for (final item in servers) item.toJson()]);
    notifyListeners();
  }

  /// 测试连接；SMB 会顺带返回共享名列表（share 为空时用于选择）。
  Future<Json> probe(LanShareServer server) =>
      _verify(transport.call('lanShareProbe', server.nativeArgs(id: server.id, path: '')));

  Future<List<LanShareEntry>> list(LanShareServer server, String path) async {
    final result = await _verify(
      transport.call('lanShareList', server.nativeArgs(id: server.id, path: path)),
    );
    return [
      for (final value in result['entries'] as List? ?? const [])
        ?LanShareEntry.tryFromJson(value),
    ];
  }

  Future<Json> streamStart(LanShareServer server, String path, String id) =>
      _verify(
        transport.call('lanShareStreamStart', server.nativeArgs(id: id, path: path)),
      );

  Future<void> streamStop(String id) async {
    if (id.isEmpty) return;
    await transport.call('lanShareStreamStop', {'id': id});
  }

  Future<Json> _verify(Future<Object?> call) async {
    final result = asJson(await call ?? const {});
    if (!result.boolean('ok')) {
      throw AppException(result.str('error').ifEmpty('无法访问该共享，请检查设置'));
    }
    return result;
  }
}
