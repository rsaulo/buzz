part of '../home_page.dart';

const double _tabletSidebarWidth = 300;
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
            SizedBox(
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
            Expanded(
              child: DecoratedBox(
                key: const ValueKey('tablet-workspace-content-surface'),
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  border: Border(
                    left: BorderSide(
                      color: context.colors.outlineVariant.withValues(
                        alpha: 0.45,
                      ),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(child: content),
                    if (showsThreadPane && selectedThread != null) ...[
                      VerticalDivider(
                        key: const ValueKey('tablet-thread-divider'),
                        width: 1,
                        thickness: 1,
                        color: context.colors.outlineVariant.withValues(
                          alpha: 0.45,
                        ),
                      ),
                      SizedBox(
                        key: const ValueKey('tablet-thread-pane'),
                        width: _tabletThreadPaneWidth,
                        // Nested threads replace the pane's thread instead of
                        // covering the whole workspace.
                        child: ThreadDetailPaneScope(
                          onOpenThread: onThreadSelected,
                          child: ThreadDetailPage.fromTarget(
                            selectedThread!,
                            key: ValueKey(
                              'tablet-thread-${selectedThread!.threadHead.id}',
                            ),
                            onClose: onThreadClosed,
                          ),
                        ),
                      ),
                    ],
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

/// Hosts a workspace destination in its own navigator, so the routes it opens
/// (channel info, Solo chats, search results, phone-width threads) stay
/// beside the sidebar instead of covering the whole window.
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
