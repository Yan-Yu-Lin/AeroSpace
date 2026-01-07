@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    try await validateStillPopups()
}

@MainActor
private func validateStillPopups() async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel) {
            try await popup.relayoutWindow(on: focus.workspace)
            try await tryOnWindowDetected(popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    for window in windows {
        let isMacosFullscreen = try await window.isMacosFullscreen
        let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized }
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                if isMacosFullscreen {
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
                    let parentWeight = tilingParent.flatMap { tp in
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

                    // Move to fullscreen container (original behavior)
                    window.layoutReason = .macos(prevParentKind: parent.kind)
                    window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                } else if isMacosMinimized {
                    window.layoutReason = .macos(prevParentKind: parent.kind)
                    window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                } else if isMacosWindowOfHiddenApp {
                    window.layoutReason = .macos(prevParentKind: parent.kind)
                    window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    // Try to restore to saved position for fullscreen windows
                    if let restoreData = window.macosNativeFullscreenRestoreData {
                        try await restoreWindowPosition(window: window, restoreData: restoreData, workspace: workspace, prevParentKind: prevParentKind)
                        window.macosNativeFullscreenRestoreData = nil
                    } else {
                        try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace)
                    }
                }
        }
    }
}

/// Attempts to restore a window to its saved position, with fallbacks
@MainActor
private func restoreWindowPosition(window: Window, restoreData: MacosNativeFullscreenRestoreData, workspace: Workspace, prevParentKind: NonLeafTreeNodeKind) async throws {
    window.layoutReason = .standard
    let savedProportion = restoreData.savedProportion

    // Try to restore to saved parent (if it still exists and is bound)
    if let savedParent = restoreData.savedParent, savedParent.isBound {
        let clampedIndex = min(restoreData.savedIndex, savedParent.children.count)

        // Calculate new weight based on proportion and current sibling weights
        // This handles the case where siblings' weights changed while window was fullscreen
        if let tilingParent = savedParent as? TilingContainer {
            let currentSiblingsWeight = tilingParent.children.sumOfDouble { $0.getWeight(tilingParent.orientation) }
            // Formula: windowWeight = siblingsWeight * proportion / (1 - proportion)
            // So that: windowWeight / (windowWeight + siblingsWeight) = proportion
            let newWeight: Double
            if savedProportion < 1.0 && savedProportion > 0 {
                newWeight = currentSiblingsWeight * savedProportion / (1.0 - savedProportion)
            } else {
                newWeight = Double(restoreData.savedWeight)
            }
            window.bind(to: savedParent, adaptiveWeight: newWeight, index: clampedIndex)
        } else {
            window.bind(to: savedParent, adaptiveWeight: restoreData.savedWeight, index: clampedIndex)
        }
        return
    }

    // Parent was flattened - need to find a sibling and recreate container structure
    // Get the saved container properties (needed to recreate the container)
    let savedLayout = restoreData.savedParentLayout ?? .tiles
    let savedOrientation = restoreData.savedParentOrientation ?? .h

    // Find a sibling that still exists
    let sibling: TreeNode? = restoreData.leftSibling ?? restoreData.rightSibling
    let windowWasOnLeft = restoreData.leftSibling == nil && restoreData.rightSibling != nil

    if let sibling = sibling, let siblingParent = sibling.parent {
        // Check if sibling's parent is a TilingContainer with the SAME layout/orientation
        // If so, we can just insert next to the sibling
        if let tilingParent = siblingParent as? TilingContainer,
           tilingParent.layout == savedLayout && tilingParent.orientation == savedOrientation {
            // Container structure is compatible - insert next to sibling
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
            return
        }

        // Container was flattened or has different layout - need to wrap sibling in new container
        // This handles: sibling became root, or sibling is in a container with different layout

        // Step 1: Get sibling's current position and weight
        // When the parent container was flattened, sibling inherited the parent's weight
        let siblingIndex = sibling.ownIndex ?? 0
        let siblingInheritedWeight = (siblingParent as? TilingContainer).map { tp in
            sibling.getWeight(tp.orientation)
        } ?? restoreData.savedParentWeight

        // Step 2: Create new container with the weight the sibling inherited (which was the parent's weight)
        let newContainer = TilingContainer(
            parent: siblingParent,
            adaptiveWeight: siblingInheritedWeight,
            savedOrientation,
            savedLayout,
            index: siblingIndex
        )

        // Step 3: Move sibling into the new container with weight based on (1 - proportion)
        // Step 4: Add window with weight based on proportion
        // Use relative weights so they maintain the saved proportion
        let siblingWeight = 1.0 - savedProportion
        let windowWeight = savedProportion

        sibling.bind(to: newContainer, adaptiveWeight: siblingWeight, index: INDEX_BIND_LAST)
        let windowIndex = windowWasOnLeft ? 0 : INDEX_BIND_LAST
        window.bind(to: newContainer, adaptiveWeight: windowWeight, index: windowIndex)
        return
    }

    // No sibling found - try grandparent fallback
    if let grandparent = restoreData.savedGrandparent, grandparent.isBound {
        // Create new container at the saved position with saved parent weight
        let clampedGrandparentIndex = min(restoreData.savedParentIndexInGrandparent, grandparent.children.count)
        let newContainer = TilingContainer(
            parent: grandparent,
            adaptiveWeight: restoreData.savedParentWeight,
            savedOrientation,
            savedLayout,
            index: clampedGrandparentIndex
        )
        // Window takes 100% of the new container since it's alone
        window.bind(to: newContainer, adaptiveWeight: 1.0, index: INDEX_BIND_LAST)
        return
    }

    // Ultimate fallback: no sibling or grandparent found, use original behavior
    switch prevParentKind {
        case .workspace:
            window.bindAsFloatingWindow(to: workspace)
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, forceTile: true)
        case .macosPopupWindowsContainer:
            try await window.relayoutWindow(on: workspace)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            try await window.relayoutWindow(on: workspace)
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(window: Window, prevParentKind: NonLeafTreeNodeKind, workspace: Workspace) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .workspace:
            window.bindAsFloatingWindow(to: workspace)
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace)
    }
}
