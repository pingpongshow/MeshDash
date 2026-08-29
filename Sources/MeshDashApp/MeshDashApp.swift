import MeshtasticCore
import SwiftUI

@main
struct MeshDashApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.session)
                .frame(minWidth: 1000, minHeight: 640)
                .task { await model.start() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { MeshDashCommands(model: model) }

        Settings {
            PreferencesView()
                .environment(model)
                .environment(model.session)
        }
    }
}

/// Menu bar commands, so the common actions have keyboard shortcuts.
struct MeshDashCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Radio") {
            Button("Connect…") { model.isShowingConnectSheet = true }
                .keyboardShortcut("k", modifiers: [.command])
            Button("Disconnect") {
                Task { await model.session.disconnect() }
            }
            .disabled(!model.session.isConnected)

            Divider()

            Button("Reload Configuration") {
                Task { await model.session.refreshFromRadio() }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!model.session.isConnected)

            Button("Set Radio Clock to This Mac") {
                Task { await model.session.setTime() }
            }
            .disabled(!model.session.isConnected)

            Divider()

            Button("Reboot Radio") {
                Task { await model.session.reboot() }
            }
            .disabled(!model.session.isConnected)
        }

        CommandMenu("Go") {
            ForEach(SidebarSection.allCases) { section in
                Button(section.title) { model.sidebarSelection = section }
            }
        }
    }
}
