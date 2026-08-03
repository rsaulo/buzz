import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/activity/activity_provider.dart';
import '../../features/activity/inbox_local_state_provider.dart';
import '../../features/activity/inbox_read_state.dart';
import 'read_state_provider.dart';

/// Number of Inbox conversations that still need attention.
///
/// This shared projection lets navigation surfaces observe Inbox state without
/// reaching into the Activity presentation feature.
final unreadInboxItemCountProvider = Provider<int>((ref) {
  final readState = ref.watch(readStateProvider);
  if (!readState.isReady) return 0;

  final localState = ref.watch(inboxLocalStateProvider);
  final items = ref.watch(inboxItemsProvider);
  return items
      .where(
        (item) => !isInboxItemDone(
          item,
          markerOf: readState.effectiveTimestamp,
          localUnreadOverrides: localState.unreadIds,
          localDoneSet: localState.doneIds,
        ),
      )
      .length;
});
