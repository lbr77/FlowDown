//
//  SceneDelegate.swift
//  FlowDown
//
//  Created by 秋星桥 on 2024/12/31.
//

import Combine
import ConfigurableKit
import Storage
import UIKit

@objc(SceneDelegate)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var cancellables = Set<AnyCancellable>()
    lazy var mainController = MainController()

    func scene(
        _ scene: UIScene, willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        #if targetEnvironment(macCatalyst)
            if let titlebar = windowScene.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbar = nil
            }
        #endif
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 650, height: 650)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = mainController
        self.window = window
        window.makeKeyAndVisible()

        for urlContext in connectionOptions.urlContexts {
            handleIncomingURL(urlContext.url)
        }
    }

    func scene(_: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for urlContext in contexts {
            handleIncomingURL(urlContext.url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        switch url.scheme {
        case "file":
            switch url.pathExtension {
            case "fdmodel", "plist":
                importModel(from: url)
            case "fdtemplate":
                importTemplate(from: url)
            case "fdmcp":
                importMCPServer(from: url)
            default: break // dont know how
            }
        case "flowdown":
            handleFlowDownURL(url)
        default:
            break
        }
    }

    private func importModel(from url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        do {
            let model = try ModelManager.shared.importCloudModel(at: url)
            mainController.queueBootMessage(text: String(localized: "Successfully imported model \(model.auxiliaryIdentifier)"))
        } catch {
            mainController.queueBootMessage(text: String(localized: "Failed to import model: \(error.localizedDescription)"))
        }
    }

    private func importTemplate(from url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        do {
            let data = try Data(contentsOf: url)
            let decoder = PropertyListDecoder()
            let template = try decoder.decode(ChatTemplate.self, from: data)
            Task { @MainActor in
                ChatTemplateManager.shared.addTemplate(template)
            }
            mainController.queueBootMessage(text: String(localized: "Successfully imported \(template.name)"))
        } catch {
            Logger.app.errorFile("failed to import template from URL: \(url), error: \(error)")
            mainController.queueBootMessage(text: String(localized: "Failed to import template: \(error.localizedDescription)"))
        }
    }

    private func importMCPServer(from url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        do {
            let data = try Data(contentsOf: url)
            let decoder = PropertyListDecoder()
            let server = try decoder.decode(ModelContextServer.self, from: data)
            Task { @MainActor in
                MCPService.shared.insert(server)
            }
            let serverName = if let serverUrl = URL(string: server.endpoint), let host = serverUrl.host {
                host
            } else if !server.name.isEmpty {
                server.name
            } else {
                "MCP Server"
            }
            mainController.queueBootMessage(text: String(localized: "Successfully imported MCP server \(serverName)"))
        } catch {
            Logger.app.errorFile("failed to import MCP server from URL: \(url), error: \(error)")
            mainController.queueBootMessage(text: String(localized: "Failed to import MCP server: \(error.localizedDescription)"))
        }
    }

    private func handleFlowDownURL(_ url: URL) {
        Logger.app.infoFile("handling incoming message: \(url)")
        guard let host = url.host(), !host.isEmpty else { return }
        switch host {
        case "new": handleNewMessageURL(url)
        case "shortcut": handleShortcutCallback(url)
        case "addShortcutTools": handleAddShortcutToolURL(url)
        default: break
        }
    }

    private func handleNewMessageURL(_ url: URL) {
        let pathComponents = url.pathComponents
        guard pathComponents.count >= 2 else { return }
        let encodedMessage = pathComponents[1]
        let message = encodedMessage.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mainController.queueNewConversation(text: message, shouldSend: !message.isEmpty)
    }

    private func handleShortcutCallback(_ url: URL) {
        ShortcutToolsManager.shared.handleCallbackURL(url)
    }

    private func handleAddShortcutToolURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var draft = ShortcutToolDraft.empty
        var icloudURLString: String?
        draft.isEnabled = true
        if let items = components.queryItems {
            for item in items {
                guard let value = item.value else { continue }
                switch item.name.lowercased() {
                case "name":
                    draft.name = value
                case "description":
                    draft.detail = value
                case "shortcut", "shortcutname":
                    draft.shortcutName = value
                case "schema":
                    draft.schemaJSON = value
                case "enabled":
                    draft.isEnabled = (value as NSString).boolValue
                case "icloudurl":
                    icloudURLString = value
                default:
                    continue
                }
            }
        }
        if
            let icloudURLString,
            !icloudURLString.isEmpty,
            let shortcutURL = URL(string: icloudURLString)
        {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let alert = UIAlertController(
                    title: String(localized: "Open Shortcut"),
                    message: String(localized: "Would you like to open iCloud to download this shortcut?"),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
                alert.addAction(UIAlertAction(title: String(localized: "Open"), style: .default) { _ in
                    UIApplication.shared.open(shortcutURL)
                })
                presentFromTop(alert)
            }
        }
        ShortcutToolsManager.shared.queueExternalDraft(draft)
        Task { @MainActor [weak self] in
            guard let self else { return }
            SettingController.setNextEntryPage(.shortcutTools)
            let controller = SettingController()
            if mainController.presentedViewController == nil {
                mainController.present(controller, animated: true)
            } else {
                mainController.dismiss(animated: true) {
                    self.mainController.present(controller, animated: true)
                }
            }
        }
    }

    func sceneDidDisconnect(_: UIScene) {}

    func sceneDidBecomeActive(_: UIScene) {}

    func sceneWillResignActive(_: UIScene) {}

    func sceneWillEnterForeground(_: UIScene) {}

    func sceneDidEnterBackground(_: UIScene) {}

    @MainActor
    private func presentFromTop(_ controller: UIViewController) {
        guard let root = window?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(controller, animated: true)
    }
}
