//
//  CloudModelEditorController+OpenAIOAuth.swift
//  FlowDown
//
//  Created by LiBr on 2026/4/19.
//

import AlertController
import ConfigurableKit
import Foundation
import Storage
import UIKit

extension CloudModelEditorController {
    func makeOpenAIOAuthView(model _: CloudModel?) -> ConfigurableInfoView {
        let view = ConfigurableInfoView().setTapBlock { [weak self] tappedView in
            guard let self else { return }
            Task { @MainActor in
                self.presentOpenAIOAuthSessionAlert(from: tappedView)
            }
        }

        view.configure(icon: .init(systemName: "person.crop.circle.badge.checkmark"))
        view.configure(title: String(localized: "ChatGPT OAuth Session"))
        view.configure(description: String(localized: "FlowDown refreshes and applies ChatGPT OAuth credentials automatically for this endpoint."))
        view.configure(value: String(localized: "Disconnected"))
        refreshOpenAIOAuthView(view)
        return view
    }

    func promptForOpenAIOAuthIfNeeded(using endpoint: String) {
        guard CloudModel.isOpenAICodexOAuthEndpoint(endpoint) else { return }

        Task { [weak self] in
            guard let self else { return }
            let hasCredentials = await OpenAIOAuthService.shared.hasCredentials()
            let isAuthenticating = await OpenAIOAuthService.shared.isAuthenticating()
            if hasCredentials || isAuthenticating {
                await MainActor.run {
                    self.rerenderContent()
                }
                return
            }

            await MainActor.run {
                self.presentOpenAIOAuthPrompt()
            }
        }
    }

    func refreshOpenAIOAuthView(_ view: ConfigurableInfoView) {
        Task { [weak view] in
            let connected = await OpenAIOAuthService.shared.hasCredentials()
            let isAuthenticating = await OpenAIOAuthService.shared.isAuthenticating()
            let status = connected
                ? String(localized: "Connected")
                : (isAuthenticating
                    ? String(localized: "Awaiting Redirect URL")
                    : String(localized: "Disconnected"))
            await MainActor.run {
                view?.configure(value: status)
            }
        }
    }
}

@MainActor
private extension CloudModelEditorController {
    func presentOpenAIOAuthPrompt() {
        let alert = AlertViewController(
            title: String(localized: "ChatGPT OAuth Session"),
            message: String(localized: "FlowDown refreshes and applies ChatGPT OAuth credentials automatically for this endpoint."),
        ) { [weak self] context in
            context.addAction(title: "Cancel") {
                context.dispose()
            }
            context.addAction(title: String(localized: "Sign In to ChatGPT"), attribute: .accent) {
                context.dispose {
                    guard let self else { return }
                    Task { @MainActor in
                        await self.runOpenAIOAuthFlow(force: false)
                    }
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.topPresentedController()?.present(alert, animated: true)
        }
    }

    func presentOpenAIOAuthSessionAlert(from view: UIView) {
        Task { @MainActor in
            let connected = await OpenAIOAuthService.shared.hasCredentials()
            let isAuthenticating = await OpenAIOAuthService.shared.isAuthenticating()
            let alert = AlertViewController(
                title: String(localized: "ChatGPT OAuth Session"),
                message: String(localized: "FlowDown refreshes and applies ChatGPT OAuth credentials automatically for this endpoint."),
            ) { [weak self] context in
                context.addAction(title: "Cancel") {
                    context.dispose()
                }
                if connected {
                    context.addAction(title: String(localized: "Reconnect ChatGPT"), attribute: .accent) {
                        context.dispose {
                            guard let self else { return }
                            Task { @MainActor in
                                await self.runOpenAIOAuthFlow(force: true)
                            }
                        }
                    }
                    context.addAction(title: String(localized: "Disconnect ChatGPT")) {
                        context.dispose {
                            guard let self else { return }
                            Task { @MainActor in
                                await self.disconnectOpenAIOAuth()
                            }
                        }
                    }
                } else if isAuthenticating {
                    context.addAction(title: String(localized: "Cancel Sign In")) {
                        context.dispose {
                            guard let self else { return }
                            Task { @MainActor in
                                await OpenAIOAuthService.shared.cancelAuthorization()
                                self.rerenderContent()
                            }
                        }
                    }
                } else {
                    context.addAction(title: String(localized: "Sign In to ChatGPT"), attribute: .accent) {
                        context.dispose {
                            guard let self else { return }
                            Task { @MainActor in
                                await self.runOpenAIOAuthFlow(force: false)
                            }
                        }
                    }
                }
            }
            view.parentViewController?.present(alert, animated: true)
        }
    }

    func runOpenAIOAuthFlow(force: Bool) async {
        do {
            let authURL = try await OpenAIOAuthService.shared.beginAuthorization(force: force)
            let opened = await openAuthorizationURL(authURL)
            guard opened else {
                await OpenAIOAuthService.shared.cancelAuthorization()
                throw NSError(
                    domain: "OpenAIOAuthService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "FlowDown could not open the ChatGPT sign-in page."],
                )
            }

            try await OpenAIOAuthService.shared.awaitAuthorizationCompletion()
            Indicator.present(title: "Connected", referencingView: view)
        } catch {
            if (error as NSError).code != NSUserCancelledError {
                presentOpenAIOAuthError(error)
            }
        }

        rerenderContent()
    }

    func openAuthorizationURL(_ authorizationURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(authorizationURL, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
    }

    func disconnectOpenAIOAuth() async {
        do {
            try await OpenAIOAuthService.shared.clearCredentials()
            Indicator.present(title: "Disconnected", referencingView: view)
        } catch {
            presentOpenAIOAuthError(error)
        }
        rerenderContent()
    }

    func presentOpenAIOAuthError(_ error: Error) {
        let alert = AlertViewController(
            title: "Error",
            message: error.localizedDescription,
        ) { context in
            context.allowSimpleDispose()
            context.addAction(title: "OK", attribute: .accent) {
                context.dispose()
            }
        }
        topPresentedController()?.present(alert, animated: true)
    }

    func topPresentedController() -> UIViewController? {
        var current: UIViewController? = self
        while let presented = current?.presentedViewController {
            current = presented
        }
        return current
    }
}
