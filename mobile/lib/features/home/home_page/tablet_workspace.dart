part of '../home_page.dart';

const double _tabletSidebarDefaultWidth = 300;
const double _tabletSidebarMinWidth = 260;
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

/// Persistent workspace destinations. [_kWorkspaceChannel] shows the channel
/// selected in the sidebar; the others are the sidebar's top-level rows.
const int _kWorkspaceChannel = 0;
const int _kWorkspaceInbox = 1;
const int _kWorkspaceSearch = 2;
const int _kWorkspaceSolo = 3;

class _TabletWorkspace extends StatelessWidget {
  const _TabletWorkspace({
    required this.settingsPageBuilder,
    required this.communityInvitePageBuilder,
    required this.communityAppearancePageBuilder,
    required this.mePageBuilder,
    required this.newChatAction,
    required this.hasUnreadInbox,
    required this.hasUnreadSolo,
    required this.selectedDestination,
    required this.selectedChannel,
    required this.selectedThread,
    required this.settingsTransitionProgress,
    required this.onDestinationSelected,
    required this.onChannelSelected,
    required this.onThreadSelected,
    required this.onThreadClosed,
    required this.onCommunityChanged,
    required this.onSelectedChannelUnavailable,
    required this.sidebarCollapsed,
    required this.onSidebarCollapsedChanged,
    required this.threadExpanded,
    required this.onThreadExpandedChanged,
  });

  final WidgetBuilder settingsPageBuilder;
  final WidgetBuilder? communityInvitePageBuilder;
  final WidgetBuilder? communityAppearancePageBuilder;
  final Widget Function(BuildContext, ValueNotifier<VoidCallback?>)?
  mePageBuilder;
  final ValueNotifier<VoidCallback?> newChatAction;
  final bool hasUnreadInbox;
  final bool hasUnreadSolo;
  final int selectedDestination;
  final Channel? selectedChannel;
  final ThreadDetailTarget? selectedThread;
  final ValueNotifier<double> settingsTransitionProgress;
  final ValueChanged<int> onDestinationSelected;
  final ValueChanged<Channel> onChannelSelected;
  final ValueChanged<ThreadDetailTarget> onThreadSelected;
  final VoidCallback onThreadClosed;
  final ValueChanged<String?> onCommunityChanged;
  final VoidCallback onSelectedChannelUnavailable;

  /// Whether the sidebar is reduced to the compact rail.
  final bool sidebarCollapsed;
  final ValueChanged<bool> onSidebarCollapsedChanged;

  /// Whether the open thread fills the whole window.
  final bool threadExpanded;
  final ValueChanged<bool> onThreadExpandedChanged;

  @override
  Widget build(BuildContext context) {
    final gradient = context.appColors.topSectionGradient;
    final channel = selectedDestination == _kWorkspaceChannel
        ? selectedChannel
        : null;
    final destination = channel != null
        ? _kWorkspaceChannel
        : selectedDestination == _kWorkspaceChannel
        ? _kWorkspaceInbox
        : selectedDestination;
    final mePageBuilder = this.mePageBuilder;
    final Widget page = switch (destination) {
      _kWorkspaceChannel => ChannelDetailPage(
        channel: channel!,
        placement: ChannelRoutePlacement.ordinary,
      ),
      _kWorkspaceSearch => const SearchPage(showCloseButton: false),
      _kWorkspaceSolo when mePageBuilder != null => mePageBuilder(
        context,
        newChatAction,
      ),
      _ => const ActivityPage(splitView: true),
    };
    final contentNavigator = _TabletContentNavigator(
      key: ValueKey('tablet-content-$destination-${channel?.id}'),
      child: page,
    );
    // Threads opened from a channel belong to the workspace: beside the
    // conversation when there is room, over it otherwise.
    final content = channel != null
        ? ThreadDetailPaneScope(
            onOpenThread: onThreadSelected,
            child: contentNavigator,
          )
        : contentNavigator;
    final thread = channel == null ? null : selectedThread;

    final sidebar = Stack(
      fit: StackFit.expand,
      children: [
        MediaQuery(
          // Keep the last channel rows clear of the quick actions.
          data: _mediaQueryWithFloatingTabBarClearance(
            context,
            HomePage._fabClearance,
          ),
          child: ChannelsPage(
            settingsPageBuilder: settingsPageBuilder,
            communityInvitePageBuilder: communityInvitePageBuilder,
            communityAppearancePageBuilder: communityAppearancePageBuilder,
            onSettingsTransitionProgress: (progress) {
              if (settingsTransitionProgress.value != progress) {
                settingsTransitionProgress.value = progress;
              }
            },
            selectedChannelId: channel?.id,
            onChannelSelected: onChannelSelected,
            onCommunityChanged: onCommunityChanged,
            onSelectedChannelUnavailable: onSelectedChannelUnavailable,
            onHideSidebar: () => onSidebarCollapsedChanged(true),
            workspaceHeader: _TabletWorkspaceDestinations(
              selectedDestination: destination,
              hasUnreadInbox: hasUnreadInbox,
              hasUnreadSolo: hasUnreadSolo,
              showsSolo: mePageBuilder != null,
              onDestinationSelected: onDestinationSelected,
            ),
          ),
        ),
        ValueListenableBuilder<VoidCallback?>(
          valueListenable: newChatAction,
          builder: (context, onNewChat, _) => ChannelQuickActionsLauncher(
            key: const ValueKey('tablet-quick-actions'),
            visible: true,
            newChatMode: destination == _kWorkspaceSolo,
            onNewChat: onNewChat,
            navigationBarHeight: HomePage._tabBarHeight,
            navigationBarBottomGap: HomePage._tabBarBottomGap,
            navigationBarWidth: 0,
            navigationBarLeft: 0,
            systemBottomInset: MediaQuery.viewPaddingOf(context).bottom,
            rightInset: Grid.gutter,
            onOpenChannel: onChannelSelected,
          ),
        ),
      ],
    );

    return Scaffold(
      key: const ValueKey('tablet-workspace'),
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: gradient == null
              ? context.colors.surfaceContainerLowest
              : null,
          gradient: gradient,
        ),
        child: _WorkspacePanes(
          sidebar: sidebar,
          rail: _TabletWorkspaceRail(
            selectedDestination: destination,
            hasUnreadInbox: hasUnreadInbox,
            hasUnreadSolo: hasUnreadSolo,
            showsSolo: mePageBuilder != null,
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

class _TabletWorkspaceDestinations extends StatelessWidget {
  const _TabletWorkspaceDestinations({
    required this.selectedDestination,
    required this.hasUnreadInbox,
    required this.hasUnreadSolo,
    required this.showsSolo,
    required this.onDestinationSelected,
  });

  final int selectedDestination;
  final bool hasUnreadInbox;
  final bool hasUnreadSolo;
  final bool showsSolo;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Grid.xxs,
        Grid.xxs,
        Grid.xxs,
        Grid.half,
      ),
      child: Column(
        children: [
          _TabletWorkspaceDestination(
            icon: BuzzIcons.inbox300,
            selectedIcon: BuzzIcons.inbox500,
            label: 'Inbox',
            selected: selectedDestination == _kWorkspaceInbox,
            showBadge: hasUnreadInbox,
            onTap: () => onDestinationSelected(_kWorkspaceInbox),
          ),
          _TabletWorkspaceDestination(
            icon: BuzzIcons.search300,
            selectedIcon: BuzzIcons.search500,
            label: 'Search',
            selected: selectedDestination == _kWorkspaceSearch,
            onTap: () => onDestinationSelected(_kWorkspaceSearch),
          ),
          if (showsSolo)
            _TabletWorkspaceDestination(
              icon: BuzzIcons.messageSquare,
              selectedIcon: BuzzIcons.messageSquare,
              label: 'Solo',
              selected: selectedDestination == _kWorkspaceSolo,
              showBadge: hasUnreadSolo,
              onTap: () => onDestinationSelected(_kWorkspaceSolo),
            ),
          Divider(
            height: Grid.xs,
            color: navigationSecondaryForeground(
              context,
            ).withValues(alpha: 0.16),
          ),
        ],
      ),
    );
  }
}

class _TabletWorkspaceDestination extends StatelessWidget {
  const _TabletWorkspaceDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.showBadge = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    final foreground = navigationPrimaryForeground(context);
    return Semantics(
      selected: selected,
      button: true,
      label: showBadge && !selected ? '$label, unread' : label,
      excludeSemantics: true,
      child: Material(
        color: selected
            ? context.colors.primaryContainer.withValues(alpha: 0.72)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          key: ValueKey('tablet-workspace-${label.toLowerCase()}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Grid.gutter),
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(
                        selected ? selectedIcon : icon,
                        size: 20,
                        color: foreground,
                      ),
                      if (showBadge)
                        Positioned(
                          top: -2,
                          right: -3,
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: context.colors.primary,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: context.colors.surface,
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: Grid.twelve),
                  Text(
                    label,
                    style: context.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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
}

/// Compact sidebar: show-sidebar control plus the top-level destinations.
class _TabletWorkspaceRail extends StatelessWidget {
  const _TabletWorkspaceRail({
    required this.selectedDestination,
    required this.hasUnreadInbox,
    required this.hasUnreadSolo,
    required this.showsSolo,
    required this.onDestinationSelected,
    required this.onShowSidebar,
  });

  final int selectedDestination;
  final bool hasUnreadInbox;
  final bool hasUnreadSolo;
  final bool showsSolo;
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
              showBadge: hasUnreadInbox,
              onTap: () => onDestinationSelected(_kWorkspaceInbox),
            ),
            _TabletRailButton(
              key: const ValueKey('tablet-rail-search'),
              icon: BuzzIcons.search300,
              label: 'Search',
              selected: selectedDestination == _kWorkspaceSearch,
              onTap: () => onDestinationSelected(_kWorkspaceSearch),
            ),
            if (showsSolo)
              _TabletRailButton(
                key: const ValueKey('tablet-rail-solo'),
                icon: BuzzIcons.messageSquare,
                label: 'Solo',
                selected: selectedDestination == _kWorkspaceSolo,
                showBadge: hasUnreadSolo,
                onTap: () => onDestinationSelected(_kWorkspaceSolo),
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
    this.showBadge = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Grid.half),
      child: Semantics(
        button: true,
        selected: selected,
        label: showBadge && !selected ? '$label, unread' : label,
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
                    if (showBadge)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: context.colors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
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
