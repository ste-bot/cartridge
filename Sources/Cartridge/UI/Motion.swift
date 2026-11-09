import SwiftUI

/// Shared motion tokens. Curves match the strong UI easings used across the app.
enum Motion {
    /// Strong ease-out for UI entering or leaving: cubic-bezier(0.23, 1, 0.32, 1).
    static func easeOut(_ duration: Double) -> Animation { .timingCurve(0.23, 1, 0.32, 1, duration: duration) }
    /// Strong ease-in-out for on-screen movement: cubic-bezier(0.77, 0, 0.175, 1).
    static func easeInOut(_ duration: Double) -> Animation { .timingCurve(0.77, 0, 0.175, 1, duration: duration) }

    static let toastIn = easeOut(0.2)
    static let toastOut = easeOut(0.15)
    static let reflow = easeInOut(0.2)

    /// Toasts rise 8pt from the bottom edge; with Reduce Motion they only fade.
    static func toast(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: (reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 8)))
                .animation(toastIn),
            removal: AnyTransition.opacity.animation(toastOut)
        )
    }
}
