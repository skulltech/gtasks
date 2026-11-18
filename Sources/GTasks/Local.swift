import SwiftUI

/// Drop-in for `@State`. On recent SDKs `@State` is a macro whose plugin ships only with
/// full Xcode, so this lets the app build with just the Command Line Tools.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var state: State<Value>

    init(wrappedValue: Value) { state = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { state.projectedValue }
}
