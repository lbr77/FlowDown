import AlertController
import Combine
import ConfigurableKit
import Storage
import UIKit

class MCPEditorController: StackScrollController {
    let clientId: ModelContextClient.ID
    @Published private var client: ModelContextClient?
    var cancellables: Set<AnyCancellable> = .init()
    private let toolsSectionStackView = UIStackView() // view for tools (to be hidden together.)

    init(clientId: ModelContextClient.ID) {
        self.clientId = clientId
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Edit MCP Client")
        client = MCPService.shared.client(with: clientId)
        assert(client != nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .background

        navigationItem.rightBarButtonItem = .init(
            image: UIImage(systemName: "checkmark"),
            style: .done,
            target: self,
            action: #selector(checkTapped)
        )

        MCPService.shared.clients
            .removeDuplicates()
            .ensureMainThread()
            .delay(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] clients in
                guard let self, isVisible else { return }
                if !clients.contains(where: { $0.id == self.clientId }) {
                    navigationController?.popViewController(animated: true)
                }
            }
            .store(in: &cancellables)
    }

    @objc func checkTapped() {
        navigationController?.popViewController(animated: true)
    }

    @objc func deleteTapped() {
        let alert = AlertViewController(
            title: String(localized: "Delete Client"),
            message: String(localized: "Are you sure you want to delete this model context protocol client? This action cannot be undone.")
        ) { context in
            context.addAction(title: String(localized: "Cancel")) {
                context.dispose()
            }
            context.addAction(title: String(localized: "Delete"), attribute: .dangerous) {
                context.dispose { [weak self] in
                    guard let self else { return }
                    MCPService.shared.remove(clientId)
                    navigationController?.popViewController(animated: true)
                }
            }
        }
        present(alert, animated: true)
    }

    override func setupContentViews() {
        super.setupContentViews()

        guard let client else { return }

        // MARK: - Enabled

        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionHeaderView()
                .with(header: String(localized: "Enabled"))
        ) { $0.bottom /= 2 }
        let enabledView = ConfigurableToggleActionView()
        enabledView.boolValue = client.isEnabled
        enabledView.actionBlock = { value in
            MCPService.shared.edit(identifier: self.clientId) { client in
                client.isEnabled = value
            }
            UIView.animate(withDuration: 0.3) {
                self.toolsSectionStackView.isHidden = !value
            }
        }
        enabledView.configure(icon: .init(systemName: "power"))
        enabledView.configure(title: String(localized: "Enabled"))
        enabledView.configure(description: String(localized: "Whether this model context protocol server is enabled."))
        stackView.addArrangedSubviewWithMargin(enabledView)
        stackView.addArrangedSubview(SeparatorView())
        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionFooterView()
                .with(footer: String(localized: "When enabled, this client will participate in Model Context Protocol operations. When disabled, all related requests will be ignored."))
        ) { $0.top /= 2 }
        stackView.addArrangedSubview(SeparatorView())

        // MARK: - Metadata

        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionHeaderView()
                .with(header: String(localized: "Metadata"))
        ) { $0.bottom /= 2 }
        let nameView = ConfigurableInfoView().setTapBlock { view in
            let input = AlertInputViewController(
                title: String(localized: "Edit Name"),
                message: String(localized: "The display name of this model context protocol client."),
                placeholder: String(localized: "Unnamed MCP"),
                text: client.name
            ) { output in
                MCPService.shared.edit(identifier: self.clientId) { client in
                    client.name = output
                }
                view.configure(value: output.isEmpty ? String(localized: "Unnamed Server") : output)
            }
            view.parentViewController?.present(input, animated: true)
        }
        nameView.configure(icon: .init(systemName: "tag"))
        nameView.configure(title: String(localized: "Name"))
        nameView.configure(description: String(localized: "The display name of this model context protocol client."))
        nameView.configure(value: client.name.isEmpty ? String(localized: "Unnamed Server") : client.name)
        stackView.addArrangedSubviewWithMargin(nameView)
        stackView.addArrangedSubview(SeparatorView())

        // MARK: - Connection

        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionHeaderView()
                .with(header: String(localized: "Connection"))
        ) { $0.bottom /= 2 }
        let typeView = ConfigurableInfoView()
        typeView.configure(icon: .init(systemName: "gear"))
        typeView.configure(title: String(localized: "Connection Type"))
        typeView.configure(description: String(localized: "The transport protocol to use for this client."))
        typeView.configure(value: client.type.rawValue.uppercased())
        typeView.setTapBlock { view in
            let children = [
                UIAction(
                    title: "HTTP",
                    image: UIImage(systemName: "network")
                ) { _ in
                    MCPService.shared.edit(identifier: self.clientId) { client in
                        client.type = .http
                    }
                    view.configure(value: "HTTP")
                },
                UIAction(
                    title: "SSE",
                    image: UIImage(systemName: "antenna.radiowaves.left.and.right")
                ) { _ in
                    MCPService.shared.edit(identifier: self.clientId) { client in
                        client.type = .sse
                    }
                    view.configure(value: "SSE")
                },
            ]
            view.present(
                menu: .init(title: String(localized: "Connection Type"), children: children),
                anchorPoint: .init(x: view.bounds.maxX, y: view.bounds.maxY)
            )
        }
        stackView.addArrangedSubviewWithMargin(typeView)
        stackView.addArrangedSubview(SeparatorView())

        let endpointView = ConfigurableInfoView().setTapBlock { view in
            let input = AlertInputViewController(
                title: String(localized: "Edit Endpoint"),
                message: String(localized: "The URL endpoint for this model context protocol client."),
                placeholder: "https://",
                text: client.endpoint.isEmpty ? "https://" : client.endpoint
            ) { output in
                MCPService.shared.edit(identifier: self.clientId) { client in
                    client.endpoint = output
                }
                view.configure(value: output.isEmpty ? String(localized: "Not Configured") : output)
            }
            view.parentViewController?.present(input, animated: true)
        }
        endpointView.configure(icon: .init(systemName: "link"))
        endpointView.configure(title: String(localized: "Endpoint"))
        endpointView.configure(description: String(localized: "The URL endpoint for this model context protocol client."))
        endpointView.configure(value: client.endpoint.isEmpty ? String(localized: "Not Configured") : client.endpoint)
        stackView.addArrangedSubviewWithMargin(endpointView)
        stackView.addArrangedSubview(SeparatorView())

        let headerView = ConfigurableInfoView().setTapBlock { view in
            guard let client = MCPService.shared.client(with: self.clientId) else { return }
            var text = client.header
            if text.isEmpty { text = "{}" }
            let textEditor = JsonStringMapEditorController(text: text)
            textEditor.title = String(localized: "Edit Headers")
            textEditor.collectEditedContent { result in
                guard let object = try? JSONDecoder().decode([String: String].self, from: result.data(using: .utf8) ?? .init()) else {
                    return
                }
                let jsonData = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
                let jsonString = String(data: jsonData ?? Data(), encoding: .utf8) ?? ""
                MCPService.shared.edit(identifier: self.clientId) { client in
                    client.header = jsonString == "{}" ? "" : jsonString
                }
                view.configure(value: object.isEmpty ? String(localized: "No Headers") : String(localized: "Configured"))
            }
            view.parentViewController?.navigationController?.pushViewController(textEditor, animated: true)
        }
        headerView.configure(icon: .init(systemName: "list.bullet"))
        headerView.configure(title: String(localized: "Headers"))
        headerView.configure(description: String(localized: "This value will be added to the request as additional header."))
        headerView.configure(value: client.header.isEmpty ? String(localized: "No Headers") : String(localized: "Configured"))
        stackView.addArrangedSubviewWithMargin(headerView)
        stackView.addArrangedSubview(SeparatorView())

        let timeoutView = ConfigurableInfoView().setTapBlock { view in
            let input = AlertInputViewController(
                title: String(localized: "Edit Timeout"),
                message: String(localized: "Request timeout in seconds."),
                placeholder: "60",
                text: "\(client.timeout)"
            ) { output in
                let timeout = Int(output) ?? 60
                MCPService.shared.edit(identifier: self.clientId) { client in
                    client.timeout = timeout
                }
                view.configure(value: "\(timeout)s")
            }
            view.parentViewController?.present(input, animated: true)
        }
        timeoutView.configure(icon: .init(systemName: "timer"))
        timeoutView.configure(title: String(localized: "Timeout"))
        timeoutView.configure(description: String(localized: "Request timeout in seconds."))
        timeoutView.configure(value: "\(client.timeout)s")
        stackView.addArrangedSubviewWithMargin(timeoutView)
        stackView.addArrangedSubview(SeparatorView())
        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionFooterView()
                .with(footer: String(localized: "Please fill in the connection parameters according to your server configuration to ensure the client can communicate with the server properly."))
        ) { $0.top /= 2 }
        stackView.addArrangedSubview(SeparatorView())

        // MARK: - Test

        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionHeaderView()
                .with(header: String(localized: "Test"))
        ) { $0.bottom /= 2 }
        let testAction = ConfigurableActionView { [weak self] _ in
            guard let self else { return }
            guard let client = self.client else { return }
            Task {
                let result = await MCPService.shared.testConfiguration(properties: client)

                await MainActor.run {
                    if result {
                        Indicator.present(
                            title: String(localized: "Configuration Tested."),
                            referencingView: self.view
                        )
                    } else {
                        Indicator.present(
                            title: String(localized: "Failed"),
                            message: String(localized: "Please Check Your Configuration"),
                            preset: .error,
                            referencingView: self.view
                        )
                    }
                }
            }
        }
        testAction.configure(icon: UIImage(systemName: "wand.and.stars"))
        testAction.configure(title: String(localized: "Test Configuration"))
        testAction.configure(description: String(localized: "Test the configuration of the model context protocol server."))
        stackView.addArrangedSubviewWithMargin(testAction)
        stackView.addArrangedSubview(SeparatorView())

        // MARK: - Tools

        toolsSectionStackView.axis = .vertical
        toolsSectionStackView.spacing = stackView.spacing
        toolsSectionStackView.addArrangedSubviewWithMargin( // title
            ConfigurableSectionHeaderView()
                .with(header: String(localized: "Tools"))
        )
        if let toolsArray = MCPService.shared.tools.value[clientId], !toolsArray.isEmpty { // tools available
            for tool in toolsArray {
                // do sth.
                let enabledView = ConfigurableToggleActionView()
                enabledView.boolValue = true // TODO: Change.
                enabledView.actionBlock = { value in
//                    MCPService.shared.edit(identifier: self.clientId) { client in
//                        client.isEnabled = value
//                    } // TODO: change this here.
                }
                enabledView.configure(icon: .init(systemName: "power"))
                enabledView.configure(title: tool.interfaceName)
                enabledView.configure(description: tool.shortDescription)
                toolsSectionStackView.addArrangedSubviewWithMargin(enabledView)
            }
        } else {
            let phView = UILabel() // placeholder
            phView.text = String(localized: "No Tools Available")
            phView.text = "No tools found"
            phView.textColor = .secondaryLabel
            phView.textAlignment = .center
            phView.font = .systemFont(ofSize: 16)
            toolsSectionStackView.addArrangedSubviewWithMargin(phView) { $0.top /= 2 }
        }
        toolsSectionStackView.addArrangedSubview(SeparatorView())
        toolsSectionStackView.isHidden = !client.isEnabled
        
        stackView.addArrangedSubview(toolsSectionStackView)

//        }

        // MARK: - Management

        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionHeaderView()
                .with(header: String(localized: "Management"))
        ) { $0.bottom /= 2 }
        let deleteAction = ConfigurableActionView { [weak self] _ in
            guard let self else { return }
            deleteTapped()
        }
        deleteAction.configure(icon: UIImage(systemName: "trash"))
        deleteAction.configure(title: String(localized: "Delete Server"))
        deleteAction.configure(description: String(localized: "Delete this model context protocol server permanently."))
        deleteAction.titleLabel.textColor = .systemRed
        deleteAction.iconView.tintColor = .systemRed
        deleteAction.descriptionLabel.textColor = .systemRed
        deleteAction.imageView.tintColor = .systemRed
        stackView.addArrangedSubviewWithMargin(deleteAction)
        stackView.addArrangedSubview(SeparatorView())
        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionFooterView()
                .with(footer: String(localized: "Are you sure you want to delete this model context protocol client? This action cannot be undone."))
        ) { $0.top /= 2 }
        stackView.addArrangedSubview(SeparatorView())
    }
}
