part of '../home_page.dart';

const double _tabletSidebarDefaultWidth = 320;
const double _tabletSidebarMinWidth = 280;
const double _tabletSidebarMaxWidth = 480;
const double _tabletRailWidth = 68;
const double _tabletThreadDefaultWidth = 380;
const double _tabletThreadMinWidth = 300;

/// Narrowest the conversation beside a thread pane may become. Below this the
/// thread covers the conversation instead of sitting beside it.
const double _tabletChannelMinWidth = 360;

/// Content width kept free when no thread is open.
const double _tabletContentMinWidth = 400;
const double _tabletResizeHandleWidth = 14;

const _kTabletSidebarWidthPref = 'tablet_workspace.sidebar_width';
const _kTabletThreadWidthPref = 'tablet_workspace.thread_width';
const _kTabletSidebarCollapsedPref = 'tablet_workspace.sidebar_collapsed';

/// Tablet layout preferences survive relaunches; tests without stored
/// preferences fall back to defaults.
SharedPreferences? _tabletPrefs(WidgetRef ref) {
  try {
    return ref.read(savedPrefsProvider);
  } catch (_) {
    return null;
  }
}

/// What the content pane shows. [_kWorkspaceChannel] is the conversation
/// picked in the sidebar (a channel, DM or Solo chat); Inbox and Search are
/// the sidebar's Inbox row and the Search button of its bottom bar.
const int _kWorkspaceChannel = 0;
const int _kWorkspaceInbox = 1;
const int _kWorkspaceSearch = 2;

/// Persistent iPad layout: the Messages list in a resizable, collapsible
/// sidebar; the selected conversation, Inbox or Search beside it; and threads
/// in a third pane (or over the conversation when the window is narrow).
class _TabletWorkspace extends StatelessWidget {
  const _TabletWorkspace({
    required this.sidebar,
    required this.selectedDestination,
    required this.selectedChannel,
    required this.selectedThread,
    required this.onDestinationSelected,
    required this.onThreadSelected,
    required this.onThreadClosed,
    required this.sidebarCollapsed,
    required this.onSidebarCollapsedChanged,
    required this.threadExpanded,
    required this.onThreadExpandedChanged,
  });

  /// The Messages page with its bottom bar, built by [HomePage].
  final Widget sidebar;
  final int selectedDestination;
  final ChannelWorkspaceTarget? selectedChannel;
  final ThreadDetailTarget? selectedThread;
  final ValueChanged<int> onDestinationSelected;
  final ValueChanged<ThreadDetailTarget> onThreadSelected;
  final VoidCallback onThreadClosed;

  /// Whether the sidebar is reduced to the compact rail.
  final bool sidebarCollapsed;
  final ValueChanged<bool> onSidebarCollapsedChanged;

  /// Whether the open thread fills the whole window.
  final bool threadExpanded;
  final ValueChanged<bool> onThreadExpandedChanged;

  @override
  Widget build(BuildContext context) {
    final gradient = context.appColors.topSectionGradient;
    final target = selectedDestination == _kWorkspaceChannel
        ? selectedChannel
        : null;
    final destination = target != null
        ? _kWorkspaceChannel
        : selectedDestination == _kWorkspaceChannel
        ? _kWorkspaceInbox
        : selectedDestination;
    final Widget page = switch (destination) {
      _kWorkspaceChannel => ChannelDetailPage(
        channel: target!.channel,
        personalChat: target.personalChat,
        initialAssistant: target.initialAssistant,
        placement: target.placement,
      ),
      _kWorkspaceSearch => const SearchPage(embedded: true),
      _ => const ActivityPage(splitView: true),
    };
    final contentNavigator = _TabletContentNavigator(
      key: ValueKey('tablet-content-$destination-${target?.channel.id}'),
      child: page,
    );
    // Threads opened from a conversation belong to the workspace: beside it
    // when there is room, over it otherwise.
    final content = target != null
        ? ThreadDetailPaneScope(
            onOpenThread: onThreadSelected,
            child: contentNavigator,
          )
        : contentNavigator;
    final thread = target == null ? null : selectedThread;

    return Scaffold(
      key: const ValueKey('tablet-workspace'),
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: gradient == null ? context.colors.surface : null,
          gradient: gradient,
        ),
        child: _WorkspacePanes(
          sidebar: sidebar,
          rail: _TabletWorkspaceRail(
            selectedDestination: destination,
            onDestinationSelected: onDestinationSelected,
            onShowSidebar: () => onSidebarCollapsedChanged(false),
          ),
          content: content,
          thread: thread == null
              ? null
              : ThreadDetailPaneScope(
                  // Nested threads replace the pane's thread instead of
                  // covering the whole workspace.
                  onOpenThread: onThreadSelected,
                  child: ThreadDetailPage.fromTarget(
                    thread,
                    key: ValueKey('tablet-thread-${thread.threadHead.id}'),
                    onClose: onThreadClosed,
                    expanded: threadExpanded,
                    onToggleExpanded: () =>
                        onThreadExpandedChanged(!threadExpanded),
                  ),
                ),
          sidebarCollapsed: sidebarCollapsed,
          threadExpanded: threadExpanded,
        ),
      ),
    );
  }
}

/// Header button that reduces the sidebar to the compact rail.
class _HideSidebarButton extends StatelessWidget {
  const _HideSidebarButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 44,
      child: IconButton(
        key: const ValueKey('hide-sidebar'),
        tooltip: 'Hide sidebar',
        onPressed: onPressed,
        color: navigationPrimaryForeground(context),
        icon: const Icon(BuzzIcons.layoutSidebar, size: 22),
      ),
    );
  }
}

/// Lays out sidebar (or rail), content and thread, with drag handles on the
/// sidebar edge and the thread edge. Pane widths persist across launches.
///
/// Children are built once by the caller, so dragging a handle only re-lays
/// out the panes instead of rebuilding them. Hidden panes stay mounted
/// offstage, so scroll positions, drafts and nested routes survive collapsing
/// the sidebar or expanding the thread.
class _WorkspacePanes extends HookConsumerWidget {
  const _WorkspacePanes({
    required this.sidebar,
    required this.rail,
    required this.content,
    required this.thread,
    required this.sidebarCollapsed,
    required this.threadExpanded,
  });

  final Widget sidebar;
  final Widget rail;
  final Widget content;
  final Widget? thread;
  final bool sidebarCollapsed;
  final bool threadExpanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = _tabletPrefs(ref);
    final sidebarWidth = useState(
      prefs?.getDouble(_kTabletSidebarWidthPref) ?? _tabletSidebarDefaultWidth,
    );
    final threadWidth = useState(
      prefs?.getDouble(_kTabletThreadWidthPref) ?? _tabletThreadDefaultWidth,
    );
    final borderColor = context.colors.outlineVariant.withValues(alpha: 0.45);

    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        final threadOpen = thread != null;
        final threadFullScreen = threadOpen && threadExpanded;
        final sidebarHidden = sidebarCollapsed || threadFullScreen;
        final reservedContent = threadOpen
            ? _tabletChannelMinWidth + _tabletThreadMinWidth
            : _tabletContentMinWidth;
        final sidebarMax = math.max(
          _tabletSidebarMinWidth,
          math.min(_tabletSidebarMaxWidth, total - reservedContent),
        );
        final sidebarW = sidebarWidth.value
            .clamp(_tabletSidebarMinWidth, sidebarMax)
            .toDouble();
        final leftW = sidebarHidden
            ? (threadFullScreen ? 0.0 : _tabletRailWidth)
            : sidebarW;
        final contentW = total - leftW;
        // Beside the conversation when both fit, otherwise over it.
        final threadBeside =
            threadOpen &&
            !threadFullScreen &&
            contentW >= _tabletChannelMinWidth + _tabletThreadMinWidth;
        final threadMax = math.max(
          _tabletThreadMinWidth,
          contentW - _tabletChannelMinWidth,
        );
        final threadW = threadWidth.value
            .clamp(_tabletThreadMinWidth, threadMax)
            .toDouble();
        final threadCovers = threadOpen && !threadBeside;

        void persist(String key, double value) =>
            unawaited(prefs?.setDouble(key, value));

        return Row(
          children: [
            Offstage(
              key: const ValueKey('tablet-workspace-sidebar-slot'),
              offstage: sidebarHidden,
              child: SizedBox(
                key: const ValueKey('tablet-workspace-sidebar'),
                width: sidebarW,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    sidebar,
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: _tabletResizeHandleWidth,
                      child: _PaneResizeHandle(
                        key: const ValueKey('tablet-sidebar-resize'),
                        label: 'Resize sidebar',
                        grabberAlignment: Alignment.centerRight,
                        onDrag: (dx) => sidebarWidth.value =
                            (sidebarWidth.value.clamp(
                                      _tabletSidebarMinWidth,
                                      sidebarMax,
                                    ) +
                                    dx)
                                .clamp(_tabletSidebarMinWidth, sidebarMax)
                                .toDouble(),
                        onDragEnd: () => persist(
                          _kTabletSidebarWidthPref,
                          sidebarWidth.value,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (sidebarHidden && !threadFullScreen) rail,
            Expanded(
              child: DecoratedBox(
                key: const ValueKey('tablet-workspace-content-surface'),
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  border: Border(
                    left: threadFullScreen
                        ? BorderSide.none
                        : BorderSide(color: borderColor),
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      right: threadBeside ? threadW : 0,
                      child: Offstage(offstage: threadCovers, child: content),
                    ),
                    if (threadOpen)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        left: threadBeside ? null : 0,
                        width: threadBeside ? threadW : null,
                        child: DecoratedBox(
                          key: const ValueKey('tablet-thread-pane'),
                          decoration: BoxDecoration(
                            color: context.colors.surface,
                            border: Border(
                              left: threadBeside
                                  ? BorderSide(color: borderColor)
                                  : BorderSide.none,
                            ),
                          ),
                          child: thread,
                        ),
                      ),
                    if (threadBeside)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: threadW - _tabletResizeHandleWidth,
                        width: _tabletResizeHandleWidth,
                        child: _PaneResizeHandle(
                          key: const ValueKey('tablet-thread-resize'),
                          label: 'Resize thread',
                          grabberAlignment: Alignment.centerLeft,
                          onDrag: (dx) => threadWidth.value =
                              (threadWidth.value.clamp(
                                        _tabletThreadMinWidth,
                                        threadMax,
                                      ) -
                                      dx)
                                  .clamp(_tabletThreadMinWidth, threadMax)
                                  .toDouble(),
                          onDragEnd: () => persist(
                            _kTabletThreadWidthPref,
                            threadWidth.value,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Horizontal drag strip on a pane edge, with a small grabber on the border.
///
/// Only horizontal drags are claimed, so taps and vertical scrolling still
/// reach the pane underneath.
class _PaneResizeHandle extends HookWidget {
  const _PaneResizeHandle({
    required this.label,
    required this.grabberAlignment,
    required this.onDrag,
    required this.onDragEnd,
    super.key,
  });

  final String label;
  final Alignment grabberAlignment;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final dragging = useState(false);
    void end() {
      if (!dragging.value) return;
      dragging.value = false;
      onDragEnd();
    }

    return Semantics(
      label: label,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          // Follow the finger from touch-down, including the drag slop.
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: (_) {
            dragging.value = true;
            unawaited(HapticFeedback.selectionClick());
          },
          onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
          onHorizontalDragEnd: (_) => end(),
          onHorizontalDragCancel: end,
          child: Align(
            alignment: grabberAlignment,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: dragging.value ? 6 : 4,
              height: dragging.value ? 56 : 36,
              decoration: BoxDecoration(
                color: dragging.value
                    ? context.colors.primary
                    : context.colors.outlineVariant.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(Radii.full),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hosts a workspace destination in its own navigator, so the routes it opens
/// (channel info, Solo chats, search results) stay beside the sidebar instead
/// of covering the whole window.
class _TabletContentNavigator extends HookWidget {
  const _TabletContentNavigator({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final navigatorKey = useMemoized(GlobalKey<NavigatorState>.new);
    final observer = useMemoized(NestedNavigatorRouteObserver.new);
    // A route's modal barrier carries BlockSemantics, which would otherwise
    // hide the sidebar painted before this pane from assistive technologies.
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: NavigatorPopHandler(
        onPopWithResult: (_) => navigatorKey.currentState?.maybePop(),
        child: Navigator(
          key: navigatorKey,
          observers: [observer],
          onGenerateRoute: (_) => PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => child,
          ),
        ),
      ),
    );
  }
}

/// Compact sidebar: show-sidebar control plus Inbox and Search.
class _TabletWorkspaceRail extends StatelessWidget {
  const _TabletWorkspaceRail({
    required this.selectedDestination,
    required this.onDestinationSelected,
    required this.onShowSidebar,
  });

  final int selectedDestination;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onShowSidebar;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('tablet-workspace-rail'),
      width: _tabletRailWidth,
      child: Padding(
        padding: EdgeInsets.only(
          top: MediaQuery.viewPaddingOf(context).top + Grid.xxs,
        ),
        child: Column(
          children: [
            _TabletRailButton(
              key: const ValueKey('tablet-show-sidebar'),
              icon: BuzzIcons.layoutSidebar,
              label: 'Show sidebar',
              onTap: onShowSidebar,
            ),
            const SizedBox(height: Grid.sm),
            _TabletRailButton(
              key: const ValueKey('tablet-rail-inbox'),
              icon: BuzzIcons.inbox300,
              label: 'Inbox',
              selected: selectedDestination == _kWorkspaceInbox,
              onTap: () => onDestinationSelected(_kWorkspaceInbox),
            ),
            _TabletRailButton(
              key: const ValueKey('tablet-rail-search'),
              icon: BuzzIcons.search300,
              label: 'Search',
              selected: selectedDestination == _kWorkspaceSearch,
              onTap: () => onDestinationSelected(_kWorkspaceSearch),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabletRailButton extends StatelessWidget {
  const _TabletRailButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Grid.half),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: Material(
            color: selected
                ? context.colors.primaryContainer.withValues(alpha: 0.72)
                : context.controlSurface,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox.square(
                dimension: 44,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      icon,
                      size: 20,
                      color: navigationPrimaryForeground(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
