import 'package:buzz/shared/utils/adaptive_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses the persistent workspace for tablet-class windows', () {
    expect(usesTabletWorkspace(width: 1024, height: 768), isTrue);
    expect(usesTabletWorkspace(width: 840, height: 600), isTrue);
    // 11-inch iPad portrait.
    expect(usesTabletWorkspace(width: 834, height: 1194), isTrue);
  });

  test('keeps iPad mini portrait in the compact shell', () {
    expect(usesTabletWorkspace(width: 744, height: 1133), isFalse);
    // Flutter's default 800x600 test surface stays compact too.
    expect(usesTabletWorkspace(width: 800, height: 600), isFalse);
  });

  test('keeps wide landscape phones in the compact shell', () {
    expect(usesTabletWorkspace(width: 932, height: 430), isFalse);
  });

  test('falls back when split view is too narrow', () {
    expect(usesTabletWorkspace(width: 700, height: 1024), isFalse);
  });
}
