import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let ev = NSAppleEventManager.shared().currentAppleEvent,
           ev.eventID == kAEOpenApplication,
           ev.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAsLoginItem = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await Store.shared.start() }

        // Закрыли последнее окно, а приложение живёт в строке меню — убираем иконку из Dock.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, closing.canBecomeMain else { return }
            DispatchQueue.main.async {
                let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
                if !others && Store.shared.keepsRunning { NSApp.setActivationPolicy(.accessory) }
            }
        }

        // Запуск при входе в систему — без окна, только строка меню.
        if launchedAsLoginItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                for w in NSApp.windows where w.canBecomeMain && w.isVisible { w.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Store.shared.keepsRunning
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Store.shared.showMainWindow() }
        return true
    }
}

@main
struct RouteManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = Store.shared

    var body: some Scene {
        Window("RouteManager", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 880, minHeight: 560)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новый список") { store.addList() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView().environment(store)
        }

        MenuBarExtra(isInserted: Binding(get: { store.keepsRunning }, set: { _ in })) {
            MenuBarContent().environment(store)
        } label: {
            MenuBarLabel().environment(store)
        }
    }
}

struct MenuBarLabel: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: store.menuBarNeedsAttention ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
            .onAppear { store.openMainWindow = { openWindow(id: "main") } }
    }
}

struct MenuBarContent: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let auto = store.lists.filter(\.autoApply)
        Text(store.networkSummary)
        Divider()
        if auto.isEmpty {
            Text("Нет списков с автоприменением")
        } else {
            ForEach(auto) { l in Text(store.autoStatusLine(l)) }
        }
        Divider()
        Button(store.autoRunning ? "Проверяю…" : "Проверить и применить сейчас") {
            Task { await store.runAutoApply(reason: "вручную", allowPrompt: true) }
        }
        .disabled(auto.isEmpty || store.autoRunning)
        Button("Открыть RouteManager…") {
            store.openMainWindow = { openWindow(id: "main") }
            store.showMainWindow()
        }
        Divider()
        Button("Выйти из RouteManager") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
