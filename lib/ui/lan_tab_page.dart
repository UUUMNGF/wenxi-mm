import 'package:flutter/material.dart';

import '../app_services.dart';
import 'app_theme.dart';
import 'common.dart';

/// 局域网连接占位页：完整连接界面后续接入，先提供设备互联入口。
class LanTabPage extends StatelessWidget {
  const LanTabPage(
    this.services, {
    super.key,
    this.active = false,
    this.onOpen,
  });

  final AppServices services;
  final bool active;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 40),
      children: [
        Column(
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: themeAccent(context).withValues(alpha: .10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.devices_rounded,
                size: 44,
                color: themeAccent(context),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '设备互联',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              '同一局域网内互传文字、链接与文件\n完整连接界面即将接入',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: secondary(context),
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              key: const Key('lan-tab-open'),
              onPressed: onOpen,
              style: FilledButton.styleFrom(
                backgroundColor: themeAccent(context),
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 44),
              ),
              icon: const Icon(Icons.devices_rounded, size: 19),
              label: const Text('打开设备互联'),
            ),
          ],
        ),
      ],
    );
  }
}
