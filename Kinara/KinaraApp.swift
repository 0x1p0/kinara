import AppKit

@main
@MainActor
enum KinaraApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        installMenus(settingsTarget: delegate)
        // NSApplication's delegate is weak. Keep the owner of the status item
        // and the one Settings window alive for the complete application run.
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func installMenus(settingsTarget: AppDelegate) {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        let applicationMenu = submenu("Kinara", in: mainMenu)
        applicationMenu.addItem(withTitle: "About Kinara", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        let settingsItem = applicationMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        settingsItem.target = settingsTarget
        let controlsItem = applicationMenu.addItem(withTitle: "Show Controls", action: #selector(AppDelegate.showQuickControls), keyEquivalent: "1")
        controlsItem.target = settingsTarget
        let updateItem = applicationMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
        updateItem.target = settingsTarget
        let welcomeItem = applicationMenu.addItem(withTitle: "Getting Started…", action: #selector(AppDelegate.showGettingStarted), keyEquivalent: "")
        welcomeItem.target = settingsTarget
        applicationMenu.addItem(.separator())
        NSApp.servicesMenu = submenu("Services", in: applicationMenu)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide Kinara", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = applicationMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Kinara", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = submenu("File", in: mainMenu)
        // A normal responder-chain action handles both the native Settings
        // window and any sheet. There is no app-wide key-event interception.
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = submenu("Edit", in: mainMenu)
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = submenu("Window", in: mainMenu)
        NSApp.windowsMenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    }

    private static func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = parent.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }
}
