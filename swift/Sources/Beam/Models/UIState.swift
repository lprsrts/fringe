import SwiftUI

/// A plain wrapper around `SwiftUI.State`. The Command Line Tools toolchain ships without
/// SwiftUIMacros.dylib, so this sidesteps the macro-based `@State` when building outside Xcode.
@propertyWrapper
public struct UIState<Value>: DynamicProperty {
    private var state: SwiftUI.State<Value>

    public init(wrappedValue: Value) {
        self.state = SwiftUI.State(initialValue: wrappedValue)
    }

    public var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    public var projectedValue: Binding<Value> {
        state.projectedValue
    }
}
