import AppKit
import SwiftUI

private enum ScanFilter: String, CaseIterable, Identifiable {
    case all, caches, dependencies, tools, ignored
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .all: "All findings"
        case .caches: "Caches & builds"
        case .dependencies: "Project dependencies"
        case .tools: "Tools & containers"
        case .ignored: "Ignored"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .caches: "shippingbox"
        case .dependencies: "folder.badge.gearshape"
        case .tools: "terminal"
        case .ignored: "eye.slash"
        }
    }
}

struct ContentView: View {
    @State private var model = CleanerModel()
    @State private var filter: ScanFilter? = .all
    @State private var selection: String?
    @State private var search = ""
    @State private var showingIssues = false

    private var visibleFindings: [Finding] {
        model.findings.filter { item in
            let ignored = model.ignored.contains(item.id)
            let matches = switch filter ?? .all {
            case .all: !ignored
            case .ignored: ignored
            case .caches: !ignored && item.category == .caches
            case .dependencies: !ignored && item.category == .dependencies
            case .tools: !ignored && item.category == .tools
            }
            return matches && (search.isEmpty || "\(item.title) \(item.ecosystem) \(item.id)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationSplitView {
            CleanerSidebar(filter: $filter, showingAccess: $showingIssues)
                .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 300)
        } content: {
            VStack(spacing: 0) {
                ScanOverview(findings: model.findings.filter { !model.ignored.contains($0.id) }, completedAt: model.completedAt)
                Divider()
                FindingsPanel(items: visibleFindings, selection: $selection, isScanning: model.isScanning,
                              hasScanned: model.completedAt != nil, filter: filter ?? .all,
                              progress: model.progress, scan: model.scan)
                    .frame(maxHeight: .infinity)
                ScanFooter(model: model, showingIssues: $showingIssues)
            }
            .frame(minWidth: 440, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Storage audit")
            .navigationSplitViewColumnWidth(min: 360, ideal: 490)
            .searchable(text: $search, prompt: "Find a tool, project, or path")
        } detail: {
            if let item = visibleFindings.first(where: { $0.id == selection }) {
                FindingInspector(item: item, ignored: model.ignored.contains(item.id), toggleIgnored: { model.toggleIgnored(item) })
            } else {
                ContentUnavailableView("A little context before cleanup", systemImage: "terminal",
                                       description: Text("Select a finding to see what it is, what removal means, and a command you can review."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Storage audit")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    Button("Cancel scan", systemImage: "stop.circle", action: model.cancel)
                } else {
                    Button("Scan this Mac", systemImage: "viewfinder", action: model.scan)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .onDisappear { model.cancel() }
        .tint(.teal)
        .sheet(isPresented: $showingIssues) {
            ScanIssuesView(issues: model.issues, inaccessibleLocations: model.inaccessibleLocations, isSandboxedBuild: model.isSandboxedBuild, openSettings: model.openPrivacySettings)
        }
    }
}

private struct CleanerSidebar: View {
    @Binding var filter: ScanFilter?
    @Binding var showingAccess: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.title).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacDevCleaner").font(.headline)
                    Text("Make room for what’s next.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 24)
            List(selection: $filter) {
                Section("YOUR STORAGE") {
                    ForEach(ScanFilter.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("SCAN SCOPE") {
                    Label("This Mac", systemImage: "desktopcomputer")
                    Text("Startup disk & local drives")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Scan access…", systemImage: "lock.shield") { showingAccess = true }
                }
            }
            .listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 8) {
                Label("You’re in control", systemImage: "hand.raised")
                    .font(.subheadline.weight(.medium))
                Text("Read-only scans. Local results. Commands run only when you run them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.teal.opacity(0.07))
        }
    }
}

private struct ScanOverview: View {
    let findings: [Finding]
    let completedAt: Date?
    private var bytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A clearer view of your dev storage").font(.title2.weight(.semibold))
                    Text("Find the leftovers. Understand the tradeoffs.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "internaldrive").font(.largeTitle).foregroundStyle(.teal)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(completedAt == nil ? "—" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                Text("developer storage found").font(.caption).foregroundStyle(.secondary)
            }
            Text("Measured file allocation, not guaranteed reclaimable space. Shared files and APFS snapshots can affect recovery.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(FindingCategory.allCases) { category in
                    CategoryMetric(category: category, bytes: findings.filter { $0.category == category }.reduce(0) { $0 + $1.bytes })
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.teal.opacity(0.045))
    }
}

private struct CategoryMetric: View {
    let category: FindingCategory
    let bytes: Int64
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: category.symbol).foregroundStyle(.teal)
            Text(category.title).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 85, alignment: .topLeading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct FindingsPanel: View {
    let items: [Finding]
    @Binding var selection: String?
    let isScanning: Bool
    let hasScanned: Bool
    let filter: ScanFilter
    let progress: ScanProgress
    let scan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(filter.title).font(.headline)
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Largest first").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            if isScanning {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Scanning this Mac…").font(.headline)
                    Text("\(progress.directoriesVisited.formatted()) folders checked · \(progress.findingsCount.formatted()) findings")
                        .font(.subheadline).monospacedDigit()
                    Text(progress.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).padding(.horizontal, 24)
                    Text("Large dependency trees can take a moment.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label(hasScanned ? "Nothing here" : "Make room for your next project", systemImage: hasScanned ? "checkmark.circle" : "desktopcomputer")
                } description: {
                    Text(hasScanned ? "No matching findings. Try another category or check scan access for coverage limitations." : "Find developer caches, dependencies, and tools across this Mac. No folders to choose. You decide what to clean.")
                } actions: {
                    Button(hasScanned ? "Scan again" : "Scan this Mac", systemImage: "viewfinder", action: scan)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items, selection: $selection) { item in
                    FindingRow(item: item).tag(item.id)
                }.listStyle(.inset)
            }
        }
    }
}

private struct FindingRow: View {
    let item: Finding
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.category.symbol)
                .font(.title3).foregroundStyle(.teal)
                .frame(width: 38, height: 42)
                .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.ecosystem).font(.caption).foregroundStyle(.secondary)
                Text(item.url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                Text(item.displaySize).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(item.incomplete ? "Partial size" : item.inspectionCommand != nil ? "Review usage" : "Regenerable")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }
}

private struct ScanFooter: View {
    let model: CleanerModel
    @Binding var showingIssues: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isSandboxedBuild {
                Button { showingIssues = true } label: {
                    Label("This build has limited scan access", systemImage: "lock.shield")
                }.buttonStyle(.plain).foregroundStyle(.orange)
            }
            if !model.issues.isEmpty {
                Button { showingIssues = true } label: {
                    Label("\(model.inaccessibleLocations.formatted()) locations couldn’t be read — review access", systemImage: "exclamationmark.circle")
                }.buttonStyle(.plain).foregroundStyle(.orange)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if let date = model.completedAt {
                HStack {
                    Text("Last completed scan")
                    Text(date, format: .dateTime.hour().minute())
                    Text("· \(model.volumesScanned) local volumes")
                }.font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(.bar)
    }
}

private struct FindingInspector: View {
    let item: Finding
    let ignored: Bool
    let toggleIgnored: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: item.category.symbol).font(.largeTitle).foregroundStyle(.teal)
                    Text(item.ecosystem).font(.subheadline).foregroundStyle(.secondary)
                    Text(item.title).font(.title.weight(.semibold))
                    Text(item.displaySize).font(.system(.title, design: .rounded, weight: .medium)).monospacedDigit()
                    Label(item.incomplete ? "Partial measurement" : "Measured on disk", systemImage: "internaldrive")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DetailSection(title: "What you’re looking at", text: item.explanation)
                DetailSection(title: "Before you decide", text: item.consequence)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Location").font(.headline)
                    Text(item.url.path).font(.caption.monospaced()).textSelection(.enabled)
                    if let date = item.modified {
                        LabeledContent("Directory modified") { Text(date, format: .dateTime.year().month().day()) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Modification time is a clue, not proof of inactivity.").font(.caption).foregroundStyle(.secondary)
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                }
                CommandCard(command: item.command, isInspection: item.inspectionCommand != nil)
                    .id(item.id)
                Button(ignored ? "Restore finding" : "Ignore this finding", systemImage: ignored ? "eye" : "eye.slash", action: toggleIgnored)
                    .frame(maxWidth: .infinity)
                Text("After running a command yourself, scan again to refresh these results.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .frame(minWidth: 300)
        .background(.background)
    }
}

private struct DetailSection: View {
    let title: LocalizedStringResource
    let text: LocalizedStringResource
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CommandCard: View {
    let command: String
    let isInspection: Bool
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isInspection ? "Inspect in Terminal" : "Cleanup command", systemImage: "terminal")
                .font(.headline)
            Text(command).font(.callout.monospaced()).textSelection(.enabled)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            Text(isInspection ? "This command lists information. Use the owning tool to choose what to remove." : "Interactive removal asks before deleting files. Review the exact path and back up local changes. Deletion bypasses Trash.")
                .font(.caption).foregroundStyle(.secondary)
            Button(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(16)
        .background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ScanIssuesView: View {
    let issues: [String]
    let inaccessibleLocations: Int
    let isSandboxedBuild: Bool
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Scan access & coverage", systemImage: "lock.shield").font(.title2.bold())
            Text("The scan searches the startup disk and mounted local drives for supported developer storage. System directories, app bundles, backups, network drives, and symbolic links are skipped.")
                .foregroundStyle(.secondary)
            if isSandboxedBuild {
                Label("This build uses App Sandbox", systemImage: "exclamationmark.shield").font(.headline)
                Text("Automatic whole-Mac coverage requires a build without App Sandbox. Full Disk Access does not remove the sandbox restriction.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("For broader access, open System Settings → Privacy & Security → Full Disk Access and enable MacDevCleaner. Relaunch the app, then scan again. macOS permissions can still prevent reading some locations.")
                .font(.subheadline)
            Button("Open System Settings", systemImage: "gear", action: openSettings)
            Divider()
            Text("\(inaccessibleLocations.formatted()) locations could not be read in the last completed scan.")
                .font(.headline)
            Text("Unreadable files are excluded from totals. Notes below include measurement limitations; at most 100 traversal errors per volume are listed.")
                .font(.caption).foregroundStyle(.secondary)
            List(issues, id: \.self) { issue in
                Text(issue).font(.caption.monospaced()).textSelection(.enabled)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(24).frame(width: 680, height: 650)
    }
}

#Preview {
    ContentView()
        .frame(width: 1280, height: 820)
}
