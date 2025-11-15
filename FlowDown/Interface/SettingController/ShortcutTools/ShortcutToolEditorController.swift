//
//  ShortcutToolEditorController.swift
//  FlowDown
//
//  Created by LiBr on 15/11/2025.
//

import AlertController
import ConfigurableKit
import UIKit

final class ShortcutToolEditorController: StackScrollController {
    private var draft: ShortcutToolDraft
    var onSave: (() -> Void)?

    private lazy var nameView: ConfigurableInfoView = {
        let view = ConfigurableInfoView()
        view.configure(icon: UIImage(systemName: "character.textbox"))
        view.configure(title: String.LocalizationValue("Function Name"))
        view.configure(description: String.LocalizationValue("How this tool will be displayed to the model."))
        view.setTapBlock { [weak self] _ in
            self?.presentTextInput(
                title: String(localized: "Function Name"),
                message: String(localized: "Provide a short, action oriented name such as “Plan Vacation”."),
                placeholder: String(localized: "Plan Vacation"),
                initialValue: self?.draft.name ?? ""
            ) { value in
                self?.draft.name = value
                self?.refreshViews()
            }
        }
        return view
    }()

    private lazy var descriptionInfoView: ConfigurableInfoView = {
        let view = ConfigurableInfoView()
        view.configure(icon: UIImage(systemName: "text.justify.left"))
        view.configure(title: String.LocalizationValue("Description"))
        view.configure(description: String.LocalizationValue("Explain what this shortcut does so the model can decide when to call it."))
        view.setTapBlock { [weak self] _ in
            self?.presentTextInput(
                title: String(localized: "Shortcut Description"),
                message: String(localized: "Provide a short, action oriented name such as “Plan Vacation”."),
                placeholder: String(localized: "Plan Vacation"),
                initialValue: self?.draft.detail ?? ""
            ) { value in
                self?.draft.detail = value
                self?.refreshViews()
            }
        }
        return view
    }()

    private lazy var shortcutNameView: ConfigurableInfoView = {
        let view = ConfigurableInfoView()
        view.configure(icon: UIImage(systemName: "bolt.square"))
        view.configure(title: String.LocalizationValue("Shortcut Name"))
        view.configure(description: String.LocalizationValue("The exact name of the shortcut inside the Shortcuts app."))
        view.setTapBlock { [weak self] _ in
            self?.presentTextInput(
                title: String(localized: "Shortcut Name"),
                message: String(localized: "Use the same casing and spacing as in the Shortcuts app."),
                placeholder: String(localized: "FlowDown Helper"),
                initialValue: self?.draft.shortcutName ?? ""
            ) { value in
                self?.draft.shortcutName = value
                self?.refreshViews()
            }
        }
        return view
    }()

    private lazy var schemaView: ConfigurableInfoView = {
        let view = ConfigurableInfoView()
        view.configure(icon: UIImage(systemName: "curlybraces.square"))
        view.configure(title: String.LocalizationValue("JSON Schema"))
        view.configure(description: String.LocalizationValue("Describe the parameters this shortcut accepts."))
        view.setTapBlock { [weak self] _ in
            self?.presentSchemaEditor()
        }
        return view
    }()

    private lazy var enabledToggle: ConfigurableToggleActionView = {
        let view = ConfigurableToggleActionView()
        view.configure(icon: UIImage(systemName: "power"))
        view.configure(title: String.LocalizationValue("Enabled"))
        view.configure(description: String.LocalizationValue("Disabled shortcuts are hidden from compatible models."))
        view.actionBlock = { [weak self] value in
            self?.draft.isEnabled = value
        }
        return view
    }()

    private let schemaTemplate = """
    {
      "type": "object",
      "properties": {}
    }
    """

    init(draft: ShortcutToolDraft) {
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = draft.id == nil ? String(localized: "New Shortcut Tool") : String(localized: "Edit Shortcut Tool")
        view.backgroundColor = .background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save,
            target: self,
            action: #selector(saveTapped)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Save Shortcut Tool")

        refreshViews()
    }

    override func setupContentViews() {
        super.setupContentViews()

        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionHeaderView().with(header: String.LocalizationValue("Shortcut Tool"))
        ) { $0.bottom /= 2 }
        stackView.addArrangedSubview(SeparatorView())

        stackView.addArrangedSubviewWithMargin(nameView)
        stackView.addArrangedSubview(SeparatorView())
        stackView.addArrangedSubviewWithMargin(descriptionInfoView)
        stackView.addArrangedSubview(SeparatorView())
        stackView.addArrangedSubviewWithMargin(shortcutNameView)
        stackView.addArrangedSubview(SeparatorView())

        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionHeaderView().with(header: String.LocalizationValue("Invocation"))
        ) { $0.bottom /= 2 }
        stackView.addArrangedSubview(SeparatorView())

        stackView.addArrangedSubviewWithMargin(schemaView)
        stackView.addArrangedSubview(SeparatorView())

        stackView.addArrangedSubviewWithMargin(
            ConfigurableSectionHeaderView().with(header: String.LocalizationValue("Status"))
        ) { $0.bottom /= 2 }
        stackView.addArrangedSubview(SeparatorView())

        stackView.addArrangedSubviewWithMargin(enabledToggle)
        stackView.addArrangedSubview(SeparatorView())
    }

    @objc private func saveTapped() {
        do {
            try ShortcutToolsManager.shared.save(draft: draft)
            onSave?()
            navigationController?.popViewController(animated: true)
        } catch {
            let alert = UIAlertController(title: String(localized: "Unable to Save"), message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            present(alert, animated: true)
        }
    }

    private func refreshViews() {
        nameView.configure(value: formattedValue(draft.name, placeholder: String(localized: "Not Configured")))
        shortcutNameView.configure(value: formattedValue(draft.shortcutName, placeholder: String(localized: "Not Configured")))
        descriptionInfoView.configure(value: previewValue(for: draft.detail, placeholder: String(localized: "Not Configured")))
        schemaView.configure(value: draft.schemaJSON.isEmpty ? String(localized: "N/A") : String(localized: "Configured"))
        enabledToggle.boolValue = draft.isEnabled
    }

    private func formattedValue(_ value: String, placeholder: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? placeholder : trimmed
    }

    private func previewValue(for value: String, placeholder: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return placeholder }
        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count > 120 {
            let index = collapsed.index(collapsed.startIndex, offsetBy: 120)
            return "\(collapsed[..<index])…"
        }
        return collapsed
    }

    private func presentTextInput(
        title: String,
        message: String,
        placeholder: String,
        initialValue: String,
        onSave: @escaping (String) -> Void
    ) {
        let controller = AlertInputViewController(
            title: title,
            message: message,
            placeholder: placeholder,
            text: initialValue,
            cancelButtonText: String(localized: "Cancel"),
            doneButtonText: String(localized: "Save")
        ) { output in
            onSave(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        present(controller, animated: true)
    }

    private func presentTextEditor(
        title: String,
        initialText: String,
        builder: ((String) -> CodeEditorController)? = nil,
        onSave: @escaping (String) -> Void
    ) {
        let controller = builder?(initialText) ?? CodeEditorController(text: initialText)
        controller.title = title
        controller.collectEditedContent { output in
            onSave(output)
        }

        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .formSheet
        navigationController.preferredContentSize = .init(width: 600, height: 600)
        present(navigationController, animated: true)
    }

    private func presentSchemaEditor() {
        presentTextEditor(
            title: String(localized: "JSON Schema"),
            initialText: draft.schemaJSON.isEmpty ? schemaTemplate : draft.schemaJSON,
            builder: { JsonEditorController(text: $0) }
        ) { [weak self] output in
            self?.draft.schemaJSON = output
            self?.refreshViews()
        }
    }
}
