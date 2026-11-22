import 'package:flutter/material.dart';

import '../app_services.dart';
import '../core/json.dart';
import '../domain/lan_shares.dart';
import '../domain/models.dart';
import 'common.dart';

/// 新建/编辑一台 SMB 或 FTP 共享服务器。SMB 需要通过「测试连接」选择共享文件夹。
class LanShareEditPage extends StatefulWidget {
  const LanShareEditPage(this.services, {super.key, this.server});

  final AppServices services;
  final LanShareServer? server;

  @override
  State<LanShareEditPage> createState() => _LanShareEditPageState();
}

class _LanShareEditPageState extends State<LanShareEditPage> {
  late LanShareKind kind = widget.server?.kind ?? LanShareKind.smb;
  late final name = TextEditingController(text: widget.server?.name ?? '');
  late final host = TextEditingController(text: widget.server?.host ?? '');
  late final domain = TextEditingController(text: widget.server?.domain ?? '');
  late final username = TextEditingController(
    text: widget.server?.username ?? '',
  );
  late final password = TextEditingController(
    text: widget.server?.password ?? '',
  );
  late final share = TextEditingController(text: widget.server?.share ?? '');
  late int port = widget.server?.port ?? 0;
  late final portText = TextEditingController(
    text: '${widget.server?.port ?? (kind == LanShareKind.smb ? 445 : 21)}',
  );
  late bool anonymous = widget.server?.anonymous ?? false;
  List<String> shares = const [];
  bool testing = false, saving = false;
  String testResult = '';

  bool get editing => widget.server != null;
  int get effectivePort => port == 0 ? (kind == LanShareKind.smb ? 445 : 21) : port;

  LanShareServer buildServer() => LanShareServer(
    id: widget.server?.id ?? newId(),
    kind: kind,
    name: name.text.trim().ifEmpty(host.text.trim()),
    host: host.text.trim(),
    port: effectivePort,
    domain: kind == LanShareKind.smb ? domain.text.trim() : '',
    username: anonymous ? '' : username.text.trim(),
    password: anonymous ? '' : password.text,
    share: kind == LanShareKind.smb ? share.text.trim().replaceAll('\\', '/') : '',
    anonymous: anonymous,
  );

  Future<void> _test() async {
    if (host.text.trim().isEmpty) {
      setState(() => testResult = '请先填写服务器地址');
      return;
    }
    setState(() {
      testing = true;
      testResult = '';
    });
    try {
      final result = await widget.services.lanShares.probe(buildServer());
      final found = [
        for (final value in result['shares'] as List? ?? const []) '$value',
      ];
      if (!mounted) return;
      setState(() {
        shares = found;
        testResult = found.isEmpty
            ? '连接成功'
            : '连接成功，找到 ${found.length} 个共享文件夹';
      });
    } on AppException catch (error) {
      if (mounted) setState(() => testResult = error.message);
    } catch (_) {
      if (mounted) setState(() => testResult = '连接失败，请检查地址与网络');
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  Future<void> _save() async {
    if (host.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写服务器地址')));
      return;
    }
    if (kind == LanShareKind.smb && share.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请选择或填写共享文件夹')));
      return;
    }
    setState(() => saving = true);
    try {
      await widget.services.lanShares.save(buildServer());
      if (mounted) Navigator.of(context).pop();
    } on AppException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = themeAccent(context);
    return Scaffold(
      appBar: AppBar(title: Text(editing ? '编辑服务器' : '添加服务器')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          SegmentedButton<LanShareKind>(
            segments: [
              ButtonSegment(
                value: LanShareKind.smb,
                label: const Text('SMB / NAS'),
                icon: const Icon(Icons.dns_rounded, size: 18),
              ),
              ButtonSegment(
                value: LanShareKind.ftp,
                label: const Text('FTP'),
                icon: const Icon(Icons.public_rounded, size: 18),
              ),
            ],
            selected: {kind},
            onSelectionChanged: (selection) => setState(() {
              kind = selection.first;
              port = 0;
              portText.text = '${kind == LanShareKind.smb ? 445 : 21}';
              shares = const [];
              testResult = '';
            }),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: host,
            enabled: !testing && !saving,
            decoration: InputDecoration(
              labelText: '服务器地址',
              hintText: kind == LanShareKind.smb ? '例如 192.168.1.10' : '例如 192.168.1.10 或 domain.com',
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: portText,
            enabled: false,
            decoration: const InputDecoration(labelText: '端口'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: name,
            enabled: !testing && !saving,
            decoration: const InputDecoration(
              labelText: '名称（可选）',
              hintText: '默认使用服务器地址',
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('匿名 / 访客访问'),
            subtitle: const Text('不填写账号密码，直接使用服务器允许的匿名权限'),
            value: anonymous,
            onChanged: (value) => setState(() => anonymous = value),
          ),
          if (!anonymous) ...[
            TextField(
              controller: username,
              enabled: !testing && !saving,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: password,
              enabled: !testing && !saving,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
            const SizedBox(height: 14),
          ],
          if (kind == LanShareKind.smb) ...[
            TextField(
              controller: domain,
              enabled: !testing && !saving,
              decoration: const InputDecoration(
                labelText: '域 / 工作组（可选）',
                hintText: '通常留空即可',
              ),
            ),
            const SizedBox(height: 14),
            if (shares.isEmpty)
              TextField(
                controller: share,
                enabled: !testing && !saving,
                decoration: const InputDecoration(
                  labelText: '共享文件夹',
                  hintText: '先点「测试连接」自动获取',
                ),
              )
            else ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '共享文件夹',
                  style: TextStyle(fontSize: 12, color: secondary(context)),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in shares)
                    ChoiceChip(
                      label: Text(item),
                      selected: share.text == item,
                      onSelected: (_) => setState(() => share.text = item),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('lan-share-test'),
            onPressed: testing || saving ? null : _test,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 44),
              side: BorderSide(color: accent),
              foregroundColor: accent,
            ),
            icon: testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering_rounded, size: 19),
            label: const Text('测试连接'),
          ),
          if (testResult.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              testResult,
              style: TextStyle(
                fontSize: 13,
                color: testResult.startsWith('连接成功')
                    ? accent
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('lan-share-save'),
            onPressed: testing || saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 44),
            ),
            child: Text(editing ? '保存修改' : '添加'),
          ),
        ],
      ),
    );
  }
}
