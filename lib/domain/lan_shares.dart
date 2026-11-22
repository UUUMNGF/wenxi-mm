import '../core/json.dart';

enum LanShareKind { smb, ftp }

/// 一台可浏览的局域网共享服务器（SMB 或 FTP）。
/// 密码只保存在本机状态文件中，随其他账号凭据同等对待。
class LanShareServer {
  const LanShareServer({
    required this.id,
    required this.kind,
    required this.name,
    required this.host,
    required this.port,
    this.domain = '',
    this.username = '',
    this.password = '',
    this.share = '',
    this.anonymous = false,
  });

  final String id;
  final LanShareKind kind;
  final String name, host, domain, username, password, share;
  final int port;
  final bool anonymous;

  String get label => kind == LanShareKind.smb ? 'SMB' : 'FTP';
  int get defaultPort => kind == LanShareKind.smb ? 445 : 21;
  String get address => port == 0 || port == defaultPort
      ? host
      : '$host:$port';

  LanShareServer copyWith({
    String? name,
    String? host,
    int? port,
    String? domain,
    String? username,
    String? password,
    String? share,
    bool? anonymous,
  }) => LanShareServer(
    id: id,
    kind: kind,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    domain: domain ?? this.domain,
    username: username ?? this.username,
    password: password ?? this.password,
    share: share ?? this.share,
    anonymous: anonymous ?? this.anonymous,
  );

  Json toJson() => {
    'version': 1,
    'id': id,
    'kind': kind.name,
    'name': name,
    'host': host,
    'port': port,
    'domain': domain,
    'username': username,
    'password': password,
    'share': share,
    'anonymous': anonymous,
  };

  /// 组件侧请求参数；Go 端按同一组键解析。
  Json nativeArgs({required String id, required String path}) => {
    'id': id,
    'kind': kind.name,
    'host': host,
    'port': port,
    'domain': domain,
    'username': username,
    'password': password,
    'anonymous': anonymous,
    'share': share,
    'path': path,
  };

  static LanShareServer? tryFromJson(Object? value) {
    if (value is! Map) return null;
    try {
      final json = asJson(value);
      require(json.integer('version') == 1, '局域网服务器版本无效');
      final kind = json.str('kind');
      require(kind == LanShareKind.smb.name || kind == LanShareKind.ftp.name, '局域网服务器类型无效');
      final host = json.str('host');
      require(host.isNotEmpty, '局域网服务器地址缺失');
      return LanShareServer(
        id: json.str('id'),
        kind: kind == LanShareKind.smb.name ? LanShareKind.smb : LanShareKind.ftp,
        name: json.str('name').ifEmpty(host),
        host: host,
        port: json.integer('port'),
        domain: json.str('domain'),
        username: json.str('username'),
        password: json.str('password'),
        share: json.str('share'),
        anonymous: json.boolean('anonymous'),
      );
    } on Object {
      return null;
    }
  }
}

/// 目录中的一条记录；size/modified 对文件夹没有意义。
class LanShareEntry {
  const LanShareEntry({
    required this.name,
    required this.dir,
    required this.size,
    required this.modified,
  });

  final String name;
  final bool dir;
  final int size;
  final int modified;

  static LanShareEntry? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final json = asJson(value);
    final name = json.str('name');
    if (name.isEmpty) return null;
    return LanShareEntry(
      name: name,
      dir: json.boolean('dir'),
      size: json.integer('size'),
      modified: json.integer('modified'),
    );
  }
}
