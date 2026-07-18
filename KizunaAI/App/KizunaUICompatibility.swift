import SwiftUI

extension View {
    @ViewBuilder
    func viukAdaptiveSheetSizing(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self.presentationDetents([.large])
            .presentationDragIndicator(.visible)
        #endif
    }
}

