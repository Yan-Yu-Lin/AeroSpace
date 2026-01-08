import AppKit
import Common

/// Problem ID-B6E178F2: It's not first-class citizen command in AeroSpace model, since it interacts with macOS API directly.
/// Consecutive macos-native-fullscreen commands may not works as expected (because macOS may report correct state with a
/// delay), or may flicker
///
/// The same applies to macos-native-minimize command
struct MacosNativeFullscreenCommand: Command {
    let args: MacosNativeFullscreenCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        let prevState = try await window.isMacosFullscreen
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !prevState
        }
        if newState == prevState {
            if !args.failIfNoop {
                io.err((newState ? "Already fullscreen. " : "Already not fullscreen. ") +
                    "Tip: use --fail-if-noop to exit with non-zero exit code")
            }
            return !args.failIfNoop
        }
        window.asMacWindow().setNativeFullscreen(newState)
        guard let workspace = window.visualWorkspace else {
            return io.err(windowIsntPartOfTree(window))
        }
        if newState { // Enter fullscreen
            guard let parent = window.parent else {
                return io.err(windowIsntPartOfTree(window))
            }
            // Save position data BEFORE moving to fullscreen container
            let index = window.ownIndex ?? 0
            let siblings = parent.children
            let leftSibling = index > 0 ? siblings[index - 1] : nil
            let rightSibling = index < siblings.count - 1 ? siblings[index + 1] : nil
            let tilingParent = parent as? TilingContainer
            let weight = tilingParent.map { window.getWeight($0.orientation) } ?? WEIGHT_AUTO

            // Calculate proportion: window's share of the total container
            let totalWeight = tilingParent.map { tp in
                siblings.sumOfDouble { $0.getWeight(tp.orientation) }
            } ?? 1.0
            let proportion = totalWeight > 0 ? Double(weight) / totalWeight : 0.5

            // Save parent container's weight in grandparent (for recreating container with correct size)
            let grandparent = parent.parent
            let parentWeight: CGFloat = tilingParent.flatMap { tp in
                (grandparent as? TilingContainer).map { gp in tp.getWeight(gp.orientation) }
            } ?? WEIGHT_AUTO
            let parentIndexInGrandparent = tilingParent?.ownIndex ?? 0

            window.macosNativeFullscreenRestoreData = MacosNativeFullscreenRestoreData(
                savedParent: parent,
                savedWeight: weight,
                savedIndex: index,
                leftSibling: leftSibling,
                rightSibling: rightSibling,
                savedParentLayout: tilingParent?.layout,
                savedParentOrientation: tilingParent?.orientation,
                savedProportion: proportion,
                savedParentWeight: parentWeight,
                savedGrandparent: grandparent,
                savedParentIndexInGrandparent: parentIndexInGrandparent
            )

            window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        } else { // Exit fullscreen
            // Try to restore to saved position first
            if let restoreData = window.macosNativeFullscreenRestoreData {
                window.layoutReason = .standard
                let savedProportion = restoreData.savedProportion

                // Try to restore to saved parent
                if let savedParent = restoreData.savedParent, savedParent.isBound {
                    let clampedIndex = min(restoreData.savedIndex, savedParent.children.count)

                    // Restore with correct proportions by scaling sibling weights
                    // NOTE: Only do this for 'tiles' layout - accordion doesn't use weights for sizing
                    if let tilingParent = savedParent as? TilingContainer {
                        if tilingParent.layout == .tiles {
                            let currentSiblingsWeight = tilingParent.children.sumOfDouble { $0.getWeight(tilingParent.orientation) }

                            if savedProportion < 1.0 && savedProportion > 0 && currentSiblingsWeight > 0 {
                                // Calculate what siblings' total weight should be to maintain proportion
                                let targetSiblingsWeight = Double(restoreData.savedWeight) * (1.0 - savedProportion) / savedProportion
                                let scaleFactor = targetSiblingsWeight / currentSiblingsWeight

                                // Scale all current siblings' weights
                                for child in tilingParent.children {
                                    let oldWeight = child.getWeight(tilingParent.orientation)
                                    child.setWeight(tilingParent.orientation, oldWeight * scaleFactor)
                                }
                            }
                        }

                        // Now bind window with its original saved weight
                        window.bind(to: savedParent, adaptiveWeight: restoreData.savedWeight, index: clampedIndex)
                    } else {
                        window.bind(to: savedParent, adaptiveWeight: restoreData.savedWeight, index: clampedIndex)
                    }
                } else {
                    // Parent was flattened - recreate container structure
                    let savedLayout = restoreData.savedParentLayout ?? .tiles
                    let savedOrientation = restoreData.savedParentOrientation ?? .h

                    let sibling: TreeNode? = restoreData.leftSibling ?? restoreData.rightSibling
                    let windowWasOnLeft = restoreData.leftSibling == nil && restoreData.rightSibling != nil

                    if let sibling = sibling, let siblingParent = sibling.parent {
                        // Check if sibling's parent has compatible layout/orientation
                        if let tilingParent = siblingParent as? TilingContainer,
                           tilingParent.layout == savedLayout && tilingParent.orientation == savedOrientation {
                            // Calculate weight based on proportion
                            let currentSiblingsWeight = tilingParent.children.sumOfDouble { $0.getWeight(tilingParent.orientation) }
                            let newWeight: Double
                            if savedProportion < 1.0 && savedProportion > 0 {
                                newWeight = currentSiblingsWeight * savedProportion / (1.0 - savedProportion)
                            } else {
                                newWeight = Double(WEIGHT_AUTO)
                            }

                            let siblingIndex = sibling.ownIndex ?? 0
                            let insertIndex = windowWasOnLeft ? siblingIndex : siblingIndex + 1
                            window.bind(to: tilingParent, adaptiveWeight: newWeight, index: insertIndex)
                        } else if let siblingWorkspace = siblingParent as? Workspace,
                                  let siblingContainer = sibling as? TilingContainer {
                            // Special case: sibling's parent is Workspace (sibling became root)
                            // Use ABSOLUTE PIXEL weights, not proportions!
                            // Get total size from sibling (root's weight = workspace dimension)
                            let totalSize = siblingContainer.getWeight(savedOrientation)
                            let windowPixelWeight = totalSize * savedProportion
                            let siblingPixelWeight = totalSize - windowPixelWeight

                            // Create new root container with saved orientation/layout
                            let newRoot = TilingContainer(
                                parent: siblingWorkspace,
                                adaptiveWeight: WEIGHT_AUTO,
                                savedOrientation,
                                savedLayout,
                                index: INDEX_BIND_LAST
                            )

                            // Bind with absolute pixel weights
                            siblingContainer.bind(to: newRoot, adaptiveWeight: siblingPixelWeight, index: INDEX_BIND_LAST)
                            let windowIndex = windowWasOnLeft ? 0 : INDEX_BIND_LAST
                            window.bind(to: newRoot, adaptiveWeight: windowPixelWeight, index: windowIndex)
                        } else {
                            // Need to wrap sibling in new container
                            // Use sibling's inherited weight (it inherited from the flattened parent)
                            let siblingIndex = sibling.ownIndex ?? 0
                            let siblingInheritedWeight: CGFloat = (siblingParent as? TilingContainer).map { tp in
                                sibling.getWeight(tp.orientation)
                            } ?? restoreData.savedParentWeight

                            let newContainer = TilingContainer(
                                parent: siblingParent,
                                adaptiveWeight: siblingInheritedWeight,
                                savedOrientation,
                                savedLayout,
                                index: siblingIndex
                            )

                            // Use proportion-based weights
                            let siblingWeight = 1.0 - savedProportion
                            let windowWeight = savedProportion

                            sibling.bind(to: newContainer, adaptiveWeight: siblingWeight, index: INDEX_BIND_LAST)
                            let windowIndex = windowWasOnLeft ? 0 : INDEX_BIND_LAST
                            window.bind(to: newContainer, adaptiveWeight: windowWeight, index: windowIndex)
                        }
                    } else if let grandparent = restoreData.savedGrandparent, grandparent.isBound {
                        // No sibling found - try grandparent fallback
                        let clampedGrandparentIndex = min(restoreData.savedParentIndexInGrandparent, grandparent.children.count)
                        let newContainer = TilingContainer(
                            parent: grandparent,
                            adaptiveWeight: restoreData.savedParentWeight,
                            savedOrientation,
                            savedLayout,
                            index: clampedGrandparentIndex
                        )
                        window.bind(to: newContainer, adaptiveWeight: 1.0, index: INDEX_BIND_LAST)
                    } else {
                        // Ultimate fallback
                        try await window.relayoutWindow(on: workspace, forceTile: true)
                    }
                }
                window.macosNativeFullscreenRestoreData = nil
            } else {
                // No restore data, use original behavior
                switch window.layoutReason {
                    case .macos(let prevParentKind):
                        try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace)
                    default:
                        try await window.relayoutWindow(on: workspace)
                }
            }
        }
        return true
    }
}
