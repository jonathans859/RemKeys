import SwiftUI

/// Post a VoiceOver announcement that *queues* after whatever VoiceOver is
/// currently saying. A plain `UIAccessibility.post(.announcement)` interrupts
/// ongoing speech, which clips VoiceOver mid-sentence whenever an
/// announcement coincides with the system speaking a control's updated state
/// (field-reported on the virtual-input rows). Low priority still speaks
/// immediately when VoiceOver is idle.
func postQueuedAnnouncement(_ message: String) {
    var attributed = AttributedString(message)
    attributed.accessibilitySpeechAnnouncementPriority = .low
    AccessibilityNotification.Announcement(attributed).post()
}
