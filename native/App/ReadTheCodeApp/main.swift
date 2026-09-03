import RTCContracts
import RTCDesign
import RTCDomain
import RTCIPC
import RTCLifecycle
import RTCReview
import RTCStore
import SwiftUI

/// Compile-only composition root. Product UI and final application composition remain
/// reserved for the Wave B feature targets and RTC-900.
@main
struct ReadTheCodeApp: App {
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
    }
}
