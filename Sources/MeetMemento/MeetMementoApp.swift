import SwiftUI

@main
struct MeetMementoApp: App {
    @NSApplicationDelegateAdaptor(MeetMementoAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MeetMemento", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.library)
                .frame(minWidth: 780, minHeight: 520)
                .onAppear {
                    appDelegate.attach(model)
                    model.start()
                }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.settings)
        } label: {
            Image(systemName: model.captureState == .recording ? "record.circle.fill" : "waveform.circle")
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
        }
    }
}

@MainActor
final class MeetMementoAppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []
    private weak var model: AppModel?
    private var isFinishingActiveRecording = false

    func attach(_ model: AppModel) {
        self.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeWindowVisibility()
        if UserDefaults.standard.bool(forKey: "recordingConsentAcknowledgedV1") {
            // A direct launch stays visible. A background login launch settles
            // into the menu bar without interrupting the user.
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard !NSApp.isActive else { return }
                NSApp.setActivationPolicy(.accessory)
                NSApp.windows.filter(\.canBecomeMain).forEach { $0.orderOut(nil) }
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        if !flag {
            NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.activeCapture != nil else { return .terminateNow }
        guard !isFinishingActiveRecording else { return .terminateLater }
        isFinishingActiveRecording = true
        Task { @MainActor in
            await model.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func observeWindowVisibility() {
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { _ in
            NSApp.setActivationPolicy(.regular)
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            NSApp.setActivationPolicy(.regular)
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                let hasVisibleMainWindow = NSApp.windows.contains {
                    $0.isVisible && $0.canBecomeMain
                }
                if !hasVisibleMainWindow {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        })
    }
}
