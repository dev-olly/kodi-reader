import Foundation
@main struct RegistrationTests {
 static func main() {
  let current = URL(fileURLWithPath: "/Applications/Kodi Reader.app")
  let other = URL(fileURLWithPath: "/tmp/Kodi Reader.app")
  let installedOther = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Kodi Reader.app")
  assert(!DocumentRegistration.shouldUnregister(candidate: current, current: current, candidateVersion: "0.4.3", currentVersion: "0.4.3"))
  assert(DocumentRegistration.shouldUnregister(candidate: other, current: current, candidateVersion: "0.4.2", currentVersion: "0.4.3"))
  assert(DocumentRegistration.shouldUnregister(candidate: other, current: current, candidateVersion: "0.4.3", currentVersion: "0.4.3"))
  assert(DocumentRegistration.shouldUnregister(candidate: other, current: current, candidateVersion: "0.4.10", currentVersion: "0.4.3"))
  assert(DocumentRegistration.shouldUnregister(candidate: other, current: current, candidateVersion: nil, currentVersion: "0.4.3"))
  assert(DocumentRegistration.shouldUnregister(candidate: other, current: current, candidateVersion: "", currentVersion: "0.4.3"))
  assert(!DocumentRegistration.shouldUnregister(candidate: current, current: current, candidateVersion: nil, currentVersion: "0.4.3"))
  assert(!DocumentRegistration.shouldUnregister(candidate: installedOther, current: current, candidateVersion: "0.4.10", currentVersion: "0.4.3"))
  assert(DocumentRegistration.shouldUnregister(candidate: installedOther, current: current, candidateVersion: "0.4.2", currentVersion: "0.4.3"))
  assert(DocumentRegistration.shouldUnregister(candidate: installedOther, current: current, candidateVersion: nil, currentVersion: "0.4.3"))
  assert(DocumentRegistration.isInstalled(current))
  assert(!DocumentRegistration.isInstalled(URL(fileURLWithPath: "/Applications/Development/Kodi Reader.app")))
  assert(DocumentRegistration.bundleIdentifiers.contains("com.olly.Folio"))
  assert(DocumentRegistration.bundleIdentifiers.contains("com.olly.EpubReader"))
  print("Registration cleanup checks passed.")
 }
}
