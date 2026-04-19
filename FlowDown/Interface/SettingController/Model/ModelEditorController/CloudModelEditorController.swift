//
//  CloudModelEditorController.swift
//  FlowDown
//
//  Created by 秋星桥 on 1/26/25.
//

import AlertController
import Combine
import ConfigurableKit
import Storage
import UIKit

class CloudModelEditorController: StackScrollController {
    let identifier: CloudModel.ID

    var cancellables: Set<AnyCancellable> = .init()
    weak var responseFormatInfoView: ConfigurableInfoView?

    init(identifier: CloudModel.ID) {
        self.identifier = identifier
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Edit Model")
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
        navigationItem.rightBarButtonItems = buildNavBarItems()

        ModelManager.shared.cloudModels
            .removeDuplicates()
            .ensureMainThread()
            .delay(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] values in
                guard let self, isVisible else { return }
                guard values.contains(where: { $0.id == self.identifier }) else {
                    navigationController?.popViewController(animated: true)
                    return
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openAIOAuthCredentialsDidChange)
            .ensureMainThread()
            .sink { [weak self] _ in
                guard let self, isVisible else { return }
                rerenderContent()
            }
            .store(in: &cancellables)
    }

    override func setupContentViews() {
        super.setupContentViews()
        renderContent()
    }

    @objc func checkTapped() {
        navigationController?.popViewController()
    }

    func rerenderContent() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        responseFormatInfoView = nil
        setupContentViews()
        applySeparatorConstraints()
    }

    func applySeparatorConstraints() {
        stackView
            .subviews
            .compactMap { view -> SeparatorView? in
                if view is SeparatorView {
                    return view as? SeparatorView
                }
                return nil
            }
            .forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    $0.heightAnchor.constraint(equalToConstant: 1),
                    $0.widthAnchor.constraint(equalTo: stackView.widthAnchor),
                ])
            }
    }
}

private extension CloudModelEditorController {
    func buildNavBarItems() -> [UIBarButtonItem] {
        let confirmItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            style: .done,
            target: self,
            action: #selector(checkTapped),
        )
        let actionsItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            style: .plain,
            target: nil,
            action: nil,
        )
        actionsItem.accessibilityLabel = String(localized: "More Actions")
        actionsItem.menu = buildActionsMenu()
        return [confirmItem, actionsItem]
    }
}
