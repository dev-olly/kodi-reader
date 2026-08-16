import Foundation

/// The small set of Kokoro voices offered in the reader.
struct ReadAloudVoice: Identifiable, Hashable {
    var id: String
    var displayName: String
    var subtitle: String

    static let catalog: [ReadAloudVoice] = [
        ReadAloudVoice(id: "af_heart", displayName: "Heart", subtitle: "US English"),
        ReadAloudVoice(id: "af_bella", displayName: "Bella", subtitle: "US English"),
        ReadAloudVoice(id: "am_michael", displayName: "Michael", subtitle: "US English"),
        ReadAloudVoice(id: "bf_emma", displayName: "Emma", subtitle: "British English"),
    ]

    static let defaultID = "af_heart"

    static func isAmerican(_ id: String) -> Bool {
        id.first == "a"
    }
}
