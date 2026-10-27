import 'package:flutter/widgets.dart';

/// Shared route lifecycle for native navigation and recording cleanup.
final appRouteObserver = AppRouteObserver();

/// Also reports reveals after the covering route has finished animating out.
class AppRouteObserver extends RouteObserver<ModalRoute<dynamic>> {
  final _revealListeners = <ModalRoute<dynamic>, Set<VoidCallback>>{};

  /// Registers a layout refresh for the end of a covering route's transition.
  void addRevealListener(ModalRoute<dynamic> route, VoidCallback listener) {
    (_revealListeners[route] ??= {}).add(listener);
  }

  /// Stops reporting completed reveals to a disposed navigation view.
  void removeRevealListener(ModalRoute<dynamic> route, VoidCallback listener) {
    final listeners = _revealListeners[route];
    listeners?.remove(listener);
    if (listeners?.isEmpty ?? false) _revealListeners.remove(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (route is! TransitionRoute<dynamic> ||
        previousRoute is! ModalRoute<dynamic>) {
      return;
    }
    route.completed.then((_) {
      if (!previousRoute.isCurrent) return;
      final listeners = List<VoidCallback>.of(
        _revealListeners[previousRoute] ?? const {},
      );
      for (final listener in listeners) {
        if (_revealListeners[previousRoute]?.contains(listener) ?? false) {
          listener();
        }
      }
    });
  }
}

/// Reports a nested navigator's route changes to [appRouteObserver].
///
/// A [NavigatorObserver] can be attached to only one [Navigator], so nested
/// navigators (tablet panes) forward their events instead. Native navigation
/// bars and voice-note recording subscribe through [appRouteObserver] and need
/// the reveal and cover notifications from routes in those panes too.
class NestedNavigatorRouteObserver extends NavigatorObserver {
  NestedNavigatorRouteObserver([AppRouteObserver? target])
    : _target = target ?? appRouteObserver;

  final AppRouteObserver _target;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _target.didPush(route, previousRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _target.didPop(route, previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _target.didRemove(route, previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _target.didReplace(newRoute: newRoute, oldRoute: oldRoute);
}
