import 'package:flutter/material.dart';

import 'theme.dart';

/// A browsing action chosen from the sheet instead of "Save & reload".
enum SettingsAction { goHome, saveBookmark, openBookmarks, openDownloads }

/// Values collected by the settings sheet.
///
/// [refererMode] is 0 for none and 1 for the current domain, so the sheet does
/// not need to import the page's private enum.
class SettingsValues {
  const SettingsValues({
    required this.uaIndex,
    required this.refererMode,
    required this.cookie,
    required this.showPanel,
    required this.blockExternal,
    required this.adBlock,
    this.action,
  });

  final int uaIndex;
  final int refererMode;
  final String cookie;
  final bool showPanel;

  /// Cancel jumps that would leave the app (custom schemes and Universal Links).
  final bool blockExternal;

  /// Install the WebKit content-blocker list for every page.
  final bool adBlock;

  /// Set when the sheet was closed by tapping Home / Save bookmark /
  /// Bookmarks; the page runs the action instead of reloading.
  final SettingsAction? action;
}

/// Bottom sheet with the request identity settings plus the info-panel switch.
///
/// The panel and stay-in-app switches are applied immediately (the page
/// rebuilds behind the sheet); the headers are applied when the user taps
/// "Save & reload".
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.initial,
    required this.uaLabels,
    required this.onShowPanelChanged,
    required this.onBlockExternalChanged,
    required this.adBlockEnabled,
    this.adBlockStatus = '',
    this.bookmarkCount = 0,
    this.downloadCount = 0,
    this.canSaveBookmark = false,
  });

  final SettingsValues initial;
  final List<String> uaLabels;
  final ValueChanged<bool> onShowPanelChanged;
  final ValueChanged<bool> onBlockExternalChanged;

  /// Current state plus a short line about the compiled rule set, e.g.
  /// `53283 rules ready` or `compile failed`.
  final bool adBlockEnabled;
  final String adBlockStatus;
  final int bookmarkCount;
  final int downloadCount;
  final bool canSaveBookmark;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late int _uaIndex = widget.initial.uaIndex;
  late int _refererMode = widget.initial.refererMode;
  late bool _showPanel = widget.initial.showPanel;
  late bool _blockExternal = widget.initial.blockExternal;
  late bool _adBlock = widget.initial.adBlock;
  late final TextEditingController _cookie =
      TextEditingController(text: widget.initial.cookie);

  @override
  void dispose() {
    _cookie.dispose();
    super.dispose();
  }

  void _save([SettingsAction? action]) {
    Navigator.of(context).pop(
      SettingsValues(
        uaIndex: _uaIndex,
        refererMode: _refererMode,
        cookie: _cookie.text,
        showPanel: _showPanel,
        blockExternal: _blockExternal,
        adBlock: _adBlock,
        action: action,
      ),
    );
  }

  void _reset() {
    setState(() {
      _uaIndex = 0;
      _refererMode = 0;
      _cookie.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
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
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.line2,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          'Settings',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                      _CloseButton(onTap: () => Navigator.of(context).pop()),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Request identity is applied to both WKWebView navigation '
                    'and the native engine capture.',
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.55,
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const _FieldLabel('User-Agent'),
                  const SizedBox(height: 5),
                  _buildUaField(),
                  const SizedBox(height: 10),
                  const _FieldLabel('Referer'),
                  const SizedBox(height: 5),
                  _MiniSeg(
                    options: const <String>['None', 'Current domain'],
                    index: _refererMode,
                    onChanged: (value) =>
                        setState(() => _refererMode = value),
                  ),
                  const SizedBox(height: 10),
                  const _FieldLabel('Cookie'),
                  const SizedBox(height: 5),
                  _buildCookieField(),
                  const SizedBox(height: 10),
                  _buildPanelSwitch(),
                  const SizedBox(height: 8),
                  _buildStayInAppSwitch(),
                  const SizedBox(height: 8),
                  _buildAdBlockSwitch(),
                  const SizedBox(height: 14),
                  const _FieldLabel('Browsing'),
                  const SizedBox(height: 5),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _ActionTile(
                          icon: Icons.home_rounded,
                          label: 'Home',
                          onTap: () => _save(SettingsAction.goHome),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _ActionTile(
                          icon: Icons.bookmark_add_outlined,
                          label: 'Save',
                          onTap: widget.canSaveBookmark
                              ? () => _save(SettingsAction.saveBookmark)
                              : null,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _ActionTile(
                          icon: Icons.bookmarks_outlined,
                          label: widget.bookmarkCount == 0
                              ? 'Bookmarks'
                              : 'Bookmarks ${widget.bookmarkCount}',
                          onTap: () =>
                              _save(SettingsAction.openBookmarks),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _ActionTile(
                          icon: Icons.download_rounded,
                          label: widget.downloadCount == 0
                              ? 'Files'
                              : 'Files ${widget.downloadCount}',
                          onTap: () =>
                              _save(SettingsAction.openDownloads),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const _Hint(),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      TextButton(
                        onPressed: _reset,
                        child: const Text('Reset'),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.check_rounded, size: 16),
                        label: const Text('Save & reload'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUaField() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: _uaIndex,
          isDense: true,
          isExpanded: true,
          borderRadius: BorderRadius.circular(14),
          icon: const Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 20,
            color: AppColors.muted,
          ),
          style: const TextStyle(fontSize: 12.5, color: AppColors.ink),
          items: <DropdownMenuItem<int>>[
            for (var i = 0; i < widget.uaLabels.length; i++)
              DropdownMenuItem<int>(
                value: i,
                child: Text(
                  widget.uaLabels[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _uaIndex = value);
          },
        ),
      ),
    );
  }

  Widget _buildCookieField() {
    return TextField(
      controller: _cookie,
      autocorrect: false,
      enableSuggestions: false,
      maxLines: 1,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 11,
        color: AppColors.ink2,
      ),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.card,
        hintText: 'session=…; theme=dark',
        hintStyle: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: AppColors.faint,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 13,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.line2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.ink, width: 1.2),
        ),
      ),
    );
  }

  Widget _buildPanelSwitch() => _SwitchRow(
    title: 'Info panel',
    subtitle: 'WebView · Engine · Page · Log',
    value: _showPanel,
    onChanged: (value) {
      setState(() => _showPanel = value);
      widget.onShowPanelChanged(value);
    },
  );

  Widget _buildStayInAppSwitch() => _SwitchRow(
    title: 'Stay in this app',
    subtitle: 'Block baidu:// and other app jumps',
    value: _blockExternal,
    onChanged: (value) {
      setState(() => _blockExternal = value);
      widget.onBlockExternalChanged(value);
    },
  );

  Widget _buildAdBlockSwitch() => _SwitchRow(
    title: 'Block ads',
    subtitle: widget.adBlockStatus.isEmpty
        ? 'WebKit content rules · reload to apply'
        : widget.adBlockStatus,
    value: _adBlock,
    onChanged: (value) => setState(() => _adBlock = value),
  );
}

/// One tap target in the Browsing row: Home, Save bookmark or Bookmarks.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled ? AppColors.card : AppColors.wash,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            border: Border.all(
              color: enabled ? AppColors.line2 : AppColors.line,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                icon,
                size: 15,
                color: enabled ? AppColors.ink : AppColors.faint,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: enabled ? AppColors.ink2 : AppColors.faint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One labelled switch row inside the settings sheet.
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
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line2),
        borderRadius: BorderRadius.circular(14),
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
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 9.5,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.ink,
            activeTrackColor: AppColors.signal,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: AppColors.wash,
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: AppColors.faint,
        ),
      );
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
          width: 28,
          height: 28,
          child: Icon(Icons.close_rounded, size: 15, color: AppColors.muted),
        ),
      ),
    );
  }
}

class _MiniSeg extends StatelessWidget {
  const _MiniSeg({
    required this.options,
    required this.index,
    required this.onChanged,
  });

  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.wash,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < options.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == index ? AppColors.card : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    boxShadow: i == index
                        ? const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x140E0F0E),
                              blurRadius: 2,
                              offset: Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    options[i],
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight:
                          i == index ? FontWeight.w600 : FontWeight.w400,
                      color: i == index ? AppColors.ink : AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.signalWash,
        border: Border.all(color: AppColors.signalLine),
        borderRadius: BorderRadius.circular(11),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline_rounded, size: 13, color: Color(0xFF6E7A3C)),
          SizedBox(width: 7),
          Expanded(
            child: Text(
              'Saving reloads the current page with the new headers; the next '
              'engine capture uses them too.',
              style: TextStyle(
                fontSize: 9,
                height: 1.5,
                color: Color(0xFF4C5430),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
