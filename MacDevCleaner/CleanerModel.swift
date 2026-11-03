import AppKit
import Observation

/// Observable view model coordinating scans, deletions, and state for the UI.
@MainActor @Observable
final class CleanerModel {
    /// Indicates whether the app is running as an App Sandbox build.
    let isSandboxedBuild = Bundle.main.object(forInfoDictionaryKey: "MacDevCleanerSandboxEnabled") as? String != "NO"

    /// Discovered developer storage findings from the latest scan.
    var findings: [Finding] = []

    /// Diagnostic error messages logged during scanning.
    var issues: [String] = []

    /// Indicates whether a filesystem scan is currently in progress.
    var isScanning = false

    /// Indicates whether findings are actively being re-verified.
    var isRefreshing = false

    /// Timestamp of the most recent findings refresh.
    var refreshedAt: Date?

    /// Diagnostic error messages logged during the latest refresh.
    var refreshIssues: [String] = []

    /// Count of locations that could not be rechecked during refresh.
    var refreshInaccessibleLocations = 0

    /// Tracks whether a command was copied so results refresh when returning to the app.
    var needsRefreshAfterCopy = false

    /// Indicates whether any background scan, refresh, or deletion task is active.
    var isBusy: Bool { isScanning || isRefreshing }

    /// Combined and deduplicated list of scan and refresh diagnostic issues.
    var allIssues: [String] { Array(Set(issues + refreshIssues)).sorted() }

    /// Total count of inaccessible filesystem paths across scan and refresh.
    var totalInaccessibleLocations: Int { inaccessibleLocations + refreshInaccessibleLocations }

    /// Timestamp when the most recent full scan finished.
    var completedAt: Date?

    /// Current progress snapshot of the running scan.
    var progress = ScanProgress()

    /// Count of locations that could not be accessed during the full scan.
    var inaccessibleLocations = 0

    /// Count of local disk volumes scanned in the latest run.
    var volumesScanned = 0

    /// Localized status message displayed to the user in the footer.
    var status: LocalizedStringResource = "Ready to find developer storage across this Mac."

    /// Set of finding paths hidden by the user, persisted in user defaults.
    var ignored: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredPaths") ?? [])

    /// IDs of group member items currently selected for batch deletion.
    var selectedGroupItemIDs: Set<String> = []

    /// Active background task for scanning, refreshing, or deleting.
    private var task: Task<Void, Never>?

    /// Actor instance performing filesystem traversal and size calculations.
    private let scanner = StorageScanner()

    /// Accesses or updates the selection state of a group item by ID.
    subscript(isSelected id: String) -> Bool {
        get { selectedGroupItemIDs.contains(id) }
        set {
            if newValue {
                selectedGroupItemIDs.insert(id)
            } else {
                selectedGroupItemIDs.remove(id)
            }
        }
    }

    /// Selects all non-stale member items within the specified group.
    func selectAll(in group: FindingGroup) {
        for item in group.items where !item.measurementIsStale {
            selectedGroupItemIDs.insert(item.id)
        }
    }

    /// Deselects all member items within the specified group.
    func deselectAll(in group: FindingGroup) {
        for item in group.items {
            selectedGroupItemIDs.remove(item.id)
        }
    }

    /// Returns all currently selected and non-stale findings in a group.
    func selectedItems(in group: FindingGroup) -> [Finding] {
        group.items.filter { selectedGroupItemIDs.contains($0.id) && !$0.measurementIsStale }
    }

    /// Permanently deletes selected items in a group and refreshes remaining findings.
    func deleteSelected(in group: FindingGroup) {
        let targets = selectedItems(in: group)
        guard !isBusy, !targets.isEmpty else { return }
        isRefreshing = true
        status = "Deleting \(targets.count) selected folders…"
        let previous = findings
        task = Task {
            var deleteErrors: [String] = []
            for item in targets {
                do {
                    try FileManager.default.removeItem(at: item.url)
                    selectedGroupItemIDs.remove(item.id)
                } catch {
                    do {
                        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                        selectedGroupItemIDs.remove(item.id)
                    } catch {
                        deleteErrors.append("\(item.url.path): \(error.localizedDescription)")
                    }
                }
            }
            do {
                let report = try await scanner.refresh(previous)
                try Task.checkCancellation()
                findings = report.findings
                let validIDs = Set(report.findings.map(\.id))
                selectedGroupItemIDs.formIntersection(validIDs)
                refreshIssues = report.issues + deleteErrors
                refreshInaccessibleLocations = report.inaccessibleLocations + deleteErrors.count
                refreshedAt = .now
                needsRefreshAfterCopy = false
                let removed = previous.count - findings.count
                status = deleteErrors.isEmpty
                    ? "Deleted \(removed) selected locations and refreshed results."
                    : "Some selected locations could not be deleted. Review access issues."
            } catch is CancellationError {
                status = "Cleanup canceled."
            } catch {
                refreshIssues = [error.localizedDescription] + deleteErrors
                status = "Could not refresh results after deletion."
            }
            isRefreshing = false
            task = nil
        }
    }

    /// Starts a full background scan across all local volumes.
    func scan() {
        guard !isBusy else { return }
        isScanning = true
        progress = ScanProgress()
        status = "Discovering developer storage on this Mac…"
        task = Task {
            do {
                let report = try await scanner.scanMac { [weak self] update in
                    await self?.updateProgress(update)
                }
                try Task.checkCancellation()
                findings = report.findings
                selectedGroupItemIDs = Set(report.findings.filter { $0.groupKey != nil }.map(\.id))
                refreshIssues = []
                refreshInaccessibleLocations = 0
                refreshedAt = nil
                needsRefreshAfterCopy = false
                issues = Array(Set(report.issues)).sorted()
                inaccessibleLocations = report.inaccessibleLocations
                volumesScanned = report.volumesScanned
                progress = ScanProgress(directoriesVisited: report.directoriesVisited, findingsCount: findings.count)
                completedAt = .now
                status = report.inaccessibleLocations == 0 ? "Scan complete. Review findings at your own pace." : "Scan complete. Some locations could not be read."
            } catch is CancellationError {
                status = "Scan canceled. Previous results have been kept."
            } catch {
                issues = [error.localizedDescription]
                status = "The scan could not finish."
            }
            isScanning = false
            task = nil
        }
    }

    /// Rechecks existing findings to update sizes and remove deleted items.
    func refreshResults() {
        guard !isBusy, !findings.isEmpty else { return }
        isRefreshing = true
        status = "Rechecking findings after cleanup…"
        let previous = findings
        task = Task {
            do {
                let report = try await scanner.refresh(previous)
                try Task.checkCancellation()
                findings = report.findings
                let validIDs = Set(report.findings.map(\.id))
                selectedGroupItemIDs.formIntersection(validIDs)
                refreshIssues = report.issues
                refreshInaccessibleLocations = report.inaccessibleLocations
                refreshedAt = .now
                needsRefreshAfterCopy = false
                let removed = previous.count - findings.count
                status = report.inaccessibleLocations == 0
                    ? "Results refreshed. \(removed) removed locations no longer appear."
                    : "Results refreshed. Some locations could not be rechecked."
            } catch is CancellationError {
                status = "Refresh canceled. Previous results have been kept."
            } catch {
                refreshIssues = [error.localizedDescription]
                status = "Could not refresh results. Previous results have been kept."
            }
            isRefreshing = false
            task = nil
        }
    }

    /// Marks the model to trigger an automatic refresh when returning to the app.
    func commandCopied() { needsRefreshAfterCopy = true }

    /// Refreshes results if a command was copied while outside the app.
    func refreshAfterReturning() {
        if needsRefreshAfterCopy { refreshResults() }
    }

    /// Updates the scan progress state on the main actor.
    private func updateProgress(_ update: ScanProgress) { progress = update }

    /// Cancels any currently active background scan or cleanup task.
    func cancel() { task?.cancel() }

    /// Toggles the ignored state for a finding and persists the updated set.
    func toggleIgnored(_ finding: Finding) {
        if ignored.contains(finding.id) { ignored.remove(finding.id) } else { ignored.insert(finding.id) }
        UserDefaults.standard.set(Array(ignored), forKey: "ignoredPaths")
    }

    /// Opens the macOS System Settings app to guide user permission configuration.
    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
