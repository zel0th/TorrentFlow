import Foundation
import IOKit.pwr_mgt

/// Narrow injectable wrapper: tests exercise lifecycle without changing host power state.
protocol IdleSleepAssertionBackend {
    func create(type: CFString, reason: CFString) -> (status: IOReturn, id: IOPMAssertionID)
    func release(_ id: IOPMAssertionID) -> IOReturn
}
struct SystemIdleSleepAssertionBackend: IdleSleepAssertionBackend {
    func create(type: CFString, reason: CFString) -> (status: IOReturn, id: IOPMAssertionID) {
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let status = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
        return (status, id)
    }
    func release(_ id: IOPMAssertionID) -> IOReturn { IOPMAssertionRelease(id) }
}

enum PowerManagementChange: Equatable {
    case started
    case stopped
    case failed(IOReturn)
}

/// Prevents automatic *system idle* sleep for confirmed unfinished downloads.
/// Display sleep, explicit sleep, closing the lid and low-battery sleep remain controlled by macOS.
/// AppStore calls this serially on the main actor; the lock also makes cleanup safe from deinit.
final class SleepPreventionController {
    private let backend: any IdleSleepAssertionBackend
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?
    private var stopped = false
    private var lastFailure: IOReturn?

    init(backend: any IdleSleepAssertionBackend = SystemIdleSleepAssertionBackend()) { self.backend = backend }
    deinit { stop() }

    var isPreventingSleep: Bool { lock.withLock { assertionID != nil } }

    static func isActiveDownload(_ transfer: Transfer) -> Bool {
        guard !transfer.draft, transfer.hasMetadata, transfer.error.isEmpty, !transfer.complete else { return false }
        // A temporary zero rate (searching for peers / network stall) does not finish a download.
        // Unconfirmed magnet discovery and finished seeding never acquire an assertion.
        return transfer.phase == "downloading" || transfer.phase == "checking"
    }

    @discardableResult
    func update(preventSleep: Bool, transfers: [Transfer]) -> PowerManagementChange? {
        let needed = preventSleep && transfers.contains(where: Self.isActiveDownload)
        return lock.withLock {
            guard !stopped else { return nil }
            guard needed else { return releaseLocked() }
            guard assertionID == nil else { return nil }
            let created = backend.create(
                type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                reason: "TorrentFlow — загрузка файлов" as CFString)
            if created.status == kIOReturnSuccess, created.id != IOPMAssertionID(kIOPMNullAssertionID) {
                assertionID = created.id; lastFailure = nil
                return .started
            }
            let status = created.status == kIOReturnSuccess ? kIOReturnError : created.status
            guard lastFailure != status else { return nil }
            lastFailure = status
            return .failed(status)
        }
    }

    /// Releases the current assertion; a later update may acquire a new one.
    @discardableResult
    func release() -> PowerManagementChange? { lock.withLock { releaseLocked() } }

    /// Terminal cleanup used on quit. Late refresh completions cannot acquire a new assertion.
    @discardableResult
    func stop() -> PowerManagementChange? {
        lock.withLock { stopped = true; return releaseLocked() }
    }

    private func releaseLocked() -> PowerManagementChange? {
        guard let id = assertionID else { lastFailure = nil; return nil }
        let status = backend.release(id)
        if status == kIOReturnSuccess || status == kIOReturnNotFound {
            assertionID = nil; lastFailure = nil
            return .stopped
        }
        // Retain ownership on failure so the next update/stop can retry release.
        guard lastFailure != status else { return nil }
        lastFailure = status
        return .failed(status)
    }
}
