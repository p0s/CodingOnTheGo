import AppState
import Combine
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ComposerToolsCard: View {
    private enum ComposerFocusField: Hashable {
        case prompt
        case steer
    }

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsPhotoPicker = false
    @State private var promptDraft = ""
    @State private var voiceController = VoiceComposerController()
    @State private var keyboardBottomInset: CGFloat = 0
    @State private var isCompactPromptFocused = false
    @FocusState private var focusedField: ComposerFocusField?

    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: isCompactPhone ? 1 : 10) {
            if showsToolbarRow {
                toolbar
            }

            if !model.composerState.attachments.isEmpty {
                attachmentStrip
            }

            if model.activeTurnID != nil {
                steerRow
            }

            promptComposer

            if let statusText = voiceController.statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(voiceController.isRecording ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            } else if let statusDetail {
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
            }
        }
        .adaptiveGlassSurface(
            tint: AppVisualStyle.chromeTint,
            cornerRadius: isCompactPhone ? 20 : 20,
            padding: isCompactPhone ? 6 : 14
        )
        .padding(.horizontal, isCompactPhone ? 10 : 12)
        .padding(.top, isCompactPhone ? 0 : 8)
        .padding(.bottom, bottomPadding)
        .photosPicker(isPresented: $showsPhotoPicker, selection: $selectedPhoto, matching: .images)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codex-sticky-composer")
        .task(id: model.selectedMachineID) {
            if promptDraft != model.composerState.draft {
                promptDraft = model.composerState.draft
            }
            let availability = await voiceController.refreshAvailability(
                hostSupportsVoice: model.composerState.voiceInputAvailability != .unavailable
            )
            await MainActor.run {
                if model.composerState.voiceInputAvailability != .unavailable {
                    model.composerState.voiceInputAvailability = availability
                }
            }
        }
        .onAppear {
            if promptDraft != model.composerState.draft {
                promptDraft = model.composerState.draft
            }
            model.refreshModelsIfNeeded()
        }
        .onChange(of: model.composerState.draft) { _, newValue in
            if promptDraft != newValue {
                promptDraft = newValue
            }
        }
        .onChange(of: promptDraft) { _, newValue in
            if model.composerState.draft != newValue {
                model.composerState.draft = newValue
            }
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else {
                return
            }
            Task {
                let suggestedFilename = attachmentFilename(for: newValue)
                let data = try? await newValue.loadTransferable(type: Data.self)
                await MainActor.run {
                    model.addPhotoAttachment(
                        named: suggestedFilename,
                        data: data,
                        suggestedFilename: suggestedFilename
                    )
                    selectedPhoto = nil
                }
            }
        }
        .onReceive(keyboardFramePublisher) { keyboardBottomInset = $0 }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { promptDraft },
            set: { promptDraft = $0 }
        )
    }

    private var steerBinding: Binding<String> {
        Binding(
            get: { model.steerDraft },
            set: { model.steerDraft = $0 }
        )
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: isCompactPhone ? 3 : 10) {
            if !isCompactPhone {
                modelMenu
            }

            if model.threadFeatureState.queuedPromptCount > 0 {
                AppMetadataChip(
                    title: "\(model.threadFeatureState.queuedPromptCount) queued",
                    systemImage: "clock.arrow.circlepath",
                    tint: .secondary
                )
            }

            Spacer(minLength: 0)

            if !isCompactPhone {
                addMenu
                voiceControl
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.composerState.attachments) { attachment in
                    HStack(spacing: 6) {
                        Label(attachment.displayName, systemImage: attachment.kind == .photo ? "photo" : "waveform")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold))

                        Button {
                            model.composerState.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(AppVisualStyle.secondaryText)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppVisualStyle.panelBackgroundMuted, in: Capsule())
                }
            }
        }
    }

    private var steerRow: some View {
        HStack(alignment: .bottom, spacing: isCompactPhone ? 6 : 10) {
            TextField("Steer the active turn", text: steerBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...2)
                .padding(.horizontal, isCompactPhone ? 10 : 12)
                .padding(.vertical, isCompactPhone ? 6 : 10)
                .background(AppVisualStyle.panelBackgroundMuted, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($focusedField, equals: .steer)
                .accessibilityIdentifier("steer-turn-field")

            Button("Steer") {
                model.steerActiveTurn()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!model.canSteerTurn)
            .accessibilityIdentifier("steer-turn-button")
        }
    }

    private var promptComposer: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                regularPromptComposer
            } else {
                compactPromptComposer
            }
        }
    }

    private var compactPromptComposer: some View {
        HStack(alignment: .bottom, spacing: 5) {
            addMenu
                .frame(width: 32, height: 32)
            promptInputField
            voiceControl
                .frame(width: 32, height: 32)

            if model.canInterruptTurn {
                interruptButton(showsTitle: false)
                    .frame(width: 32, height: 32)
            }

            composerSendButton(minWidth: 32, minHeight: 32, showsTitle: false)
        }
    }

    private var regularPromptComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            promptInputField

            HStack {
                Spacer(minLength: 0)
                composerActionColumn(minWidth: 132, minHeight: 42, showsTitle: true)
            }
        }
    }

    @ViewBuilder
    private var promptInputField: some View {
        if isCompactPhone {
            compactPromptInputField
        } else {
            regularPromptInputField
        }
    }

    private var compactPromptInputField: some View {
        ZStack(alignment: .topLeading) {
            if promptDraft.isEmpty {
                Text("Message Codex")
                    .font(.subheadline)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }

#if canImport(UIKit)
            PromptTextView(
                text: draftBinding,
                isFocused: promptFocusBinding,
                onSubmit: submitComposerDraft
            )
            .frame(minHeight: 32, maxHeight: 54)
            .accessibilityIdentifier("session-prompt-field")
#else
            regularPromptInputField
#endif
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 0)
    }

    private var regularPromptInputField: some View {
        TextField("Message Codex", text: draftBinding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(2...6)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppVisualStyle.panelBackgroundMuted)
            )
            .submitLabel(.send)
            .onSubmit {
                submitComposerDraft()
            }
            .focused($focusedField, equals: .prompt)
            .accessibilityIdentifier("session-prompt-field")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Hide") {
                        dismissKeyboard()
                    }
                    .accessibilityIdentifier("keyboard-dismiss-button")
                }
            }
    }

    private var promptFocusBinding: Binding<Bool> {
        Binding(
            get: {
                if isCompactPhone {
                    return isCompactPromptFocused
                }
                return focusedField == .prompt
            },
            set: { isFocused in
                if isCompactPhone {
                    isCompactPromptFocused = isFocused
                } else {
                    focusedField = isFocused ? .prompt : nil
                }
            }
        )
    }

    private func composerActionColumn(
        minWidth: CGFloat,
        minHeight: CGFloat,
        showsTitle: Bool
    ) -> some View {
        VStack(spacing: isCompactPhone ? 4 : 8) {
            if model.canInterruptTurn {
                interruptButton(showsTitle: showsTitle)
                    .frame(width: minWidth, height: minHeight)
            }

            composerSendButton(
                minWidth: minWidth,
                minHeight: minHeight,
                showsTitle: showsTitle
            )
        }
    }

    private func composerSendButton(
        minWidth: CGFloat,
        minHeight: CGFloat,
        showsTitle: Bool
    ) -> some View {
        let label = model.activeTurnID == nil ? "Send" : "Queue"

        return Group {
            if showsTitle {
                Button {
                    submitComposerDraft()
                } label: {
                    Label(label, systemImage: model.activeTurnID == nil ? "arrow.up" : "plus.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: minWidth, minHeight: minHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
            } else {
                Button {
                    submitComposerDraft()
                } label: {
                    Image(systemName: model.activeTurnID == nil ? "arrow.up" : "plus")
                        .font(.headline.weight(.bold))
                        .frame(width: minWidth, height: minHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .disabled(!model.composerState.canSend)
        .accessibilityLabel(label)
        .accessibilityIdentifier("queue-prompt-button")
    }

    private var modelMenu: some View {
        Menu {
            ForEach(model.availableModels) { descriptor in
                Button(descriptor.displayName) {
                    model.selectModel(descriptor)
                }
            }
        } label: {
            ToolbarPillLabel(
                title: model.selectedModel ?? "Model",
                systemImage: "cpu",
                showsTitle: !isCompactPhone,
                compact: isCompactPhone
            )
        }
        .accessibilityIdentifier("model-menu-button")
    }

    private func submitComposerDraft() {
        let needsCommit = focusedField == .prompt || isCompactPromptFocused
        let visibleDraft = promptDraft
        dismissKeyboard()

        if needsCommit {
            Task { @MainActor in
                await Task.yield()
                if model.composerState.draft != visibleDraft {
                    model.composerState.draft = visibleDraft
                }
                model.sendComposerDraft()
                promptDraft = model.composerState.draft
            }
        } else {
            if model.composerState.draft != visibleDraft {
                model.composerState.draft = visibleDraft
            }
            model.sendComposerDraft()
            promptDraft = model.composerState.draft
        }
    }

    private func dismissKeyboard() {
        isCompactPromptFocused = false
        focusedField = nil
    }

    private var addMenu: some View {
        Menu {
            if model.composerState.canAttachPhotos {
                Button("Attach photo") {
                    showsPhotoPicker = true
                }
            }

            Button("Refresh models") {
                model.refreshModels()
            }
            .accessibilityIdentifier("refresh-models-button")

            if model.activeSession?.threadID != nil {
                Button("Open current thread on Mac") {
                    model.openCurrentThreadInCodexOnHost()
                }

                Button("Fork current thread") {
                    model.forkCurrentThread()
                }
            }

            if model.activeSession?.workspaceRoot != nil {
                Button("New Codex Mac thread") {
                    model.openNewCodexThreadOnHost()
                }
            }
        } label: {
            ToolbarPillLabel(
                title: "Add",
                systemImage: "plus",
                showsTitle: !isCompactPhone,
                compact: isCompactPhone
            )
        }
        .accessibilityIdentifier("photo-tool-button")
    }

    private var voiceControl: some View {
        Button {
            if model.composerState.voiceInputAvailability != .unavailable {
                toggleVoiceRecording()
            }
        } label: {
            ToolbarPillLabel(
                title: voiceController.isRecording ? "Stop Voice" : "Voice",
                systemImage: voiceController.isRecording ? "waveform.circle.fill" : "mic",
                showsTitle: !isCompactPhone,
                prominence: voiceController.isRecording ? .prominent : .standard,
                isDisabled: model.composerState.voiceInputAvailability == .unavailable,
                compact: isCompactPhone
            )
        }
        .disabled(model.composerState.voiceInputAvailability == .unavailable)
        .accessibilityIdentifier("voice-tool-button")
    }

    private func interruptButton(showsTitle: Bool) -> some View {
        Button {
            model.interruptActiveTurn()
        } label: {
            ToolbarPillLabel(
                title: "Stop",
                systemImage: "stop.circle.fill",
                showsTitle: showsTitle,
                prominence: .prominent,
                compact: isCompactPhone
            )
        }
        .disabled(!model.canInterruptTurn)
        .accessibilityIdentifier("interrupt-turn-button")
    }

    private var statusDetail: String? {
        if isCompactPhone {
            return nil
        }

        switch model.composerState.voiceInputAvailability {
        case .available:
            if model.composerState.canAttachPhotos {
                return nil
            }
            return "Photo attachments are unavailable for this host."
        case .permissionRequired:
            return "Voice input needs microphone or speech permission."
        case .unavailable:
            return model.composerState.canAttachPhotos
                ? "Voice input is unavailable for this host."
                : "Voice and photo tools are unavailable for this host."
        }
    }

    private func toggleVoiceRecording() {
        Task {
            let availability = await voiceController.toggleRecording { transcript in
                model.appendVoiceTranscript(transcript)
            }
            await MainActor.run {
                model.composerState.voiceInputAvailability = availability
            }
        }
    }

    private func attachmentFilename(for item: PhotosPickerItem) -> String {
        if let identifier = item.itemIdentifier,
           !identifier.isEmpty {
            return identifier
        }

        if let preferredExtension = item.supportedContentTypes.first?.preferredFilenameExtension {
            return "photo.\(preferredExtension)"
        }

        return "photo"
    }

    private var isCompactPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var showsToolbarRow: Bool {
        if !isCompactPhone {
            return true
        }

        return model.threadFeatureState.queuedPromptCount > 0
    }

    private var bottomPadding: CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad, keyboardBottomInset > 0 {
            return keyboardBottomInset + 12
        }

        return isCompactPhone ? 0 : 4
    }

    private var keyboardFramePublisher: AnyPublisher<CGFloat, Never> {
#if canImport(UIKit)
        let changeFrame = NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        let hide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)

        return Publishers.Merge(changeFrame, hide)
            .map { notification in
                guard UIDevice.current.userInterfaceIdiom == .pad else {
                    return 0
                }

                guard let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                    return 0
                }

                let overlap = UIScreen.main.bounds.maxY - frameValue.minY
                return max(0, overlap)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
#else
        return Just(0).eraseToAnyPublisher()
#endif
    }
}

private struct ToolbarPillLabel: View {
    let title: String
    let systemImage: String
    let showsTitle: Bool
    var prominence: Prominence = .standard
    var isDisabled = false
    var compact = false

    var body: some View {
        HStack(spacing: showsTitle ? (compact ? 4 : 8) : 0) {
            Image(systemName: systemImage)
                .font(showsTitle ? (compact ? .callout.weight(.semibold) : .body.weight(.semibold)) : compact ? .footnote.weight(.semibold) : .callout.weight(.semibold))

            if showsTitle {
                Text(title)
                    .lineLimit(1)
            }
        }
        .font(showsTitle ? (compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold)) : compact ? .caption2.weight(.semibold) : .callout.weight(.semibold))
        .padding(.horizontal, showsTitle ? (compact ? 6 : 10) : (compact ? 4 : 8))
        .padding(.vertical, showsTitle ? (compact ? 3 : 7) : (compact ? 2 : 6))
        .fixedSize()
        .foregroundStyle(foregroundStyle)
        .background(backgroundStyle, in: Capsule())
        .accessibilityLabel(title)
    }

    private var backgroundStyle: Color {
        if isDisabled {
            return AppVisualStyle.panelBackgroundMuted
        }

        switch prominence {
        case .prominent:
            return Color.accentColor
        case .standard:
            return AppVisualStyle.panelBackgroundMuted
        }
    }

    private var foregroundStyle: Color {
        if isDisabled {
            return AppVisualStyle.secondaryText
        }

        switch prominence {
        case .prominent:
            return .white
        case .standard:
            return .primary
        }
    }

    enum Prominence {
        case standard
        case prominent
    }
}

#if canImport(UIKit)
private struct PromptTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .subheadline)
        textView.adjustsFontForContentSizeCategory = true
        textView.returnKeyType = .send
        textView.enablesReturnKeyAutomatically = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.textContainer.maximumNumberOfLines = 2
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityIdentifier = "session-prompt-field"
        textView.accessibilityLabel = "Message Codex"
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if textView.text != text {
            textView.text = text
        }
        textView.accessibilityValue = text

        textView.font = UIFont.preferredFont(forTextStyle: .subheadline)

        if isFocused, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        } else if !isFocused, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PromptTextView

        init(parent: PromptTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.accessibilityValue = textView.text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard replacement == "\n" else {
                return true
            }

            parent.onSubmit()
            return false
        }
    }
}
#endif
