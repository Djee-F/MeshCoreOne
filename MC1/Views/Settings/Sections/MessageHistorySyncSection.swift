import MC1Services
import SwiftUI
import UniformTypeIdentifiers

/// Settings for sharing message history between the user's own Apple devices
/// through a folder they choose — typically one in iCloud Drive.
///
/// Deliberately a plain folder rather than an app-managed iCloud container: it
/// needs no iCloud entitlement, works with any location the file picker can
/// reach, and leaves the user able to see, move, or delete the folder like any
/// other. Choosing the same folder on each device is what links them.
struct MessageHistorySyncSection: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState

  @State private var showFolderImporter = false
  @State private var showStopConfirmation = false
  @State private var errorMessage: String?

  private var isConfigured: Bool {
    appState.cloudSyncStatus != .notConfigured
  }

  var body: some View {
    Section {
      statusRow

      if appState.cloudSyncStatus == .unavailable {
        Text(L10n.Settings.HistorySync.unavailableDetail)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Button {
        showFolderImporter = true
      } label: {
        TintedLabel(
          isConfigured ? L10n.Settings.HistorySync.change : L10n.Settings.HistorySync.choose,
          systemImage: "folder"
        )
      }

      if isConfigured {
        Button {
          Task { await appState.reconcileCloudSyncFolder() }
        } label: {
          TintedLabel(L10n.Settings.HistorySync.syncNow, systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(appState.isCloudSyncReconciling)

        Button(role: .destructive) {
          showStopConfirmation = true
        } label: {
          Text(L10n.Settings.HistorySync.stop)
        }
      }

      // Surfaced because a silently skipped document would otherwise look like
      // history that simply never arrived.
      if let summary = appState.cloudSyncLastSummary, !summary.isClean {
        Text(L10n.Settings.HistorySync.someSkipped)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text(L10n.Settings.HistorySync.header)
    } footer: {
      Text(L10n.Settings.HistorySync.footer)
    }
    .themedRowBackground(theme)
    .fileImporter(
      isPresented: $showFolderImporter,
      allowedContentTypes: [.folder]
    ) { result in
      handleFolderSelection(result)
    }
    .confirmationDialog(
      L10n.Settings.HistorySync.StopConfirm.title,
      isPresented: $showStopConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Settings.HistorySync.StopConfirm.confirm, role: .destructive) {
        Task { await appState.disconnectCloudSyncFolder() }
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Settings.HistorySync.StopConfirm.message)
    }
    .task {
      await appState.refreshCloudSyncStatus()
    }
    .errorAlert($errorMessage)
  }

  // MARK: - Rows

  @ViewBuilder
  private var statusRow: some View {
    HStack {
      Text(statusText)
        .foregroundStyle(isConfigured ? .primary : .secondary)
      Spacer()
      if appState.isCloudSyncReconciling {
        ProgressView()
          .controlSize(.small)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      appState.isCloudSyncReconciling
        ? "\(statusText), \(L10n.Settings.HistorySync.checking)"
        : statusText
    )
  }

  private var statusText: String {
    switch appState.cloudSyncStatus {
    case .notConfigured:
      L10n.Settings.HistorySync.Status.notConfigured
    case .unavailable:
      L10n.Settings.HistorySync.Status.unavailable
    case .ready:
      L10n.Settings.HistorySync.Status.active(
        appState.cloudSyncFolderName ?? L10n.Settings.HistorySync.Status.notConfigured
      )
    }
  }

  // MARK: - Actions

  private func handleFolderSelection(_ result: Result<URL, any Error>) {
    switch result {
    case let .success(url):
      Task {
        if await !appState.selectCloudSyncFolder(url) {
          errorMessage = L10n.Settings.HistorySync.chooseFailed
        }
      }
    case .failure:
      // Includes plain cancellation, which is not worth an alert.
      break
    }
  }
}
