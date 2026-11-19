import SwiftUI

extension View {
    /// A tooltip only when there is something to say: `.help("")` would still register an
    /// empty help tag with the accessibility tree.
    @ViewBuilder
    func help(ifAny text: String?) -> some View {
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
    }
}
