import '../../shared/widgets/android_expanding_menu_button.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/theme/buzz_icons.dart';
import '../../shared/theme/theme.dart';
import '../../shared/community/community_membership_provider.dart';
import '../../shared/community/community_provider.dart';
import '../../shared/community/community_icon_provider.dart';
import '../../shared/community/community_avatar.dart';
import '../../shared/widgets/ios_message_create_button.dart';
import '../../shared/widgets/bottom_up_page_route.dart';
import '../../shared/widgets/mobile_tab_footer_backdrop.dart';
import '../../shared/utils/adaptive_layout.dart';
import '../../shared/widgets/app_route_observer.dart';
import '../activity/activity_page.dart';
import '../channels/channel_detail_page.dart';
import '../channels/channel_workspace_scope.dart';
import '../channels/channels_page.dart';
import '../channels/channels_provider.dart';
import '../channels/thread_detail_page.dart';
import '../channels/thread_detail_target.dart';
import '../search/search_page.dart';
import 'messages_filters.dart';
import 'messages_navigation_bar.dart';

part 'home_page/tablet_workspace.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({
    required this.settingsPageBuilder,
    required this.onAgents,
    required this.defaultAgentBuilder,
    this.communityInvitePageBuilder,
    this.mePageBuilder,
    this.communityAppearancePageBuilder,
    super.key,
  });

  final WidgetBuilder settingsPageBuilder;
  final ValueChanged<BuildContext> onAgents;
  final WidgetBuilder defaultAgentBuilder;

  /// Builds a sliver inventory and publishes its two creation actions.
  final Widget Function(
    BuildContext,
    ValueNotifier<VoidCallback?>,
    ValueNotifier<VoidCallback?>,
  )?
  mePageBuilder;
  final WidgetBuilder? communityInvitePageBuilder;
  final WidgetBuilder? communityAppearancePageBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ModalRoute.of(context);
    final coveringProgress = useAnimation(
      route?.secondaryAnimation ?? kAlwaysDismissedAnimation,
    );
    final nativeControlsVisible =
        (route?.isCurrent ?? true) && coveringProgress == 0;

    final communitySurfaceProgress = useState(0.0);
    final filter = useState('All');
    final reselect = useValueNotifier(0);
    final newChat = useValueNotifier<VoidCallback?>(null);
    final newWorkspace = useValueNotifier<VoidCallback?>(null);
    final newChannel = useValueNotifier<VoidCallback?>(null);
    final newDm = useValueNotifier<VoidCallback?>(null);
    useListenable(newChat);
    useListenable(newWorkspace);
    useListenable(newChannel);
    useListenable(newDm);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    // iPad workspace (RSLabs fork): what the content pane shows, and the
    // conversation a phone route remembers so the workspace can take it over
    // when the window grows.
    final windowSize = MediaQuery.sizeOf(context);
    final tablet = usesTabletWorkspace(
      width: windowSize.width,
      height: windowSize.height,
    );
    final workspaceDestination = useState(_kWorkspaceInbox);
    final workspaceChannel = useState<ChannelWorkspaceTarget?>(null);
    final workspaceThread = useState<ThreadDetailTarget?>(null);
    final workspaceThreadExpanded = useState(false);
    final workspaceSidebarCollapsed = useState(
      _tabletPrefs(ref)?.getBool(_kTabletSidebarCollapsedPref) ?? false,
    );
    void showInWorkspace(int destination, [ChannelWorkspaceTarget? channel]) {
      workspaceChannel.value = channel;
      workspaceThread.value = null;
      workspaceThreadExpanded.value = false;
      workspaceDestination.value = destination;
    }

    final workspaceCommunityId = ref.watch(
      activeCommunityProvider.select((v) => v.unwrapPrevious().value?.id),
    );
    useEffect(() {
      // A conversation of the previous community is not in this one.
      showInWorkspace(_kWorkspaceInbox);
      return null;
    }, [workspaceCommunityId]);
    final selectedWorkspaceChannelId = workspaceChannel.value?.channel.id;
    final selectedWorkspaceChannelGone = ref.watch(
      channelsProvider.select((async) {
        final channels = async.asData?.value;
        if (selectedWorkspaceChannelId == null || channels == null) {
          return false;
        }
        return !channels.any(
          (c) =>
              c.id == selectedWorkspaceChannelId && c.isMember && !c.isArchived,
        );
      }),
    );
    useEffect(() {
      if (selectedWorkspaceChannelGone) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) showInWorkspace(_kWorkspaceInbox);
        });
      }
      return null;
    }, [selectedWorkspaceChannelGone]);

    void openSearch() => Navigator.of(context).push(
      BottomUpPageRoute<void>(
        builder: (_) => const SearchPage(),
        reducedMotion: reducedMotion,
      ),
    );
    void openSettings() => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: settingsPageBuilder));
    final community = ref.watch(activeCommunityProvider).unwrapPrevious().value;
    final communityName = community?.name.trim() ?? '';
    final communityIcon = community == null
        ? null
        : ref.watch(communityIconPresentationProvider(community.relayUrl));
    final role = ref.watch(currentCommunityRoleProvider).unwrapPrevious();
    final canInvite = role.hasError || canManageCommunityInvites(role.value);
    void openPage(WidgetBuilder builder) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));
    final solo = mePageBuilder?.call(context, newChat, newWorkspace);
    final messages = ChannelsPage(
      settingsPageBuilder: settingsPageBuilder,
      onInbox: tablet
          ? () {
              unawaited(HapticFeedback.selectionClick());
              showInWorkspace(_kWorkspaceInbox);
            }
          : () => Navigator.of(context).push(
              BottomUpPageRoute<void>(
                builder: (_) => const ActivityPage(),
                reducedMotion: reducedMotion,
              ),
            ),
      messagesActionsBuilder: (openSwitcher, avatarKey) {
        final moreActions = [
          (
            label: 'Switch community',
            symbol: 'arrow.left.arrow.right',
            onPressed: openSwitcher,
          ),
          if (canInvite && communityInvitePageBuilder != null)
            (
              label: 'Invite',
              symbol: 'person.badge.plus',
              onPressed: () => openPage(communityInvitePageBuilder!),
            ),
          (
            label: 'Agents',
            symbol: 'agent',
            onPressed: () => onAgents(context),
          ),
          if (communityAppearancePageBuilder != null)
            (
              label: 'Appearance',
              symbol: 'circle.lefthalf.filled',
              onPressed: () => openPage(communityAppearancePageBuilder!),
            ),
          (label: 'Settings', symbol: 'gearshape', onPressed: openSettings),
        ];
        return [
          if (tablet)
            _HideSidebarButton(
              onPressed: () {
                unawaited(HapticFeedback.selectionClick());
                workspaceSidebarCollapsed.value = true;
                unawaited(
                  _tabletPrefs(
                    ref,
                  )?.setBool(_kTabletSidebarCollapsedPref, true),
                );
              },
            ),
          SizedBox(
            key: avatarKey,
            child: defaultTargetPlatform == TargetPlatform.iOS
                ? IosMessageCreateButton(
                    actions: moreActions,
                    dividerBefore: const {1},
                    icon: 'more',
                    avatarUrl: communityIcon,
                    avatarInitial: communityName.isEmpty
                        ? '?'
                        : communityName.characters.first.toUpperCase(),
                    accessibilityLabel: 'Community menu',
                    width: 44,
                    height: 44,
                    plain: false,
                  )
                : AndroidExpandingMenuButton(
                    label: 'Community menu',
                    actions: moreActions,
                    dividerBefore: const {1},
                    width: 48,
                    height: 48,
                    trigger: CommunityAvatar(
                      name: communityName,
                      relayUrl: community?.relayUrl,
                      size: 36,
                    ),
                  ),
          ),
        ];
      },
      messagesFilters: MessagesFilters(
        selected: filter.value,
        onSelected: (value) {
          filter.value = value;
          reselect.value++;
        },
      ),
      soloSliver: solo == null
          ? null
          : SliverOffstage(
              key: const ValueKey('messages-solo-inventory'),
              offstage: filter.value == 'Team',
              sliver: solo,
            ),
      showTeam: filter.value != 'Solo',
      showTeamHeading: filter.value == 'All',
      newChannelAction: newChannel,
      newDmAction: newDm,
      communityInvitePageBuilder: communityInvitePageBuilder,
      communityAppearancePageBuilder: communityAppearancePageBuilder,
      tabReselection: reselect,
      onSettingsTransitionProgress: (progress) {
        communitySurfaceProgress.value = progress;
      },
    );
    final bottom = mobileTabBarBottom(context);
    Widget navigationBar() => MessagesNavigationBar(
      onSearch: tablet ? () => showInWorkspace(_kWorkspaceSearch) : openSearch,
      agent: defaultAgentBuilder(context),
      creationActions: [
        (
          label: 'New chat',
          symbol: 'square.and.pencil',
          onPressed: newChat.value,
        ),
        (
          label: 'New workspace',
          symbol: 'workspace',
          onPressed: newWorkspace.value,
        ),
        (label: 'New DM', symbol: 'bubble.left', onPressed: newDm.value),
        (label: 'New channel', symbol: 'number', onPressed: newChannel.value),
      ],
    );
    final controlsVisible =
        defaultTargetPlatform != TargetPlatform.iOS || nativeControlsVisible;

    if (tablet) {
      final sidebar = Stack(
        fit: StackFit.expand,
        children: [
          MediaQuery(
            // Keep the last rows clear of the floating bottom bar.
            data: MediaQuery.of(context).copyWith(
              padding: MediaQuery.paddingOf(context).copyWith(
                bottom: bottom + mobileTabBarHeight + mobileTabBarBottomGap,
              ),
              viewPadding: MediaQuery.viewPaddingOf(context).copyWith(
                bottom: bottom + mobileTabBarHeight + mobileTabBarBottomGap,
              ),
            ),
            child: messages,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: MobileTabFooterBackdrop(
                height: mobileTabFooterBackdropHeight(context),
                tint: context.controlSurface,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottom,
            height: mobileTabBarHeight,
            child: controlsVisible
                ? Center(child: navigationBar())
                : const SizedBox.shrink(),
          ),
        ],
      );
      return ChannelWorkspaceScope(
        onOpen: (target) {
          if (workspaceChannel.value?.channel.id != target.channel.id) {
            unawaited(HapticFeedback.selectionClick());
          }
          showInWorkspace(_kWorkspaceChannel, target);
        },
        selectedChannelId: workspaceDestination.value == _kWorkspaceChannel
            ? selectedWorkspaceChannelId
            : null,
        child: Opacity(
          key: const Key('home-community-surface-visibility'),
          opacity: communitySurfaceProgress.value == 0 ? 1 : 0,
          child: _TabletWorkspace(
            sidebar: sidebar,
            selectedDestination: workspaceDestination.value,
            selectedChannel: workspaceChannel.value,
            selectedThread: workspaceThread.value,
            onDestinationSelected: (destination) {
              if (workspaceDestination.value == destination &&
                  workspaceChannel.value == null) {
                return;
              }
              unawaited(HapticFeedback.selectionClick());
              showInWorkspace(destination);
            },
            onThreadSelected: (thread) => workspaceThread.value = thread,
            onThreadClosed: () {
              workspaceThread.value = null;
              workspaceThreadExpanded.value = false;
            },
            sidebarCollapsed: workspaceSidebarCollapsed.value,
            onSidebarCollapsedChanged: (collapsed) {
              unawaited(HapticFeedback.selectionClick());
              workspaceSidebarCollapsed.value = collapsed;
              unawaited(
                _tabletPrefs(
                  ref,
                )?.setBool(_kTabletSidebarCollapsedPref, collapsed),
              );
            },
            threadExpanded: workspaceThreadExpanded.value,
            onThreadExpandedChanged: (expanded) {
              unawaited(HapticFeedback.selectionClick());
              workspaceThreadExpanded.value = expanded;
            },
          ),
        ),
      );
    }

    final phone = Scaffold(
      resizeToAvoidBottomInset: false,
      // Register the floating controls with Scaffold so snackbars clear them.
      extendBody: true,
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: SizedBox(
          height: mobileTabBarHeight,
          child: controlsVisible ? Center(child: navigationBar()) : null,
        ),
      ),
      body: Stack(
        children: [
          MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: MediaQuery.paddingOf(context).copyWith(
                bottom:
                    MediaQuery.paddingOf(context).bottom +
                    mobileTabBarHeight +
                    mobileTabBarBottomGap,
              ),
              viewPadding: MediaQuery.viewPaddingOf(context).copyWith(
                bottom:
                    MediaQuery.viewPaddingOf(context).bottom +
                    mobileTabBarHeight +
                    mobileTabBarBottomGap,
              ),
            ),
            child: Opacity(
              key: const Key('home-community-surface-visibility'),
              // The switcher uses a transparent route for its avatar flight.
              // Keep Home laid out, but do not paint it through UIKit glass.
              opacity: communitySurfaceProgress.value == 0 ? 1 : 0,
              child: messages,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: MobileTabFooterBackdrop(
                height: mobileTabFooterBackdropHeight(context),
                tint: context.controlSurface,
              ),
            ),
          ),
        ],
      ),
    );
    return ChannelWorkspaceScope(
      onCompactOpened: (target) => showInWorkspace(_kWorkspaceChannel, target),
      onCompactDismissed: () => showInWorkspace(_kWorkspaceInbox),
      child: phone,
    );
  }
}
