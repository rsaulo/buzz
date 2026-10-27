part of '../home_page.dart';

const double _tabletSidebarWidth = 300;
const double _tabletRailWidth = 68;
const double _tabletThreadPaneWidth = 380;

/// Window width at which a selected channel keeps its thread in a third pane.
///
/// Narrower workspaces (iPad portrait, Split View) open threads inside the
/// content pane instead, so the conversation never shrinks below phone width.
const double _tabletThreePaneMinWidth = 1100;

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
    final showsThreadPane =
        channel != null &&
        MediaQuery.sizeOf(context).width >= _tabletThreePaneMinWidth;
    final threadVisible = showsThreadPane && selectedThread != null;
    final threadFullScreen = threadVisible && threadExpanded;
    final contentNavigator = _TabletContentNavigator(
      key: ValueKey('tablet-content-$destination-${channel?.id}'),
      child: page,
    );
    final content = showsThreadPane
        ? ThreadDetailPaneScope(
            onOpenThread: onThreadSelected,
            child: contentNavigator,
          )
        : contentNavigator;

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
        child: Row(
          children: [
            // Hidden panes stay mounted offstage so scroll positions, drafts
            // and nested routes survive collapsing and expanding.
            Offstage(
              key: const ValueKey('tablet-workspace-sidebar-slot'),
              offstage: sidebarCollapsed || threadFullScreen,
              child: SizedBox(
                key: const ValueKey('tablet-workspace-sidebar'),
                width: _tabletSidebarWidth,
                child: Stack(
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
                        communityAppearancePageBuilder:
                            communityAppearancePageBuilder,
                        onSettingsTransitionProgress: (progress) {
                          if (settingsTransitionProgress.value != progress) {
                            settingsTransitionProgress.value = progress;
                          }
                        },
                        selectedChannelId: channel?.id,
                        onChannelSelected: onChannelSelected,
                        onCommunityChanged: onCommunityChanged,
                        onSelectedChannelUnavailable:
                            onSelectedChannelUnavailable,
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
                      builder: (context, onNewChat, _) =>
                          ChannelQuickActionsLauncher(
                            key: const ValueKey('tablet-quick-actions'),
                            visible: true,
                            newChatMode: destination == _kWorkspaceSolo,
                            onNewChat: onNewChat,
                            navigationBarHeight: HomePage._tabBarHeight,
                            navigationBarBottomGap: HomePage._tabBarBottomGap,
                            navigationBarWidth: 0,
                            navigationBarLeft: 0,
                            systemBottomInset: MediaQuery.viewPaddingOf(
                              context,
                            ).bottom,
                            rightInset: Grid.gutter,
                            onOpenChannel: onChannelSelected,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            if (sidebarCollapsed && !threadFullScreen)
              _TabletWorkspaceRail(
                selectedDestination: destination,
                hasUnreadInbox: hasUnreadInbox,
                hasUnreadSolo: hasUnreadSolo,
                showsSolo: mePageBuilder != null,
                onDestinationSelected: onDestinationSelected,
                onShowSidebar: () => onSidebarCollapsedChanged(false),
              ),
            Expanded(
              child: DecoratedBox(
                key: const ValueKey('tablet-workspace-content-surface'),
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  border: Border(
                    left: threadFullScreen
                        ? BorderSide.none
                        : BorderSide(
                            color: context.colors.outlineVariant.withValues(
                              alpha: 0.45,
                            ),
                          ),
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      right: threadVisible && !threadFullScreen
                          ? _tabletThreadPaneWidth
                          : 0,
                      child: Offstage(
                        offstage: threadFullScreen,
                        child: content,
                      ),
                    ),
                    if (threadVisible)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        left: threadFullScreen ? 0 : null,
                        width: threadFullScreen ? null : _tabletThreadPaneWidth,
                        child: DecoratedBox(
                          key: const ValueKey('tablet-thread-pane'),
                          decoration: BoxDecoration(
                            color: context.colors.surface,
                            border: Border(
                              left: threadFullScreen
                                  ? BorderSide.none
                                  : BorderSide(
                                      color: context.colors.outlineVariant
                                          .withValues(alpha: 0.45),
                                    ),
                            ),
                          ),
                          // Nested threads replace the pane's thread instead
                          // of covering the whole workspace.
                          child: ThreadDetailPaneScope(
                            onOpenThread: onThreadSelected,
                            child: ThreadDetailPage.fromTarget(
                              selectedThread!,
                              key: ValueKey(
                                'tablet-thread-${selectedThread!.threadHead.id}',
                              ),
                              onClose: onThreadClosed,
                              expanded: threadFullScreen,
                              onToggleExpanded: () =>
                                  onThreadExpandedChanged(!threadExpanded),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
              icon: CupertinoIcons.sidebar_left,
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
