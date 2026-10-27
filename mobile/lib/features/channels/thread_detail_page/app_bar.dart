part of '../thread_detail_page.dart';

FrostedAppBar _threadAppBar(
  BuildContext context,
  WidgetRef ref,
  Channel? channel,
  String? currentPubkey, {
  VoidCallback? onClose,
}) {
  final channelDisplayName = channel == null
      ? ''
      : channel.isDm
      ? ref.watch(
          identityNameSourcesProvider.select(
            (names) => resolveDmChannelDisplayLabel(
              channel,
              currentPubkey: currentPubkey,
              names: names,
            ),
          ),
        )
      : channel.name;
  final usesNativeIosGlassBackButton =
      onClose == null &&
      Navigator.canPop(context) &&
      Theme.of(context).platform == TargetPlatform.iOS;

  return FrostedAppBar(
    automaticallyImplyLeading: onClose == null,
    alwaysFrosted: true,
    nativeViewSuppressed: messageActionBackdropActive,
    nativeTitle: 'Thread',
    nativeSubtitle: channelDisplayName,
    leading: usesNativeIosGlassBackButton
        ? IosGlassNavigationButton(
            key: const ValueKey('thread-ios-glass-back'),
            icon: IosGlassNavigationIcon.back,
            semanticLabel: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            width: iosGlassChannelHeaderLeadingWidth,
            buttonCenterX: iosGlassChannelHeaderButtonCenterX,
            nativeViewSuppressed: messageActionBackdropActive,
          )
        : null,
    iconColor: context.colors.primary,
    title: Padding(
      padding: EdgeInsets.only(
        left: usesNativeIosGlassBackButton
            ? iosGlassChannelHeaderTitleSpacing
            : 0,
      ),
      child: const Text('Thread', key: ValueKey('thread-app-bar-title')),
    ),
    titleStyle: channelTitleTextStyle,
    actions: [
      if (onClose != null)
        IconButton(
          key: const ValueKey('tablet-thread-close'),
          tooltip: 'Close thread',
          onPressed: onClose,
          icon: const Icon(BuzzIcons.x),
        ),
    ],
  );
}
