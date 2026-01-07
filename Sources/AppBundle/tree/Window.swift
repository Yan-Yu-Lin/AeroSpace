import AppKit
import Common

open class Window: TreeNode, Hashable {
    nonisolated let windowId: UInt32 // todo nonisolated keyword is no longer necessary?
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard
    /// Stores the window's position before entering macOS native fullscreen for restoration on exit
    var macosNativeFullscreenRestoreData: MacosNativeFullscreenRestoreData?

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxTopLeftCorner() async throws -> CGPoint? { die("Not implemented") }
    func getAxSize() async throws -> CGSize? { die("Not implemented") }
    var title: String { get async throws { die("Not implemented") } }
    var isMacosFullscreen: Bool { get async throws { false } }
    var isMacosMinimized: Bool { get async throws { false } } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    var isHiddenInCorner: Bool { die("Not implemented") }
    @MainActor
    func nativeFocus() { die("Not implemented") }
    func getAxRect() async throws -> Rect? { die("Not implemented") }
    func getCenter() async throws -> CGPoint? { try await getAxRect()?.center }

    func setAxFrameBlocking(_ topLeft: CGPoint?, _ size: CGSize?) async throws { die("Not implemented") }
    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind)
}

/// Stores the window's position before entering macOS native fullscreen
/// Uses weak references to handle cases where parent/siblings are removed while window is fullscreen
final class MacosNativeFullscreenRestoreData {
    weak var savedParent: NonLeafTreeNodeObject?
    let savedWeight: CGFloat
    let savedIndex: Int
    // Sibling anchors for fallback positioning if saved parent no longer exists
    weak var leftSibling: TreeNode?
    weak var rightSibling: TreeNode?
    // Parent container properties - needed to recreate container if it was flattened
    let savedParentLayout: Layout?
    let savedParentOrientation: Orientation?
    // Proportion of the container this window occupied (0.0 to 1.0)
    // Used to restore correct sizing even when sibling weights have changed
    let savedProportion: CGFloat
    // Parent container's weight in grandparent - needed to recreate container with correct size
    let savedParentWeight: CGFloat
    // Grandparent reference for ultimate fallback when no siblings exist
    weak var savedGrandparent: NonLeafTreeNodeObject?
    let savedParentIndexInGrandparent: Int

    init(
        savedParent: NonLeafTreeNodeObject?,
        savedWeight: CGFloat,
        savedIndex: Int,
        leftSibling: TreeNode?,
        rightSibling: TreeNode?,
        savedParentLayout: Layout?,
        savedParentOrientation: Orientation?,
        savedProportion: CGFloat,
        savedParentWeight: CGFloat,
        savedGrandparent: NonLeafTreeNodeObject?,
        savedParentIndexInGrandparent: Int
    ) {
        self.savedParent = savedParent
        self.savedWeight = savedWeight
        self.savedIndex = savedIndex
        self.leftSibling = leftSibling
        self.rightSibling = rightSibling
        self.savedParentLayout = savedParentLayout
        self.savedParentOrientation = savedParentOrientation
        self.savedProportion = savedProportion
        self.savedParentWeight = savedParentWeight
        self.savedGrandparent = savedGrandparent
        self.savedParentIndexInGrandparent = savedParentIndexInGrandparent
    }
}

extension Window {
    var isFloating: Bool { parent is Workspace } // todo drop. It will be a source of bugs when sticky is introduced

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}
