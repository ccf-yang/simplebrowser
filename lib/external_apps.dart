import 'package:flutter/material.dart';

import 'theme.dart';

/// What the user decided about a page trying to open another app.
enum ExternalChoice { allowOnce, alwaysAllow, copy, deny }

/// Schemes a browser meets in Chinese-speaking sites, so a dialog can say
/// 「哔哩哔哩」 instead of 「bilibili://」。 An unknown protocol is still shown by
/// name — an unnamed app asking to open is exactly when the user needs to see
/// what was asked.
const Map<String, String> _appNames = <String, String>{
  'bilibili': '哔哩哔哩',
  'bilivideo': '哔哩哔哩',
  'snssdk1128': '抖音',
  'snssdk2329': '抖音',
  'aweme': '抖音',
  'kwai': '快手',
  'kuaishou': '快手',
  'weibo': '微博',
  'sinaweibo': '微博',
  'weixin': '微信',
  'wx': '微信',
  'wechat': '微信',
  'mqq': 'QQ',
  'qq': 'QQ',
  'alipays': '支付宝',
  'alipay': '支付宝',
  'taobao': '淘宝',
  'tmall': '天猫',
  'openapp.jdmobile': '京东',
  'jdmobile': '京东',
  'meituan': '美团',
  'meituanwaimai': '美团外卖',
  'dianping': '大众点评',
  'baiduboxapp': '百度',
  'baiduboxlite': '百度',
  'haokan': '好看视频',
  'zhihu': '知乎',
  'youku': '优酷',
  'qiyi': '爱奇艺',
  'iqiyi': '爱奇艺',
  'tencentvideo': '腾讯视频',
  'tenvideo2': '腾讯视频',
  'mgtv': '芒果TV',
  'dingtalk': '钉钉',
  'dingtalk-sso': '钉钉',
  'Lark': '飞书',
  'feishu': '飞书',
  'xhs': '小红书',
  'snssdk35': '头条',
  'toutiao': '头条',
  'itms-apps': 'App Store',
  'itms-appss': 'App Store',
  'mailto': '邮件',
  'tel': '电话',
  'sms': '短信',
  'facetime': 'FaceTime',
  'maps': 'Apple 地图',
  'intent': '其他应用',
};

/// The name to show for a URL scheme, or for a host whose site wants to open
/// its own app.
String externalAppName(String key) {
  final lower = key.toLowerCase();
  final known = _appNames[lower];
  if (known != null) return known;
  // `www.bilibili.com` and `m.bilibili.com` both belong to `bilibili`.
  final parts = lower.split('.');
  if (parts.length >= 2) {
    final brand = parts.length >= 3 && parts[parts.length - 3].length > 2
        ? parts[parts.length - 3]
        : parts.length >= 2
            ? parts[parts.length - 2]
            : lower;
    final fromHost = _appNames[brand];
    if (fromHost != null) return fromHost;
    if (brand.length > 1) return brand;
  }
  return lower.contains('.') ? lower : '$lower 协议';
}

/// The app a jump would open, named the way the user knows it.
String externalAppNameForJump(Uri target, Uri? page) {
  final scheme = target.scheme;
  if (scheme.isNotEmpty && _appNames[scheme.toLowerCase()] != null) {
    return _appNames[scheme.toLowerCase()]!;
  }
  final fromPage = page == null ? '' : externalAppName(page.host);
  if (fromPage.isNotEmpty && fromPage != page?.host) return fromPage;
  return externalAppName(scheme);
}

/// The ALook-style question: a page wants to leave this browser for another app.
///
/// Nothing has happened yet — the navigation was cancelled the moment it was
/// seen — so every answer is a real choice, including 「拷贝」, which is what the
/// user wants when the app is not installed at all.
Future<ExternalChoice?> askAboutExternalJump(
  BuildContext context, {
  required Uri uri,
  required String appName,
  required String pageHost,
}) => showModalBottomSheet<ExternalChoice>(
  context: context,
  backgroundColor: Colors.transparent,
  barrierColor: AppColors.ink.withAlpha(120),
  builder: (sheetContext) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              pageHost.isEmpty
                  ? '$appName 想启动外部应用'
                  : '$pageHost 想启动 $appName',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              uri.toString(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.35,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 10),
            _ChoiceRow(
              label: '打开 $appName',
              note: '仅这一次',
              icon: Icons.open_in_new_rounded,
              onTap: () =>
                  Navigator.of(sheetContext).pop(ExternalChoice.allowOnce),
            ),
            _ChoiceRow(
              label: '总是允许 $appName',
              note: '${uri.scheme}:// 以后不再问',
              icon: Icons.check_circle_outline_rounded,
              onTap: () =>
                  Navigator.of(sheetContext).pop(ExternalChoice.alwaysAllow),
            ),
            _ChoiceRow(
              label: '拷贝地址',
              note: '本机没装应用时更好用',
              icon: Icons.copy_rounded,
              onTap: () => Navigator.of(sheetContext).pop(ExternalChoice.copy),
            ),
            _ChoiceRow(
              label: '不允许',
              note: '以后都禁止 ${uri.scheme}://',
              icon: Icons.do_not_disturb_on_outlined,
              tone: _Tone.deny,
              onTap: () => Navigator.of(sheetContext).pop(ExternalChoice.deny),
            ),
          ],
        ),
      ),
    ),
  ),
);

enum _Tone { plain, deny }

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.note,
    required this.icon,
    required this.onTap,
    this.tone = _Tone.plain,
  });

  final String label;
  final String note;
  final IconData icon;
  final VoidCallback onTap;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final ink = tone == _Tone.deny ? AppColors.danger : AppColors.ink;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 17, color: ink),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      note,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.faint,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
