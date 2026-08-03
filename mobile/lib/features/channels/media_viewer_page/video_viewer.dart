part of '../media_viewer_page.dart';

// StatefulWidget retained: owns a VideoPlayerController with async init and
// disposal — kept imperative deliberately (allowed exception).
class MediaVideoViewerPage extends StatefulWidget {
  final String videoUrl;
  final String? posterUrl;
  final VoidCallback? onReply;

  const MediaVideoViewerPage({
    super.key,
    required this.videoUrl,
    this.posterUrl,
    this.onReply,
  });

  @override
  State<MediaVideoViewerPage> createState() => _MediaVideoViewerPageState();
}

class _MediaVideoViewerPageState extends State<MediaVideoViewerPage>
    with SingleTickerProviderStateMixin {
  static const _dismissThreshold = 100.0;
  static const _dismissVelocity = 700.0;
  static const _backgroundFadeDivisor = 300.0;

  VideoPlayerController? _controller;
  File? _videoFile;
  late final Future<void> _initializeFuture;
  late final AnimationController _snapBackController;
  String? _error;
  double _dragOffset = 0;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _snapBackController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _initializeFuture = _initializeVideo();
  }

  /// Download through Buzz's authenticated media client before handing the
  /// local file to AVPlayer. AVPlayer does not consistently preserve custom
  /// authorization headers for its follow-up range requests, which makes
  /// protected relay video fail after the first request.
  Future<void> _initializeVideo() async {
    try {
      final container = ProviderScope.containerOf(context, listen: false);
      final client = container.read(mediaHttpClientProvider);
      final auth = container.read(mediaGetAuthServiceProvider);
      final uri = Uri.parse(widget.videoUrl);
      final request = http.Request('GET', uri)
        ..headers.addAll(auth.headersFor(widget.videoUrl));
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw HttpException(
          'Video download failed (${response.statusCode})',
          uri: uri,
        );
      }

      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        'buzz-video-${DateTime.now().microsecondsSinceEpoch}'
        '${_videoFileExtension(uri)}',
      );
      _videoFile = file;
      await response.stream.pipe(file.openWrite());
      if (!mounted) {
        await _deleteVideoFile();
        return;
      }

      final controller = VideoPlayerController.file(file);
      _controller = controller;
      await controller.initialize();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _snapBackController.dispose();
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    unawaited(_deleteVideoFile());
    super.dispose();
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _snapBackController.stop();
    setState(() => _isDragging = true);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    setState(() {
      _dragOffset = (_dragOffset + details.delta.dy).clamp(
        0.0,
        MediaQuery.sizeOf(context).height,
      );
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    _isDragging = false;
    final velocity = details.primaryVelocity ?? 0;
    if (_dragOffset > _dismissThreshold || velocity > _dismissVelocity) {
      _controller?.pause();
      Navigator.of(context).maybePop();
      return;
    }
    _animateSnapBack();
  }

  void _animateSnapBack() {
    _isDragging = false;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _dragOffset = 0);
      return;
    }

    final tween = Tween<double>(begin: _dragOffset, end: 0);
    void listener() {
      if (mounted) {
        setState(() => _dragOffset = tween.evaluate(_snapBackController));
      }
    }

    _snapBackController
      ..stop()
      ..reset()
      ..addListener(listener);
    _snapBackController
        .animateWith(
          SpringSimulation(
            SpringDescription.withDurationAndBounce(
              duration: const Duration(milliseconds: 260),
              bounce: 0.14,
            ),
            0,
            1,
            0,
            snapToEnd: true,
          ),
        )
        .whenCompleteOrCancel(() {
          _snapBackController.removeListener(listener);
        });
  }

  Future<void> _deleteVideoFile() async {
    final file = _videoFile;
    _videoFile = null;
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Temporary storage cleanup should not make closing the viewer fail.
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final dragProgress = (_dragOffset / viewportHeight).clamp(0.0, 1.0);
    final videoScale = 1 - (dragProgress * 0.1);
    final chromeOpacity = (1 - (_dragOffset / 160)).clamp(0.0, 1.0);
    return Scaffold(
      key: const ValueKey('message-media-video-viewer'),
      backgroundColor: Colors.black.withValues(
        alpha: (1 - (_dragOffset / _backgroundFadeDivisor)).clamp(0.3, 1.0),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(0, _dragOffset),
              child: Transform.scale(
                scale: videoScale,
                child: GestureDetector(
                  key: const ValueKey('message-media-video-viewer-gesture'),
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: _onVerticalDragStart,
                  onVerticalDragUpdate: _onVerticalDragUpdate,
                  onVerticalDragEnd: _onVerticalDragEnd,
                  onVerticalDragCancel: _animateSnapBack,
                  child: SafeArea(
                    child: Center(
                      child: FutureBuilder<void>(
                        future: _initializeFuture,
                        builder: (context, snapshot) {
                          if (_error != null || snapshot.hasError) {
                            return const _MediaLoadFailure(
                              message: 'Failed to load video',
                              icon: LucideIcons.videoOff,
                            );
                          }

                          final controller = _controller;
                          if (controller == null ||
                              !controller.value.isInitialized) {
                            return _VideoLoadingPoster(
                              posterUrl: widget.posterUrl,
                            );
                          }

                          return AspectRatio(
                            aspectRatio: controller.value.aspectRatio,
                            child: VideoPlayer(controller),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          PositionedDirectional(
            top: Grid.sm,
            end: Grid.sm,
            child: Opacity(
              opacity: chromeOpacity,
              child: SafeArea(
                child: _MediaViewerCircleButton(
                  key: const ValueKey('message-media-video-viewer-close'),
                  icon: LucideIcons.x,
                  tooltip: 'Close video viewer',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ),
          PositionedDirectional(
            bottom: 0,
            start: 0,
            end: 0,
            child: Opacity(
              opacity: chromeOpacity,
              child: SafeArea(
                child: _VideoViewerBottomControls(
                  controller: _controller,
                  onReply: widget.onReply,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _videoFileExtension(Uri uri) {
  final path = uri.path;
  final extensionStart = path.lastIndexOf('.');
  if (extensionStart < 0 || extensionStart == path.length - 1) return '.mp4';
  final extension = path.substring(extensionStart);
  return RegExp(r'^\.[A-Za-z0-9]{1,10}$').hasMatch(extension)
      ? extension
      : '.mp4';
}

class _VideoLoadingPoster extends StatelessWidget {
  final String? posterUrl;

  const _VideoLoadingPoster({required this.posterUrl});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (posterUrl != null)
            MediaImage(
              url: posterUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _videoPlaceholder(context),
            )
          else
            _videoPlaceholder(context),
          const ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.24)),
          const Center(
            child: BuzzLoadingIndicator(
              size: 44,
              color: Colors.white,
              semanticLabel: 'Loading video',
            ),
          ),
        ],
      ),
    );
  }

  Widget _videoPlaceholder(BuildContext context) {
    return ColoredBox(
      color: context.colors.surfaceContainerHighest,
      child: Icon(
        LucideIcons.video,
        size: 40,
        color: context.colors.onSurfaceVariant,
      ),
    );
  }
}
