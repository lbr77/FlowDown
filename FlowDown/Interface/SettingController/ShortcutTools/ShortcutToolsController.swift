//
//  ShortcutToolsController.swift
//  FlowDown
//
//  Created by LiBr on 15/11/2025.
//

import Combine
import Storage
import UIKit

extension SettingController.SettingContent {
    class ShortcutToolsController: UITableViewController {
        private var tools: [ShortcutTool] = []
        private var cancellables: Set<AnyCancellable> = []

        override func viewDidLoad() {
            super.viewDidLoad()
            title = String(localized: "Shortcut Tools")
            tableView.backgroundColor = .background
            tableView.separatorColor = .separator
            tableView.register(ShortcutToolCell.self, forCellReuseIdentifier: ShortcutToolCell.reuseIdentifier)
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .add,
                target: self,
                action: #selector(addTapped)
            )

            NotificationCenter.default.publisher(for: .shortcutToolsDidChange)
                .sink { [weak self] _ in self?.reloadData() }
                .store(in: &cancellables)

            NotificationCenter.default.publisher(for: .shortcutToolDraftQueued)
                .sink { [weak self] _ in self?.presentExternalDraftIfNeeded() }
                .store(in: &cancellables)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            reloadData()
            presentExternalDraftIfNeeded()
        }

        private func reloadData() {
            tools = ShortcutToolsManager.shared.listShortcutTools()
            tableView.reloadData()
        }

        @objc private func addTapped() {
            presentEditor(with: .empty)
        }

        private func presentExternalDraftIfNeeded() {
            guard let draft = ShortcutToolsManager.shared.pollExternalDraft() else { return }
            presentEditor(with: draft)
        }

        private func presentEditor(with draft: ShortcutToolDraft) {
            let controller = ShortcutToolEditorController(draft: draft)
            controller.onSave = { [weak self] in
                self?.reloadData()
            }
            navigationController?.pushViewController(controller, animated: true)
        }

        // MARK: - Table view data source

        override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
            tools.count
        }

        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ShortcutToolCell.reuseIdentifier, for: indexPath) as? ShortcutToolCell else {
                return UITableViewCell()
            }
            let tool = tools[indexPath.row]
            cell.configure(with: tool)
            cell.onToggle = { isOn in
                ShortcutToolsManager.shared.setShortcutEnabled(id: tool.objectId, enabled: isOn)
            }
            return cell
        }

        override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            let tool = tools[indexPath.row]
            let draft = ShortcutToolsManager.shared.draft(for: tool)
            presentEditor(with: draft)
        }

        override func tableView(_: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            let tool = tools[indexPath.row]
            let deleteAction = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, completion in
                do {
                    try ShortcutToolsManager.shared.deleteShortcutTool(id: tool.objectId)
                    completion(true)
                } catch {
                    self?.presentError(error)
                    completion(false)
                }
            }
            return UISwipeActionsConfiguration(actions: [deleteAction])
        }

        private func presentError(_ error: Error) {
            let alert = UIAlertController(title: String(localized: "Error"), message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            present(alert, animated: true)
        }
    }
}

private final class ShortcutToolCell: UITableViewCell {
    static let reuseIdentifier = "ShortcutToolCell"

    let toggle = UISwitch()
    var onToggle: ((Bool) -> Void)?

    override init(style _: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        accessoryView = toggle
        selectionStyle = .none
        toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func configure(with tool: ShortcutTool) {
        textLabel?.text = tool.name
        detailTextLabel?.numberOfLines = 0
        detailTextLabel?.text = [
            tool.detail.isEmpty ? nil : tool.detail,
            String(localized: "Shortcut: \(tool.shortcutName)"),
        ]
        .compactMap(\.self)
        .joined(separator: "\n")
        toggle.isOn = tool.isEnabled && !tool.removed
    }

    @objc private func toggleChanged() {
        onToggle?(toggle.isOn)
    }
}
