import MeshtasticCore
import SwiftUI

/// App preferences, distinct from radio settings.
struct PreferencesView: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session

    var body: some View {
        @Bindable var model = model
        @Bindable var session = session

        TabView {
            Form {
                Section("Connection") {
                    Toggle("Reconnect to the last radio at launch", isOn: $model.reconnectOnLaunch)
                    Toggle("Reconnect automatically if the link drops", isOn: $session.automaticallyReconnects)
                    FieldNote("MeshDash backs off between attempts so a radio that is genuinely off does not keep the app busy.")
                }

                Section("Notifications") {
                    Toggle("Notify me about new messages", isOn: $model.notificationsEnabled)
                    FieldNote("Muted nodes and muted channels never produce a notification.")
                }

                Section("Units") {
                    Picker("Units", selection: $model.useMetricUnits) {
                        Text("Metric").tag(true)
                        Text("Imperial").tag(false)
                    }
                    .pickerStyle(.segmented)
                    FieldNote("Affects distances, altitudes, speeds and temperatures shown in MeshDash. The radio's own screen has a separate setting under Configuration › Display.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("History") {
                    Picker("Keep position and telemetry history for", selection: $model.historyRetentionDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                        Text("Forever").tag(0)
                    }
                    FieldNote("Older readings are removed when you connect. Messages and the node list are always kept until you delete them.")
                }

                Section("Database") {
                    if let url = try? MeshStore.defaultURL() {
                        DetailRow("Location", url.path(percentEncoded: false), monospaced: true)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 520, height: 400)
    }
}
