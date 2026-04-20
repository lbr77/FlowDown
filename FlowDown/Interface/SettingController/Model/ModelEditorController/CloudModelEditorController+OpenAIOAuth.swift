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
            let isAuthenticating = await OpenAIOAuthService.shared.isDeviceCodeAuthorizing()
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
            let isAuthenticating = await OpenAIOAuthService.shared.isDeviceCodeAuthorizing()
            let status = connected
                ? String(localized: "Connected")
                : (isAuthenticating
                    ? String(localized: "Awaiting Device Code")
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
            let isAuthenticating = await OpenAIOAuthService.shared.isDeviceCodeAuthorizing()
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
                                await OpenAIOAuthService.shared.cancelDeviceCodeAuthorization()
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
            let session = try await OpenAIOAuthService.shared.beginDeviceCodeAuthorization(force: force)
            presentDeviceCodeAlert(session: session)
        } catch {
            if (error as NSError).code != NSUserCancelledError {
                presentOpenAIOAuthError(error)
            }
            rerenderContent()
        }
    }

    func presentDeviceCodeAlert(session: OpenAIOAuthService.DeviceCodeSession) {
        let message = String(localized: "Open the link below and enter this one-time code to sign in. The code expires in 15 minutes.")
            + "\n\n"
            + session.verificationURL
            + "\n\n"
            + session.userCode

        let alert = AlertViewController(
            title: String(localized: "Sign In with Device Code"),
            message: message,
        ) { [weak self] context in
            context.addAction(title: String(localized: "Open Link")) {
                guard let url = URL(string: session.verificationURL) else { return }
                UIApplication.shared.open(url, options: [:])
            }
            context.addAction(title: String(localized: "Copy Code")) {
                UIPasteboard.general.string = session.userCode
                guard let self else { return }
                Indicator.present(title: "Copied", referencingView: self.view)
            }
            context.addAction(title: String(localized: "Cancel")) {
                context.dispose {
                    guard let self else { return }
                    Task { @MainActor in
                        await OpenAIOAuthService.shared.cancelDeviceCodeAuthorization()
                        self.rerenderContent()
                    }
                }
            }
        }

        topPresentedController()?.present(alert, animated: true)

        Task { @MainActor [weak self, weak alert] in
            do {
                try await OpenAIOAuthService.shared.completeDeviceCodeAuthorization()
                alert?.dismiss(animated: true) { [weak self] in
                    guard let self else { return }
                    Indicator.present(title: "Connected", referencingView: self.view)
                    self.rerenderContent()
                }
            } catch is CancellationError {
                alert?.dismiss(animated: true) { [weak self] in
                    self?.rerenderContent()
                }
            } catch {
                alert?.dismiss(animated: true) { [weak self] in
                    guard let self else { return }
                    if (error as NSError).code != NSUserCancelledError {
                        self.presentOpenAIOAuthError(error)
                    }
                    self.rerenderContent()
                }
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
