import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';
import 'webdav.dart';

/// WebDAV 配置页：填地址账号、试一下连通、存下来。
///
/// 它自己负责落盘（[onSave] 由宿主接 prefs 写入），所以从设置页打开后不需要
/// 再走「Save & reload」那套返回值。
class WebDavSheet extends StatefulWidget {
  const WebDavSheet({
    super.key,
    required this.initial,
    required this.onSave,
  });

  final WebDavConfig initial;

  /// Persists the config; errors come back as a message, null means stored.
  final Future<String?> Function(WebDavConfig config) onSave;

  @override
  State<WebDavSheet> createState() => _WebDavSheetState();
}

class _WebDavSheetState extends State<WebDavSheet> {
  late final TextEditingController _url =
      TextEditingController(text: widget.initial.url);
  late final TextEditingController _user =
      TextEditingController(text: widget.initial.username);
  late final TextEditingController _password =
      TextEditingController(text: widget.initial.password);
  late final TextEditingController _path =
      TextEditingController(text: widget.initial.savePath);
  late bool _ignoreTls = widget.initial.ignoreTls;
  late bool _alsoPhotos = widget.initial.alsoPhotos;

  bool _testing = false;
  String? _testError;
  List<WebDavEntry>? _entries;
  String? _savedNote;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    _path.dispose();
    super.dispose();
  }

  WebDavConfig _draft() => WebDavConfig(
    url: _url.text.trim(),
    username: _user.text.trim(),
    password: _password.text,
    savePath: _path.text.trim(),
    ignoreTls: _ignoreTls,
    alsoPhotos: _alsoPhotos,
  );

  /// PROPFIND 根目录，再试探一次存放目录存不存在。列不出根目录就是没连上，
  /// 存放目录列不出来只算提示，不算失败（第一次上传会自动建）。
  Future<void> _test() async {
    final config = _draft();
    setState(() {
      _testing = true;
      _testError = null;
      _entries = null;
      _savedNote = null;
    });
    List<WebDavEntry>? listed;
    String? failure;
    var targetMissing = false;
    WebDavClient? client;
    try {
      client = WebDavClient(config);
      listed = await client.list('/');
      if (config.savePath.trim().isNotEmpty) {
        try {
          await client.list(config.savePath);
        } on WebDavException {
          targetMissing = true;
        }
      }
    } on WebDavException catch (error) {
      failure = error.message;
    } on Object catch (error) {
      failure = error.toString();
    } finally {
      client?.close();
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testError = failure;
      _entries = listed;
      if (failure == null && targetMissing) {
        _savedNote = '存放路径 ${normalizeRemotePath(config.savePath)} '
            '还没有，第一次上传会自动建';
      }
    });
  }

  Future<void> _save() async {
    final config = _draft();
    final error = await widget.onSave(config);
    if (!mounted) return;
    if (error != null) {
      setState(() => _savedNote = '没能保存：$error');
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          '清空 WebDAV 配置？',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '地址、账号、密码和存放路径都会删掉，已传到服务器上的文件不受影响。',
          style: TextStyle(fontSize: 12, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _url.text = '';
      _user.text = '';
      _password.text = '';
      _path.text = '';
      _ignoreTls = false;
      _alsoPhotos = false;
      _entries = null;
      _testError = null;
      _savedNote = null;
    });
    final error = await widget.onSave(const WebDavConfig());
    if (!mounted) return;
    if (error != null) {
      setState(() => _savedNote = '没能清空：$error');
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final config = _draft();
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          ),
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _handle(),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          'WebDAV 存储',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                      _CloseButton(
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '资源还是先下到本机，再传到这个目录，传成功就把本机那份删掉。'
                    'OpenList / Alist 要填到 /dav 结尾。',
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.6,
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _Field(
                    label: '服务器地址',
                    hint: 'http://192.168.1.17:5244/dav',
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 8),
                  _Field(
                    label: '用户名',
                    hint: '留空表示匿名',
                    controller: _user,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 8),
                  _Field(
                    label: '密码',
                    hint: '明文存在 App 的沙盒里',
                    controller: _password,
                    obscure: true,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 8),
                  _Field(
                    label: '存放路径',
                    hint: '/browser（相对 WebDAV 根，留空用根目录）',
                    controller: _path,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 6),
                  _SwitchRow(
                    title: '忽略证书校验',
                    subtitle: '自签或过期证书时用；明文 http 不需要开',
                    value: _ignoreTls,
                    onChanged: (value) => setState(() => _ignoreTls = value),
                  ),
                  _SwitchRow(
                    title: '传完也存相册',
                    subtitle: '默认只留服务器那一份',
                    value: _alsoPhotos,
                    onChanged: (value) => setState(() => _alsoPhotos = value),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _testing || !config.ready
                              ? null
                              : () => unawaited(_test()),
                          icon: _testing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.ink,
                                  ),
                                )
                              : const Icon(
                                  Icons.network_check_rounded,
                                  size: 15,
                                ),
                          label: Text(_testing ? '测试中…' : '测试连接'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => unawaited(_save()),
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                  _buildResult(config),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: config.ready ? () => unawaited(_clear()) : null,
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.danger,
                      ),
                      child: const Text('清空配置'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResult(WebDavConfig config) {
    if (_testError != null) {
      return _ResultCard(
        tone: _Tone.bad,
        title: '连不上',
        message: _testError!,
      );
    }
    final entries = _entries;
    if (entries != null) {
      final names = entries
          .take(8)
          .map((entry) => entry.isDir ? '${entry.name}/' : entry.name)
          .join('   ');
      return _ResultCard(
        tone: _Tone.good,
        title: '连通正常',
        message: entries.isEmpty
            ? '根目录是空的，可以直接用。\n'
                  '落点：${normalizeRemotePath(config.savePath)}'
            : '根目录 ${entries.length} 项：$names\n'
                  '落点：${normalizeRemotePath(config.savePath)}'
                  '${_savedNote == null ? '' : '\n$_savedNote'}',
      );
    }
    if (_savedNote != null) return _ResultCard(tone: _Tone.good, message: _savedNote!);
    if (!config.ready) {
      return const _ResultCard(
        tone: _Tone.muted,
        message: '还没填地址。填好后点「测试连接」，能列出根目录就能用。',
      );
    }
    return const SizedBox.shrink();
  }

  Widget _handle() => Center(
    child: Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: AppColors.line2,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

enum _Tone { good, bad, muted }

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.tone,
    this.title,
    required this.message,
  });

  final _Tone tone;
  final String? title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final (Color accent, Color background, Color line) = switch (tone) {
      _Tone.good => (AppColors.signalInk, AppColors.signalWash, AppColors.signalLine),
      _Tone.bad => (AppColors.danger, AppColors.card, AppColors.danger),
      _Tone.muted => (AppColors.muted, AppColors.wash, AppColors.line),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (title != null) ...<Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    tone == _Tone.good
                        ? Icons.check_circle_rounded
                        : Icons.error_outline_rounded,
                    size: 14,
                    color: accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    title!,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
            SelectableText(
              message,
              style: TextStyle(
                fontSize: 10,
                height: 1.6,
                color: tone == _Tone.bad ? accent : AppColors.ink2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.hint,
    required this.controller,
    this.keyboardType,
    this.obscure = false,
    this.autocorrect = true,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool obscure;
  final bool autocorrect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscure,
          autocorrect: autocorrect,
          enableSuggestions: false,
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'menlo',
            fontFamilyFallback: <String>['monospace'],
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 11, color: AppColors.faint),
            filled: true,
            fillColor: AppColors.card,
            contentPadding: const EdgeInsets.fromLTRB(11, 11, 11, 11),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: AppColors.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: AppColors.ink),
            ),
          ),
        ),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 9.5, color: AppColors.muted),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.wash,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: const SizedBox(
          width: 30,
          height: 30,
          child: Icon(Icons.close_rounded, size: 16, color: AppColors.muted),
        ),
      ),
    );
  }
}
