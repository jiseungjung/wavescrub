import SwiftUI

/// One button per surfer, with their initial in their color: tap whoever is
/// riding to mark the wave as theirs.
struct SurferButtons: View {
    @EnvironmentObject private var model: PlayerModel

    var body: some View {
        let buttons = HStack(spacing: 10) {
            ForEach(model.surfers) { surfer in
                Button {
                    model.markWave(for: surfer.id)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Text(initials(surfer))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(surfer.color.color, in: Circle())
                }
            }
        }
        // More than four don't fit beside the other controls; slide through them.
        if model.surfers.count > 4 {
            ScrollView(.horizontal, showsIndicators: false) { buttons }
                .frame(maxWidth: 4 * 30 + 3 * 10)
        } else {
            buttons
        }
    }

    /// The first letter, or the first two when someone else shares it.
    private func initials(_ surfer: Surfer) -> String {
        let name = surfer.name.trimmingCharacters(in: .whitespaces)
        guard let first = name.first else { return "?" }
        let shared = model.surfers.contains {
            $0.id != surfer.id && $0.name.trimmingCharacters(in: .whitespaces).first?.lowercased() == first.lowercased()
        }
        return shared ? String(name.prefix(2)) : String(first).uppercased()
    }
}

/// Who's surfing in this video. You're always first; name yourself to have
/// your waves called by your name, and to add anyone else.
struct PeopleSheet: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Surfer.ID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(model.surfers.enumerated()), id: \.element.id) { index, surfer in
                        row(surfer, isMe: index == 0)
                    }
                    .onDelete { offsets in
                        for i in offsets where i > 0 { model.removeSurfer(model.surfers[i].id) }
                    }
                    .deleteDisabled(model.surfers.count < 2)
                    Button {
                        model.addSurfer()
                        focused = model.surfers.last?.id
                    } label: {
                        Label("Add person", systemImage: "person.badge.plus")
                    }
                    .disabled(!model.canAddSurfer)
                } footer: {
                    if !model.canAddSurfer {
                        Text("Give yourself a name first, then add someone else.")
                    } else if model.surfers.count > 1 {
                        Text("Removing someone gives their waves to you.")
                    }
                }

                if model.canAddSurfer, !suggestions.isEmpty {
                    Section("Surfed with before") {
                        ForEach(suggestions, id: \.name) { known in
                            Button { model.addSurfer(name: known.name, color: known.color) } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(known.color.color).frame(width: 14, height: 14)
                                    Text(known.name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Who's surfing?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onDisappear { model.rememberSurfers() }
            .onAppear {
                // Adding a person from a wave's dot with no name yet: start there.
                if !model.canAddSurfer { focused = model.surfers.first?.id }
            }
        }
    }

    private func row(_ surfer: Surfer, isMe: Bool) -> some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(WaveColor.allCases) { color in
                    Button(color.name) { model.setSurferColor(surfer.id, to: color) }
                }
            } label: {
                Circle().fill(surfer.color.color).frame(width: 22, height: 22)
            }
            TextField(isMe ? "Your name" : "Name", text: Binding(
                get: { surfer.name },
                set: { model.renameSurfer(surfer.id, to: $0) }
            ))
            .focused($focused, equals: surfer.id)
            .submitLabel(.done)
            if isMe { Text("You").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    /// People from other videos who aren't in this one yet.
    private var suggestions: [KnownSurfer] {
        let here = Set(model.surfers.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() })
        return model.knownSurfers.filter { !here.contains($0.name.lowercased()) }.prefix(8).map { $0 }
    }
}
