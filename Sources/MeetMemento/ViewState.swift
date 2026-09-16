import SwiftUI

// macOS ships State both as the original property-wrapper type and as a macro.
// Naming the wrapper explicitly keeps MeetMemento compatible with machines
// whose Command Line Tools do not include the optional SwiftUI macro plug-in.
typealias ViewState<Value> = SwiftUI.State<Value>
