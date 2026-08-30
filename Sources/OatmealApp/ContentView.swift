import OatmealCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selectedMeetingID }, set: model.selectMeeting)) {
                ForEach(model.meetings) { meeting in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.title).fontWeight(.medium)
                        Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(meeting.id)
                }
            }
            .accessibilityIdentifier("meeting-history")
            .navigationTitle("Oatmeal")
            .safeAreaInset(edge: .bottom) {
                Button(action: model.startMeeting) {
                    Label("New Meeting", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .accessibilityIdentifier("start-meeting")
            }
        } detail: {
            detail
                .frame(minWidth: 620, minHeight: 560)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Change Transcription Model") { model.modelSetupKind = .transcription }
                    Button("Change Notes Model") { model.modelSetupKind = .generation }
                    Divider()
                    Button("Open Models Folder", action: model.openModelsFolder)
                } label: {
                    Label("Models", systemImage: "gearshape")
                }
                .disabled(model.workflowStatus == .capturing || model.workflowStatus == .degraded)
            }
        }
        .alert("Oatmeal", isPresented: Binding(
            get: { model.visibleError != nil },
            set: { if !$0 { model.visibleError = nil } }
        )) {
            Button("Open Privacy Settings", action: model.openPrivacySettings)
            Button("OK", role: .cancel) { model.visibleError = nil }
        } message: {
            Text(model.visibleError ?? "")
        }
        .sheet(item: $model.modelSetupKind) { kind in
            ModelSetupView(model: model, kind: kind)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !model.hasTranscriptionModel {
            ModelSetupView(model: model, kind: .transcription)
                .accessibilityIdentifier("model-setup")
        } else if model.workflowStatus == .capturing || model.workflowStatus == .degraded {
            ActiveMeetingView(model: model)
        } else if let meeting = model.selectedMeeting {
            MeetingDetailView(model: model, meeting: meeting)
                .id(meeting.id)
        } else {
            ContentUnavailableView("Ready for a meeting", systemImage: "waveform", description: Text("Start capture when your call begins. Everything stays on this Mac."))
        }
    }
}

private struct ActiveMeetingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.workflowStatus == .degraded ? "Capture degraded" : "Capturing", systemImage: "record.circle.fill")
                    .foregroundStyle(model.workflowStatus == .degraded ? .orange : .red)
                Spacer()
                Button("Stop", role: .destructive, action: model.stopMeeting)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityIdentifier("stop-meeting")
            }
            .padding()

            Divider()
            TranscriptView(meeting: model.selectedMeeting, partials: model.partialTranscript)
            Divider()

            if let notes = model.selectedMeeting?.userNotes, !notes.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(notes) { note in EditableNoteRow(note: note, onSave: { model.updateUserNote(note, text: $0) }) }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 48)
            }

            HStack(alignment: .bottom) {
                TextEditor(text: $model.noteDraft)
                    .frame(minHeight: 64, maxHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .accessibilityIdentifier("user-note")
                Button("Save Note", action: model.saveDraftNote)
                    .disabled(model.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(model.selectedMeeting?.title ?? "New Meeting")
    }
}

private struct EditableNoteRow: View {
    let note: UserNote
    let onSave: (String) -> Void
    @State private var text: String

    init(note: UserNote, onSave: @escaping (String) -> Void) {
        self.note = note
        self.onSave = onSave
        _text = State(initialValue: note.text)
    }

    var body: some View {
        TextField("Meeting note", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
            .onSubmit { onSave(text) }
    }
}

private struct TranscriptView: View {
    let meeting: Meeting?
    let partials: [AudioSource: String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(meeting?.transcript ?? []) { segment in
                    HStack(alignment: .top) {
                        Text(segment.source.label)
                            .font(.caption.bold())
                            .frame(width: 54, alignment: .leading)
                        Text(segment.text).textSelection(.enabled)
                    }
                }
                ForEach(AudioSource.allCases, id: \.self) { source in
                    if let text = partials[source] {
                        HStack(alignment: .top) {
                            Text(TranscriptSource(source).label).font(.caption.bold())
                            Text(text).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .accessibilityIdentifier("meeting-transcript")
    }
}

private struct MeetingDetailView: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    @State private var title: String
    @State private var confirmsDelete = false

    init(model: AppModel, meeting: Meeting) {
        self.model = model
        self.meeting = meeting
        _title = State(initialValue: meeting.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Meeting title", text: $title, onCommit: { model.renameSelected(to: title) })
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                Spacer()
                Button("Generate Notes", action: model.generateNotes)
                    .buttonStyle(.borderedProminent)
                Button(role: .destructive) { confirmsDelete = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete Meeting")
            }
            .padding()

            TabView {
                TranscriptView(meeting: meeting, partials: [:]).tabItem { Text("Transcript") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(meeting.userNotes) { note in
                            Text(note.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding()
                }.tabItem { Text("My Notes") }
                ScrollView {
                    if let note = meeting.latestGeneratedNote {
                        Text((try? AttributedString(markdown: note.content)) ?? AttributedString(note.content))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        ContentUnavailableView("No generated notes", systemImage: "doc.text", description: Text("Generate structured notes from the local transcript."))
                    }
                }.tabItem { Text("Generated") }
            }
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmsDelete) {
            Button("Delete Meeting", role: .destructive, action: model.deleteSelected)
        } message: {
            Text("Its transcript and notes will be removed from Oatmeal storage.")
        }
    }
}

private struct ModelSetupView: View {
    @ObservedObject var model: AppModel
    let kind: ModelKind
    @Environment(\.dismiss) private var dismiss

    private var descriptors: [ModelDescriptor] {
        kind == .transcription ? ModelCatalog.transcription : ModelCatalog.generation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading) {
                    Text(kind == .transcription ? "Choose a transcription model" : "Choose a notes model").font(.largeTitle.bold())
                    Text("Downloaded directly from the disclosed source. Meeting content is never included in model requests.").foregroundStyle(.secondary)
                }
                Spacer()
                if model.modelSetupKind != nil { Button("Close") { dismiss() } }
            }

            ForEach(descriptors) { descriptor in
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(descriptor.name).font(.headline)
                            Text(descriptor.guidance).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Text(ByteCountFormatter.string(fromByteCount: descriptor.bytes, countStyle: .file))
                                Text("·")
                                Link(descriptor.sourceName, destination: descriptor.sourceURL)
                            }
                            .font(.caption)
                        }
                        Spacer()
                        if model.downloadingModelID == descriptor.id {
                            VStack {
                                ProgressView(value: model.downloadProgress).frame(width: 140)
                                Button("Cancel", action: model.cancelDownload)
                            }
                        } else {
                            Button("Download", action: { model.download(descriptor) }).buttonStyle(.borderedProminent)
                        }
                    }.padding(6)
                }
            }

            HStack {
                Button("Open Models Folder", action: model.openModelsFolder)
                Spacer()
                Text("Models remain on this Mac.").foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(minWidth: 620, minHeight: 480)
    }
}
