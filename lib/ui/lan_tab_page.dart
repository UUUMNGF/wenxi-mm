import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../domain/lan_shares.dart';
import 'common.dart';
import 'lan_share_browser_page.dart';
import 'lan_share_edit_page.dart';

/// 局域网文件共享：管理 SMB/FTP 服务器，浏览并在线播放共享文件。
class LanTabPage extends StatelessWidget {
  const LanTabPage(this.services, {super.key, this.active = false});

  final AppServices services;
  final bool active;

  void _add(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LanShareEditPage(services)),
    );
  }

  void _open(BuildContext context, LanShareServer server) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LanShareBrowserPage(services, server)),
    );
  }

  Future<void> _edit(BuildContext context, LanShareServer server) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LanShareEditPage(services, server: server)),
    );
  }

  Future<void> _delete(BuildContext context, LanShareServer server) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除服务器'),
        content: Text('删除「${server.name}」？仅移除记录，不会影响共享本身。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (approved == true) {
      await services.lanShares.remove(server.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.lanShares,
      builder: (context, _) {
        final servers = services.lanShares.servers;
        if (servers.isEmpty) return _emptyState(context);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            for (final server in servers)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerHighest
                    .withValues(alpha: .35),
                child: ListTile(
                  key: Key('lan-share-server-${server.id}'),
                  onTap: () => _open(context, server),
                  leading: CircleAvatar(
                    backgroundColor: themeAccent(context).withValues(alpha: .12),
                    child: Icon(
                      server.kind == LanShareKind.smb
                          ? Icons.dns_rounded
                          : Icons.public_rounded,
                      size: 21,
                      color: themeAccent(context),
                    ),
                  ),
                  title: Text(
                    server.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${server.label} · ${server.address}'
                    '${server.share.isEmpty ? '' : ' · /${server.share}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz_rounded, size: 20),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                    onSelected: (action) {
                      if (action == 'edit') {
                        unawaited(_edit(context, server));
                      } else if (action == 'delete') {
                        unawaited(_delete(context, server));
                      }
                    },
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Center(
              child: FilledButton.tonalIcon(
                key: const Key('lan-share-add'),
                onPressed: () => _add(context),
                icon: const Icon(Icons.add_rounded, size: 19),
                label: const Text('添加服务器'),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _emptyState(BuildContext context) {
    final accent = themeAccent(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 40),
      children: [
        Column(
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.folder_shared_rounded,
                size: 44,
                color: accent,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '局域网文件共享',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              '添加 NAS、Windows 共享文件夹（SMB）或 FTP 服务器\n浏览并在线播放其中的视频、音乐与图片',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: secondary(context),
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              key: const Key('lan-share-add'),
              onPressed: () => _add(context),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 44),
              ),
              icon: const Icon(Icons.add_rounded, size: 19),
              label: const Text('添加服务器'),
            ),
          ],
        ),
      ],
    );
  }
}
