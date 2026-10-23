import Foundation
import IOKit.pwr_mgt

private final class MockAssertionBackend: IdleSleepAssertionBackend {
    var creates: [(String, String)] = []
    var releases: [IOPMAssertionID] = []
    var createStatus = kIOReturnSuccess
    var nextID: IOPMAssertionID = 1
    var releaseStatus = kIOReturnSuccess
    func create(type: CFString, reason: CFString) -> (status: IOReturn, id: IOPMAssertionID) {
        creates.append((type as String, reason as String))
        let id = nextID; nextID += 1
        return (createStatus, id)
    }
    func release(_ id: IOPMAssertionID) -> IOReturn { releases.append(id); return releaseStatus }
}

@main @MainActor struct PowerManagementTests {
    static var checks = 0
    static func check(_ passed: @autoclosure () -> Bool, _ description: String) {
        guard passed() else { fatalError("FAIL " + description) }
        checks += 1; print("PASS " + description)
    }
    static func transfer(phase: String = "downloading", draft: Bool = false, metadata: Bool = true,
                         done: Int64 = 0, error: String = "", id: String = "a") -> Transfer {
        Transfer(id: id, draft: draft, name: "Synthetic", phase: phase, hasMetadata: metadata,
                 size: 100, wanted: 100, done: done, downloadRate: 0, uploadRate: 0,
                 downloaded: done, uploaded: 0, peers: 0, seeds: 0, ratio: 0,
                 destination: "/tmp/synthetic", error: error, hash: "", files: [], trackers: [])
    }
    static func main() throws {
        let active = transfer()
        let backend = MockAssertionBackend()
        let power = SleepPreventionController(backend: backend)
        check(power.update(preventSleep: false, transfers: [active]) == nil && backend.creates.isEmpty, "disabled option never creates assertion")
        for ignored in [transfer(phase: "paused"), transfer(phase: "seeding"), transfer(phase: "error"),
                        transfer(phase: "metadata", metadata: false), transfer(phase: "ready", draft: true),
                        transfer(draft: true), transfer(metadata: false), transfer(done: 100), transfer(error: "Disk full")] {
            check(!SleepPreventionController.isActiveDownload(ignored), "non-active state excluded: " + ignored.phase)
            _ = power.update(preventSleep: true, transfers: [ignored])
        }
        check(backend.creates.isEmpty, "ignored task states leave host sleep policy untouched")
        check(power.update(preventSleep: true, transfers: [active]) == .started, "zero-rate unfinished download acquires assertion")
        check(power.isPreventingSleep && backend.creates.count == 1, "single assertion held for download")
        check(backend.creates[0].0 == "PreventUserIdleSystemSleep", "only system idle sleep assertion type requested")
        check(!backend.creates[0].1.isEmpty && backend.creates[0].1.count <= 128, "assertion reason is descriptive and valid")
        check(power.update(preventSleep: true, transfers: [active, transfer(id: "b")]) == nil && backend.creates.count == 1, "multiple downloads and repeated ticks do not duplicate assertion")
        check(power.update(preventSleep: true, transfers: [transfer(done: 100), transfer(id: "b")]) == nil && backend.releases.isEmpty, "one completed transfer does not release while another is active")
        check(power.update(preventSleep: true, transfers: [transfer(phase: "paused")]) == .stopped && backend.releases == [1], "pausing last download releases assertion once")
        check(power.update(preventSleep: true, transfers: []) == nil && backend.releases == [1], "repeated idle updates do not release twice")
        check(power.update(preventSleep: true, transfers: [transfer(phase: "checking")]) == .started, "verification of unfinished download can finish while unattended")
        check(power.update(preventSleep: false, transfers: [active]) == .stopped && !power.isPreventingSleep, "disabling option immediately releases assertion")
        _ = power.update(preventSleep: true, transfers: [active])
        check(power.stop() == .stopped && !power.isPreventingSleep, "quit cleanup releases active assertion")
        let countBeforeStopUpdate = backend.creates.count
        check(power.update(preventSleep: true, transfers: [active]) == nil && backend.creates.count == countBeforeStopUpdate, "late refresh after quit cannot reacquire assertion")
        check(power.stop() == nil, "quit cleanup is idempotent")

        let deinitBackend = MockAssertionBackend()
        var deinitPower: SleepPreventionController? = SleepPreventionController(backend: deinitBackend)
        _ = deinitPower?.update(preventSleep: true, transfers: [active]); deinitPower = nil
        check(deinitBackend.releases == [1], "manager deinit releases owned assertion")

        let failingBackend = MockAssertionBackend(); failingBackend.createStatus = kIOReturnError
        let failingPower = SleepPreventionController(backend: failingBackend)
        check(failingPower.update(preventSleep: true, transfers: [active]) == .failed(kIOReturnError) && !failingPower.isPreventingSleep, "failed acquisition never stores invalid assertion")
        check(failingPower.update(preventSleep: true, transfers: [active]) == nil, "same acquisition failure is not logged every poll")
        failingBackend.createStatus = kIOReturnSuccess
        check(failingPower.update(preventSleep: true, transfers: [active]) == .started, "acquisition can recover on later update")
        failingBackend.releaseStatus = kIOReturnError
        check(failingPower.release() == .failed(kIOReturnError) && failingPower.isPreventingSleep, "failed release retains ownership for retry")
        failingBackend.releaseStatus = kIOReturnSuccess
        check(failingPower.release() == .stopped && !failingPower.isPreventingSleep, "release retries successfully")

        let nullBackend = MockAssertionBackend(); nullBackend.nextID = IOPMAssertionID(kIOPMNullAssertionID)
        let nullPower = SleepPreventionController(backend: nullBackend)
        check(nullPower.update(preventSleep: true, transfers: [active]) == .failed(kIOReturnError) && !nullPower.isPreventingSleep, "success result with null assertion is rejected")

        var oldPreferences = Preferences()
        oldPreferences.downloadPath = "/Volumes/Архив/Загрузки"
        oldPreferences.startImmediately = false; oldPreferences.appearance = "dark"
        oldPreferences.filterFont = 19; oldPreferences.confirmRemove = false
        oldPreferences.downLimit = 1234; oldPreferences.upLimit = 456
        oldPreferences.alternate = true; oldPreferences.altDown = 789; oldPreferences.altUp = 12
        oldPreferences.ratioLimit = 2.5; oldPreferences.connections = 333
        oldPreferences.dht = false; oldPreferences.lsd = false; oldPreferences.portMapping = false
        oldPreferences.port = 60000; oldPreferences.requireEncryption = true
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldPreferences)) as! [String: Any]
        legacy.removeValue(forKey: "preventSleepWhileDownloading")
        let migrated = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(migrated == oldPreferences, "legacy preferences.v1 migration preserves every existing setting")
        check(migrated.preventSleepWhileDownloading, "legacy record receives new sleep default")
        let minimal = try JSONDecoder().decode(Preferences.self, from: Data("{\"port\":54000,\"preventSleepWhileDownloading\":false}".utf8))
        check(minimal.port == 54000 && !minimal.preventSleepWhileDownloading && minimal.dht, "partial preferences restore present values and default missing ones")
        var disabled = oldPreferences; disabled.preventSleepWhileDownloading = false
        let roundTrip = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(disabled))
        check(roundTrip == disabled, "new disabled setting persists through encode/decode")
        let defaults = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        check(defaults == Preferences(), "empty preference record uses complete defaults")
        print("ALL \(checks) POWER/PREFERENCES CHECKS PASSED")
    }
}
