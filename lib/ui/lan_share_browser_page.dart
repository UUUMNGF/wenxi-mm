import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../core/json.dart';
import '../domain/lan_shares.dart';
import '../domain/models.dart';
import '../playback/lan_share_playback.dart';
import '../playback/playback_controller.dart';
import 'common.dart';
import 'player_page.dart';

/// 浏览一台 SMB/FTP 服务器的目录，媒体文件直接在线播放或预览。
class LanShareBrowserPage extends StatefulWidget {
  const LanShareBrowserPage(this.services, this.server, {super.key});

  final AppServices services;
  final LanShareServer server;

  @override
  State<LanShareBrowserPage> createState() => _LanShareBrowserPageState();
}

class _LanShareBrowserPageState extends State<LanShareBrowserPage> {
  final stack = <String>[];
  List<LanShareEntry> entries = const [];
  bool loading = true, playing = false;
  String error = '';

  String get path => stack.join('/');

  String entryPath(LanShareEntry entry) =>
      stack.isEmpty ? entry.name : '$path/${entry.name}';

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final result = await widget.services.lanShares.list(
        widget.server,
        path,
      );
      if (!mounted) return;
      setState(() {
        entries = result;
        loading = false;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.message;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        error = '无法读取目录，请检查网络后重试';
        loading = false;
      });
    }
  }

  void _enter(LanShareEntry entry) {
    setState(() => stack.add(entry.name));
    unawaited(_refresh());
  }

  void _up() {
    if (stack.isEmpty) return;
    setState(() => stack.removeLast());
    unawaited(_refresh());
  }

  IconData _icon(LanShareEntry entry) => entry.dir
      ? Icons.folder_rounded
      : switch (fileKind(entry.name)) {
          FileKind.image => Icons.image_rounded,
          FileKind.video => Icons.videocam_rounded,
          FileKind.audio => Icons.music_note_rounded,
          FileKind.text => Icons.description_rounded,
          FileKind.pdf => Icons.picture_as_pdf_rounded,
          FileKind.archive => Icons.folder_zip_rounded,
          FileKind.android => Icons.android_rounded,
          _ => Icons.insert_drive_file_rounded,
        };

  String _detail(LanShareEntry entry) {
    if (entry.dir) return entry.modified == 0 ? '文件夹' : formatDate(entry.modified);
    final size = formatBytes(entry.size);
    return entry.modified == 0 ? size : '$size · ${formatDate(entry.modified)}';
  }

  Future<void> _open(LanShareEntry entry) async {
    if (entry.dir) {
      _enter(entry);
      return;
    }
    final kind = fileKind(entry.name);
    if (kind == FileKind.video || kind == FileKind.audio) {
      return _play(entry);
    }
    if (kind == FileKind.image) {
      return _preview(entry);
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('该类型暂不支持在线打开，视频、音乐与图片可直接播放')));
  }

  Future<void> _play(LanShareEntry entry) async {
    if (playing) return;
    setState(() => playing = true);
    PlaybackController? controller;
    try {
      controller = lanSharePlayback(
        widget.services,
        widget.server,
        path: entryPath(entry),
        name: entry.name,
        size: entry.size,
      );
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            controller!,
            subtitleDirectory: Directory(
              '${widget.services.cacheDirectory.path}/playback-subtitles',
            ),
          ),
        ),
      );
    } on AppException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法开始播放，请重试')));
      }
    } finally {
      if (controller != null) {
        widget.services.finishPlaybackInBackground(controller.close());
      }
      if (mounted) setState(() => playing = false);
    }
  }

  Future<void> _preview(LanShareEntry entry) async {
    final id = newId();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await widget.services.lanShares.streamStart(
        widget.server,
        entryPath(entry),
        id,
      );
      if (!mounted) {
        unawaited(widget.services.lanShares.streamStop(id));
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  maxScale: 6,
                  child: Image.network(
                    result.str('url'),
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, progress) =>
                        progress == null
                        ? child
                        : const CircularProgressIndicator(),
                    errorBuilder: (_, _, _) => const Text(
                      '图片加载失败',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      unawaited(widget.services.lanShares.streamStop(id));
    } on AppException catch (e) {
      unawaited(widget.services.lanShares.streamStop(id));
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      unawaited(widget.services.lanShares.streamStop(id));
      messenger.showSnackBar(const SnackBar(content: Text('无法打开该图片，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = themeAccent(context);
    return PopScope(
      canPop: stack.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && stack.isNotEmpty) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.server.name,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: loading ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: Column(
          children: [
            if (stack.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    ActionChip(
                      avatar: Icon(Icons.home_rounded, size: 16, color: accent),
                      label: const Text('根目录'),
                      onPressed: () {
                        setState(stack.clear);
                        unawaited(_refresh());
                      },
                    ),
                    for (final (index, segment) in stack.indexed)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: ActionChip(
                          label: Text(segment, overflow: TextOverflow.ellipsis),
                          onPressed: () {
                            setState(() => stack.removeRange(index + 1, stack.length));
                            unawaited(_refresh());
                          },
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : error.isNotEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            error,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: secondary(context),
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(onPressed: _refresh, child: const Text('重试')),
                        ],
                      ),
                    )
                  : entries.isEmpty
                  ? Center(
                      child: Text(
                        '此文件夹为空',
                        style: TextStyle(fontSize: 13, color: secondary(context)),
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return ListTile(
                          key: Key('lan-share-entry-${entry.name}'),
                          leading: Icon(_icon(entry), color: entry.dir ? accent : null),
                          title: Text(
                            entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15),
                          ),
                          subtitle: Text(
                            _detail(entry),
                            style: TextStyle(fontSize: 12, color: secondary(context)),
                          ),
                          trailing: entry.dir
                              ? const Icon(Icons.chevron_right_rounded, size: 20)
                              : null,
                          onTap: () => _open(entry),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
