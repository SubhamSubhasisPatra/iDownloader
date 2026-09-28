import SwiftUI

struct AddSheet: View {
    @Environment(\.dismiss) private var dismiss
    let service: TaskService

    @State private var urlText = ""
    @State private var errorMessage = ""
    @FocusState private var isURLFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $urlText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($isURLFocused)
                        .onSubmit(addTask)
                } footer: {
                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else {
                        Text("Supports HTTP(S), magnet and .torrent links.")
                    }
                }
            }
            .navigationTitle("Add Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: addTask)
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { isURLFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func addTask() {
        Task {
            if let error = await service.add(urlText) {
                errorMessage = error
            } else {
                dismiss()
            }
        }
    }
}
