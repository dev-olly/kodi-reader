import Foundation
@main struct RegistrationTests {
 static func main() {
  let current = URL(fileURLWithPath: "/Applications/Kodi Reader.app")
  let other = URL(fileURLWithPath: "/tmp/Kodi Reader.app")
  assert(!DocumentRegistration.shouldUnregister(candidate: current, current: current, candidateVersion: "0.4.3", currentVersion: "0.4.3"))
  assert(DocumentRegistration.shouldUnregister(candidate: other, current: current, candidateVersion: "0.4.2", currentVersion: "0.4.3"))
  assert(DocumentRegistration.shouldUnregister(candidate: other, current: current, candidateVersion: "0.4.3", currentVersion: "0.4.3"))
  assert(!DocumentRegistration.shouldUnregister(candidate: other, current: current, candidateVersion: "0.4.10", currentVersion: "0.4.3"))
  assert(!DocumentRegistration.shouldUnregister(candidate: other, current: current, candidateVersion: nil, currentVersion: "0.4.3"))
  print("Registration cleanup checks passed.")
 }
}
