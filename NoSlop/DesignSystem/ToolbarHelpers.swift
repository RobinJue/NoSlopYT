import SwiftUI

extension ToolbarContent {
    /// On iOS 26 toolbar items sit in a glass capsule; this removes it for items that are a label rather than a button.
    /// Earlier systems draw no capsule, so there is nothing to remove.
    @ToolbarContentBuilder
    func hidingSharedBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
