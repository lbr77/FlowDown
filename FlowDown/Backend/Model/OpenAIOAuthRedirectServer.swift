//
//  OpenAIOAuthRedirectServer.swift
//  FlowDown
//
//  Created by LiBr on 2026/4/19.
//

import Foundation
import Network

actor OpenAIOAuthRedirectServer {
    private enum RedirectError: LocalizedError {
        case cancelled
        case unableToDeterminePort
        case listenerFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                "OpenAI OAuth sign-in was cancelled."
            case .unableToDeterminePort:
                "FlowDown could not determine the local callback port for OpenAI OAuth."
            case let .listenerFailed(message):
                "FlowDown could not start the local OpenAI OAuth callback server: \(message)"
            }
        }
    }

    private let callbackPath: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "wiki.qaq.flowdown.openai.oauth.callback")

    private var hasStarted = false
    private var isCancelled = false
    private var redirectURL: URL?
    private var receivedCallbackURL: URL?
    private var startWaiters: [CheckedContinuation<URL, Error>] = []
    private var callbackWaiters: [CheckedContinuation<URL, Error>] = []

    init(callbackPath: String = "/auth/callback") throws {
        self.callbackPath = callbackPath
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> URL {
        if let redirectURL {
            return redirectURL
        }

        if isCancelled {
            throw RedirectError.cancelled
        }

        return try await withCheckedThrowingContinuation { continuation in
            startWaiters.append(continuation)
            guard hasStarted == false else { return }

            hasStarted = true
            listener.stateUpdateHandler = { [weak self] state in
                Task {
                    await self?.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task {
                    await self?.accept(connection)
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallbackURL() async throws -> URL {
        if let receivedCallbackURL {
            return receivedCallbackURL
        }

        if isCancelled {
            throw RedirectError.cancelled
        }

        return try await withCheckedThrowingContinuation { continuation in
            callbackWaiters.append(continuation)
        }
    }

    func cancel() {
        guard isCancelled == false else { return }
        isCancelled = true
        listener.cancel()
        resumeStartWaiters(with: .failure(RedirectError.cancelled))
        resumeCallbackWaiters(with: .failure(RedirectError.cancelled))
    }
}

private extension OpenAIOAuthRedirectServer {
    func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                let error = RedirectError.unableToDeterminePort
                resumeStartWaiters(with: .failure(error))
                resumeCallbackWaiters(with: .failure(error))
                listener.cancel()
                return
            }

            let redirectURL = URL(string: "http://localhost:\(port)\(callbackPath)")!
            self.redirectURL = redirectURL
            resumeStartWaiters(with: .success(redirectURL))
        case let .failed(error):
            let wrapped = RedirectError.listenerFailed(error.localizedDescription)
            resumeStartWaiters(with: .failure(wrapped))
            resumeCallbackWaiters(with: .failure(wrapped))
        case .cancelled:
            let error = RedirectError.cancelled
            resumeStartWaiters(with: .failure(error))
            resumeCallbackWaiters(with: .failure(error))
        default:
            break
        }
    }

    func accept(_ connection: NWConnection) {
        guard isCancelled == false else {
            connection.cancel()
            return
        }

        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task {
                await self?.handleReceive(
                    data: data,
                    isComplete: isComplete,
                    error: error,
                    on: connection,
                    buffer: buffer
                )
            }
        }
    }

    func handleReceive(
        data: Data?,
        isComplete: Bool,
        error: NWError?,
        on connection: NWConnection,
        buffer: Data
    ) {
        guard isCancelled == false else {
            connection.cancel()
            return
        }

        guard error == nil else {
            connection.cancel()
            return
        }

        var accumulated = buffer
        if let data {
            accumulated.append(data)
        }

        if accumulated.containsHTTPHeaderTerminator || isComplete {
            processRequest(accumulated, on: connection)
            return
        }

        receiveRequest(on: connection, buffer: accumulated)
    }

    func processRequest(_ data: Data, on connection: NWConnection) {
        guard let redirectURL,
              let requestText = String(data: data, encoding: .utf8),
              let requestLine = requestText.components(separatedBy: "\r\n").first
        else {
            respond(on: connection, statusCode: 400, reason: "Bad Request", body: invalidRequestHTML)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(on: connection, statusCode: 400, reason: "Bad Request", body: invalidRequestHTML)
            return
        }

        let requestTarget = String(parts[1])
        guard let components = URLComponents(string: requestTarget) else {
            respond(on: connection, statusCode: 400, reason: "Bad Request", body: invalidRequestHTML)
            return
        }

        guard components.path == callbackPath else {
            respond(on: connection, statusCode: 404, reason: "Not Found", body: notFoundHTML)
            return
        }

        let absoluteURL = URL(string: "http://localhost:\(redirectURL.port ?? 0)\(requestTarget)")!
        if receivedCallbackURL == nil {
            receivedCallbackURL = absoluteURL
            resumeCallbackWaiters(with: .success(absoluteURL))
        }

        // Keep the browser response self-contained so the app can finish OAuth in the background.
        respond(on: connection, statusCode: 200, reason: "OK", body: successHTML)
    }

    func respond(on connection: NWConnection, statusCode: Int, reason: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = """
        HTTP/1.1 \(statusCode) \(reason)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r
        """

        var responseData = Data(header.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func resumeStartWaiters(with result: Result<URL, Error>) {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    func resumeCallbackWaiters(with result: Result<URL, Error>) {
        let waiters = callbackWaiters
        callbackWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    var successHTML: String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>FlowDown Sign-In Complete</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; background: #f5f5f7; color: #111827; }
            main { max-width: 32rem; margin: 12vh auto; padding: 2rem; background: white; border-radius: 1rem; box-shadow: 0 18px 48px rgba(15, 23, 42, 0.12); }
            h1 { margin: 0 0 0.75rem; font-size: 1.6rem; }
            p { margin: 0; line-height: 1.6; color: #4b5563; }
          </style>
        </head>
        <body>
          <main>
            <h1>Sign-in received</h1>
            <p>FlowDown is finishing your ChatGPT OAuth sign-in. You can return to the app.</p>
          </main>
        </body>
        </html>
        """
    }

    var invalidRequestHTML: String {
        """
        <!doctype html>
        <html lang="en">
        <body>
          <p>FlowDown could not read this OAuth callback request.</p>
        </body>
        </html>
        """
    }

    var notFoundHTML: String {
        """
        <!doctype html>
        <html lang="en">
        <body>
          <p>FlowDown is listening for an OAuth callback on a different path.</p>
        </body>
        </html>
        """
    }
}

private extension Data {
    var containsHTTPHeaderTerminator: Bool {
        range(of: Data("\r\n\r\n".utf8)) != nil
    }
}
