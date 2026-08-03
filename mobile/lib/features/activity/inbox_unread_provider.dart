import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/read_state/read_state_provider.dart';
import 'activity_provider.dart';
import 'inbox_local_state_provider.dart';
import 'inbox_read_state.dart';

/// Number of Inbox conversations that still need attention.
///
/// The floating tab bar uses this same read-state projection as Inbox rows, so
/// its indicator appears for every unread Inbox source and clears as soon as
/// the corresponding row is read.
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
