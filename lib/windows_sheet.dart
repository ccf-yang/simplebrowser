import 'package:flutter/material.dart';

import 'theme.dart';
import 'windows.dart';

/// What the user wants done with a link they held down.
enum LinkAction { newWindow, currentWindow, copy }

/// The hold menu.
///
/// It appears while the thumb is still on the screen, so it is three verbs and
/// the address, nothing else. A plain tap never shows this: it still just
/// follows the link in the window it was made in.
Future<LinkAction?> askAboutLink(
  BuildContext context, {
  required Uri uri,
  required String text,
}) =>
    showModalBottomSheet<LinkAction>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.ink.withAlpha(88),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (text.trim().isNotEmpty) ...<Widget>[
                  Text(
                    text.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                ],
                Text(
                  uri.toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.35,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 8),
                _HoldRow(
                  label: '在新窗口打开',
                  icon: Icons.open_in_new_rounded,
                  onTap: () => Navigator.of(sheetContext)
                      .pop(LinkAction.newWindow),
                ),
                _HoldRow(
                  label: '在当前窗口打开',
                  icon: Icons.reply_rounded,
                  onTap: () => Navigator.of(sheetContext)
                      .pop(LinkAction.currentWindow),
                ),
                _HoldRow(
                  label: '复制链接',
                  icon: Icons.copy_rounded,
                  onTap: () =>
                      Navigator.of(sheetContext).pop(LinkAction.copy),
                ),
              ],
            ),
          ),
        ),
      ),
    );

class _HoldRow extends StatelessWidget {
  const _HoldRow({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
            child: Row(
              children: <Widget>[
                Icon(icon, size: 17, color: AppColors.ink),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

/// Every window at once: tap a card to go there, swipe one away or press its
/// corner ✕ to close it, add another.
Future<void> showTaskView(
  BuildContext context, {
  required WindowStore store,
  required void Function(BrowseWindow window) onSelect,
  required void Function(BrowseWindow window) onClose,
  required VoidCallback onCreate,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.ink.withAlpha(120),
      builder: (_) => _TaskView(
        store: store,
        onSelect: onSelect,
        onClose: onClose,
        onCreate: onCreate,
      ),
    );

class _TaskView extends StatefulWidget {
  const _TaskView({
    required this.store,
    required this.onSelect,
    required this.onClose,
    required this.onCreate,
  });

  final WindowStore store;
  final void Function(BrowseWindow window) onSelect;
  final void Function(BrowseWindow window) onClose;
  final VoidCallback onCreate;

  @override
  State<_TaskView> createState() => _TaskViewState();
}

class _TaskViewState extends State<_TaskView> {
  void _pick(BrowseWindow window) {
    widget.onSelect(window);
    Navigator.of(context).pop();
  }

  void _close(BrowseWindow window) {
    widget.onClose(window);
    setState(() {});
    // Closing the last window makes the store open a fresh blank one a few
    // awaits later, which is after this frame. Rebuild once more so the grid is
    // never left showing an empty shelf.
    Future<void>.delayed(const Duration(milliseconds: 320), () {
      if (mounted) setState(() {});
    });
  }

  void _create() {
    widget.onCreate();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final windows = widget.store.windows;
    final height = MediaQuery.sizeOf(context).height * 0.76;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Container(
          constraints: BoxConstraints(maxHeight: height),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Icon(
                          Icons.grid_view_rounded,
                          size: 16,
                          color: AppColors.ink,
                        ),
                        const SizedBox(width: 7),
                        Text(
                          '任务视图 · ${windows.length} 个窗口',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.ink,
                          ),
                        ),
                        const Spacer(),
                        if (windows.length < WindowStore.max)
                          TextButton.icon(
                            onPressed: _create,
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: const Text('新窗口'),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.signalInk,
                              backgroundColor: AppColors.signal,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      '左滑卡片关闭 · 点卡片切过去',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.faint,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.74,
                  ),
                  itemCount: windows.length,
                  itemBuilder: (_, index) => _card(
                    windows[index],
                    current: index == _indexOfActive(windows),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The store owns which window is on screen; the list here is a snapshot.
  int _indexOfActive(List<BrowseWindow> windows) {
    final current = widget.store.current;
    for (var i = 0; i < windows.length; i++) {
      if (identical(windows[i], current)) return i;
    }
    return -1;
  }

  /// One card in the grid, swipeable away.
  ///
  /// The drag is the answer to the corner ✕ being a 22 px bullseye: the whole
  /// card is the target now, and it only reacts to a horizontal pull, so the
  /// grid still scrolls vertically under the same finger.
  Widget _card(BrowseWindow window, {required bool current}) => Dismissible(
    key: ValueKey<int>(window.number),
    direction: DismissDirection.endToStart,
    dismissThresholds: const <DismissDirection, double>{
      DismissDirection.endToStart: 0.4,
    },
    background: const _DeleteBackdrop(),
    onDismissed: (_) => _close(window),
    child: _cardBody(window, current: current),
  );

  Widget _cardBody(BrowseWindow window, {required bool current}) {
    final thumbnail = window.thumbnail;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _pick(window),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: current ? AppColors.ink : AppColors.line,
              width: current ? 1.6 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: <Widget>[
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (thumbnail == null)
                      Container(
                        color: AppColors.wash,
                        alignment: Alignment.center,
                        child: Text(
                          window.isBlank ? '＋' : window.initial,
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w600,
                            color: current
                                ? AppColors.ink.withAlpha(140)
                                : AppColors.faint,
                          ),
                        ),
                      )
                    else
                      Image.memory(
                        thumbnail,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: _CloseButton(onTap: () => _close(window)),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
                color: AppColors.card,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      window.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      current
                          ? '当前窗口 · ${window.detail}'
                          : window.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
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

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.ink.withAlpha(190),
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: const SizedBox(
            width: 30,
            height: 30,
            child: Icon(Icons.close_rounded, size: 17, color: AppColors.onInk),
          ),
        ),
      );
}

/// What a swipe reveals: the window is going away, so it says so in the corner
/// the card is travelling out of.
class _DeleteBackdrop extends StatelessWidget {
  const _DeleteBackdrop();

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.danger.withAlpha(34),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.danger.withAlpha(110)),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '关闭',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.danger,
              ),
            ),
            SizedBox(width: 6),
            Icon(Icons.delete_outline_rounded, size: 19, color: AppColors.danger),
          ],
        ),
      );
}
