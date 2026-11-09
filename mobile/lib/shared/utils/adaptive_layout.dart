/// Minimum logical width for Buzz's persistent tablet workspace.
///
/// 820 keeps 11-inch iPads (820–834 points) in the workspace in portrait while
/// iPad mini portrait (744) and narrow Split View windows use the phone shell.
const double tabletWorkspaceMinWidth = 820;

/// Minimum logical shortest side for a window to be treated as tablet-class.
///
/// Requiring both dimensions keeps wide landscape phones in the compact shell
/// while still allowing iPad Split View and Stage Manager to fall back as the
/// window becomes too narrow for persistent navigation.
const double tabletWorkspaceMinShortestSide = 600;

/// Whether a window can support Buzz's persistent navigation workspace.
bool usesTabletWorkspace({required double width, required double height}) =>
    width >= tabletWorkspaceMinWidth &&
    (width < height ? width : height) >= tabletWorkspaceMinShortestSide;
