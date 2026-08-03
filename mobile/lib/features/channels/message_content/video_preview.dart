part of '../message_content.dart';

/// A decoded, paused video surface used as a posterless message preview.
class LoadedVideoPreviewFrame {
  /// Widget backed by the initialized native video texture.
  final Widget child;

  /// Aspect ratio reported by the video decoder.
  final double aspectRatio;

  final Future<void> Function() _dispose;

  /// Creates a loaded preview frame with its resource cleanup callback.
  const LoadedVideoPreviewFrame({
    required this.child,
    required this.aspectRatio,
    required Future<void> Function() dispose,
  }) : _dispose = dispose;

  /// Releases the native decoder and any downloaded temporary file.
  Future<void> dispose() => _dispose();
}

/// Loads a paused first-frame surface for a video URL.
typedef VideoPreviewFrameLoader =
    Future<LoadedVideoPreviewFrame?> Function(String url);

/// Loader used when an older video event has no NIP-71 poster URL.
final videoPreviewFrameLoaderProvider = Provider<VideoPreviewFrameLoader>((
  ref,
) {
  final auth = ref.watch(mediaGetAuthServiceProvider);
  final client = ref.watch(mediaHttpClientProvider);
  return (url) => _loadVideoPreviewFrame(
    url,
    headers: auth.headersFor(url),
    client: client,
  );
});

class _MessageVideoPreview extends HookConsumerWidget {
  final String url;
  final ImetaEntry? imeta;
  final VoidCallback? onReply;

  const _MessageVideoPreview({
    required this.url,
    required this.imeta,
    required this.onReply,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rawAspectRatio = imeta?.aspectRatio ?? (16 / 9);
    final aspectRatio = rawAspectRatio.clamp(0.75, 1.91);
    final posterUrl = imeta?.posterUrl;
    final loadPreviewFrame = ref.watch(videoPreviewFrameLoaderProvider);
    final previewFrameFuture = useMemoized(
      () => posterUrl == null
          ? loadPreviewFrame(url)
          : Future<LoadedVideoPreviewFrame?>.value(),
      [loadPreviewFrame, posterUrl, url],
    );

    useEffect(() {
      var disposed = false;
      LoadedVideoPreviewFrame? loadedFrame;
      unawaited(
        previewFrameFuture.then((frame) {
          if (disposed) {
            if (frame != null) unawaited(frame.dispose());
          } else {
            loadedFrame = frame;
          }
        }),
      );
      return () {
        disposed = true;
        final frame = loadedFrame;
        if (frame != null) unawaited(frame.dispose());
      };
    }, [previewFrameFuture]);

    return Padding(
      padding: const EdgeInsets.only(top: Grid.half),
      child: GestureDetector(
        onTap: () => openVideoViewer(
          context,
          videoUrl: url,
          posterUrl: posterUrl,
          onReply: onReply,
        ),
        child: _MessageMediaPreviewFrame(
          previewKey: ValueKey('message-media-video-preview:$url'),
          backgroundColor: Colors.black,
          child: AspectRatio(
            aspectRatio: aspectRatio.toDouble(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (posterUrl != null)
                  MediaImage(
                    url: posterUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const _MediaPreviewFallback(
                      icon: LucideIcons.video,
                      label: 'Video preview unavailable',
                    ),
                  )
                else
                  FutureBuilder<LoadedVideoPreviewFrame?>(
                    future: previewFrameFuture,
                    builder: (context, snapshot) {
                      final frame = snapshot.data;
                      if (frame == null) {
                        return const _MediaPreviewFallback(
                          icon: LucideIcons.video,
                          label: 'Video attachment',
                        );
                      }
                      return ColoredBox(
                        key: ValueKey('message-media-video-first-frame:$url'),
                        color: Colors.black,
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: frame.aspectRatio,
                            child: frame.child,
                          ),
                        ),
                      );
                    },
                  ),
                const ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.28)),
                Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: Color.fromRGBO(0, 0, 0, 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      LucideIcons.play,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
                Positioned(
                  left: Grid.xxs,
                  right: Grid.xxs,
                  bottom: Grid.xxs,
                  child: Text(
                    'Video',
                    style: context.textTheme.labelSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<LoadedVideoPreviewFrame?> _loadVideoPreviewFrame(
  String url, {
  required Map<String, String> headers,
  required http.Client client,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;

  VideoPlayerController? controller;
  File? downloadedFile;

  Future<void> disposeResources() async {
    final currentController = controller;
    controller = null;
    if (currentController != null) await currentController.dispose();
    final currentFile = downloadedFile;
    downloadedFile = null;
    if (currentFile != null) {
      try {
        if (await currentFile.exists()) await currentFile.delete();
      } on FileSystemException {
        // Temporary preview cleanup should never break the message timeline.
      }
    }
  }

  Future<bool> initialize(VideoPlayerController candidate) async {
    controller = candidate;
    await candidate.initialize();
    final duration = candidate.value.duration;
    if (duration > const Duration(milliseconds: 100)) {
      await candidate.seekTo(const Duration(milliseconds: 100));
    }
    await candidate.pause();
    return candidate.value.isInitialized;
  }

  try {
    final networkController = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: headers,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    if (!await initialize(networkController)) {
      await disposeResources();
      return null;
    }
  } on MissingPluginException {
    await disposeResources();
    return null;
  } on UnimplementedError {
    await disposeResources();
    return null;
  } catch (_) {
    // Some protected media servers or AVPlayer range requests do not retain
    // custom headers. Fall back to the same authenticated local-file path as
    // the full-screen viewer so posterless historical events still get a frame.
    await disposeResources();
    try {
      final request = http.Request('GET', uri)..headers.addAll(headers);
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        return null;
      }
      final directory = await getTemporaryDirectory();
      downloadedFile = File(
        '${directory.path}${Platform.pathSeparator}'
        'buzz-video-preview-${DateTime.now().microsecondsSinceEpoch}'
        '${_previewVideoFileExtension(uri)}',
      );
      await response.stream.pipe(downloadedFile!.openWrite());
      if (!await initialize(VideoPlayerController.file(downloadedFile!))) {
        await disposeResources();
        return null;
      }
    } catch (_) {
      await disposeResources();
      return null;
    }
  }

  final initializedController = controller;
  if (initializedController == null) return null;
  var didDispose = false;
  return LoadedVideoPreviewFrame(
    aspectRatio: initializedController.value.aspectRatio > 0
        ? initializedController.value.aspectRatio
        : 16 / 9,
    child: VideoPlayer(initializedController),
    dispose: () async {
      if (didDispose) return;
      didDispose = true;
      await disposeResources();
    },
  );
}

String _previewVideoFileExtension(Uri uri) {
  final path = uri.path;
  final extensionStart = path.lastIndexOf('.');
  if (extensionStart < 0 || extensionStart == path.length - 1) return '.mp4';
  final extension = path.substring(extensionStart);
  return RegExp(r'^\.[A-Za-z0-9]{1,10}$').hasMatch(extension)
      ? extension
      : '.mp4';
}
