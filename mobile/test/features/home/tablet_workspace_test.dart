// RSLabs iPad fork: the persistent tablet workspace on the 0.27 Messages home.
import 'package:buzz/features/activity/activity_page.dart';
import 'package:buzz/features/agents/agents_page.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_workspace_scope.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/channels/default_agent_launcher.dart';
import 'package:buzz/features/channels/me/me_section.dart';
import 'package:buzz/features/home/home_page.dart';
import 'package:buzz/features/home/messages_navigation_bar.dart';
import 'package:buzz/features/search/search_page.dart';
import 'package:buzz/shared/me/default_agent.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;

  Future<Widget> buildHome() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    return ProviderScope(
      overrides: [
        savedPrefsProvider.overrideWithValue(prefs),
        defaultAgentProvider.overrideWith((ref) => Stream.value(null)),
        channelsProvider.overrideWith(_Channels.new),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: HomePage(
          onAgents: showAgents,
          defaultAgentBuilder: (context) =>
              DefaultAgentLauncher(onChooseAgent: () => showAgents(context)),
          mePageBuilder: (_, _, _) => const SliverToBoxAdapter(
            child: MeSection(
              label: 'Chats',
              children: [Text('Personal workspace')],
            ),
          ),
          settingsPageBuilder: (_) =>
              const Scaffold(body: Text('Your profile destination')),
        ),
      ),
    );
  }

  void useWindow(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  final sidebarKey = find.byKey(const ValueKey('tablet-workspace-sidebar'));
  final contentKey = find.byKey(
    const ValueKey('tablet-workspace-content-surface'),
  );

  testWidgets('uses the persistent workspace on a tablet-class window', (
    tester,
  ) async {
    useWindow(tester, const Size(1180, 820));
    await tester.pumpWidget(await buildHome());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('tablet-workspace')), findsOneWidget);
    expect(tester.getSize(sidebarKey).width, 320);
    // Messages, its filters and its bottom bar live in the sidebar.
    for (final text in ['Messages', 'General', 'Personal workspace']) {
      expect(
        find.descendant(of: sidebarKey, matching: find.text(text)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(
        of: sidebarKey,
        matching: find.byType(MessagesNavigationBar),
      ),
      findsOneWidget,
    );
    // The Inbox is the default destination, beside the sidebar.
    expect(
      find.descendant(of: contentKey, matching: find.byType(ActivityPage)),
      findsOneWidget,
    );
    expect(tester.getRect(contentKey).left, 320);
    expect(tester.getRect(contentKey).right, 1180);
  });

  testWidgets('Search from the bottom bar opens beside the sidebar', (
    tester,
  ) async {
    useWindow(tester, const Size(1180, 820));
    await tester.pumpWidget(await buildHome());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: contentKey, matching: find.byType(SearchPage)),
      findsOneWidget,
    );
    expect(sidebarKey, findsOneWidget);
  });

  testWidgets('collapses the sidebar to a rail and restores it', (
    tester,
  ) async {
    useWindow(tester, const Size(1180, 820));
    await tester.pumpWidget(await buildHome());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tablet-workspace-rail')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('hide-sidebar')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tablet-workspace-rail')), findsOneWidget);
    expect(tester.getRect(contentKey).left, 68);
    expect(prefs.getBool('tablet_workspace.sidebar_collapsed'), isTrue);

    await tester.tap(find.byKey(const ValueKey('tablet-rail-search')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: contentKey, matching: find.byType(SearchPage)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('tablet-show-sidebar')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tablet-workspace-rail')), findsNothing);
    expect(tester.getRect(contentKey).left, 320);
    expect(prefs.getBool('tablet_workspace.sidebar_collapsed'), isFalse);
  });

  testWidgets('resizes the sidebar by dragging its edge', (tester) async {
    useWindow(tester, const Size(1180, 820));
    await tester.pumpWidget(await buildHome());
    await tester.pumpAndSettle();

    final handle = find.byKey(const ValueKey('tablet-sidebar-resize'));
    await tester.drag(handle, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebarKey).width, closeTo(400, 1));
    expect(prefs.getDouble('tablet_workspace.sidebar_width'), closeTo(400, 1));
  });

  testWidgets('keeps phones and wide landscape phones in the compact shell', (
    tester,
  ) async {
    for (final size in const [Size(390, 844), Size(932, 430)]) {
      useWindow(tester, size);
      await tester.pumpWidget(await buildHome());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tablet-workspace')), findsNothing);
      expect(find.byType(MessagesNavigationBar), findsOneWidget);
    }
  });

  testWidgets('a workspace scope receives openings instead of a route', (
    tester,
  ) async {
    final opened = <ChannelWorkspaceTarget>[];
    final channel = _channel('dm', 'Rogerio');
    await tester.pumpWidget(
      MaterialApp(
        home: ChannelWorkspaceScope(
          onOpen: opened.add,
          selectedChannelId: 'dm',
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => openChannelDetail(
                context,
                channel: channel,
                personalChat: true,
                initialAssistant: 'agent',
              ),
              child: Text(
                'selected: ${ChannelWorkspaceScope.selectedChannelIdOf(context)}',
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('selected: dm'), findsOneWidget);
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(opened.single.channel.id, 'dm');
    expect(opened.single.personalChat, isTrue);
    expect(opened.single.initialAssistant, 'agent');
    // Nothing was pushed over the workspace.
    expect(find.byType(TextButton), findsOneWidget);
  });
}

Channel _channel(String id, String name) => Channel(
  id: id,
  name: name,
  description: '',
  createdBy: 'owner',
  createdAt: DateTime(2026),
  memberCount: 1,
  visibility: 'open',
  channelType: 'stream',
  isMember: true,
);

class _Channels extends ChannelsNotifier {
  @override
  Future<List<Channel>> build() async => [_channel('channel', 'General')];
}
