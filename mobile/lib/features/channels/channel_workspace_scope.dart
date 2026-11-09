import 'package:flutter/material.dart';

import 'channel.dart';
import 'channel_detail_page.dart';

/// A conversation the tablet workspace shows beside its sidebar.
class ChannelWorkspaceTarget {
  const ChannelWorkspaceTarget({
    required this.channel,
    this.personalChat = false,
    this.initialAssistant,
    this.placement = ChannelRoutePlacement.lookup,
  });

  final Channel channel;

  /// Caller identity for Solo placement, as on the phone route.
  final ChannelRoutePlacement placement;

  /// Opens the conversation with Solo (personal assistant) routing.
  final bool personalChat;
  final String? initialAssistant;
}

/// Routes conversation openings to an enclosing adaptive workspace.
///
/// In the tablet layout [onOpen] shows the conversation in the content pane
/// instead of pushing a full-window route. In the phone layout the scope only
/// remembers the open route ([onCompactOpened] / [onCompactDismissed]) so the
/// workspace can take it over if the window grows to tablet size.
class ChannelWorkspaceScope extends InheritedWidget {
  const ChannelWorkspaceScope({
    this.onOpen,
    this.selectedChannelId,
    this.onCompactOpened,
    this.onCompactDismissed,
    required super.child,
    super.key,
  });

  final ValueChanged<ChannelWorkspaceTarget>? onOpen;

  /// Conversation currently shown by the workspace, for row highlighting.
  final String? selectedChannelId;
  final ValueChanged<ChannelWorkspaceTarget>? onCompactOpened;
  final VoidCallback? onCompactDismissed;

  static ChannelWorkspaceScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ChannelWorkspaceScope>();

  /// The selected conversation id, rebuilding [context] when it changes.
  static String? selectedChannelIdOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ChannelWorkspaceScope>()
      ?.selectedChannelId;

  @override
  bool updateShouldNotify(ChannelWorkspaceScope oldWidget) =>
      oldWidget.selectedChannelId != selectedChannelId;
}

/// Opens a conversation: in the tablet workspace when one encloses [context],
/// otherwise as a full-window route.
Future<void> openChannelDetail(
  BuildContext context, {
  required Channel channel,
  bool personalChat = false,
  String? initialAssistant,
  ChannelRoutePlacement placement = ChannelRoutePlacement.lookup,
  bool allowSnapshotting = true,
}) async {
  final target = ChannelWorkspaceTarget(
    channel: channel,
    personalChat: personalChat,
    initialAssistant: initialAssistant,
    placement: placement,
  );
  final scope = ChannelWorkspaceScope.maybeOf(context);
  final onOpen = scope?.onOpen;
  if (onOpen != null) {
    onOpen(target);
    return;
  }
  final onCompactOpened = scope?.onCompactOpened;
  onCompactOpened?.call(target);
  var yieldedToWorkspace = false;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      allowSnapshotting: allowSnapshotting,
      builder: (_) => ChannelDetailPage(
        channel: channel,
        personalChat: personalChat,
        initialAssistant: initialAssistant,
        placement: placement,
        onTabletWorkspaceActivated: onCompactOpened == null
            ? null
            : () => yieldedToWorkspace = true,
      ),
    ),
  );
  if (!yieldedToWorkspace) scope?.onCompactDismissed?.call();
}
