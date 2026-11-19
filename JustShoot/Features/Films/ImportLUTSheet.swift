import SwiftUI

// MARK: - 导入确认 Sheet
struct ImportLUTSheet: View {
    @Binding var name: String
    @Binding var iso: String
    @Binding var encoding: LUTColorEncoding
    let isImporting: Bool
    @State private var showCompatibility = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Filter name") {
                    TextField("Name", text: $name)
                }
                Section("ISO") {
                    TextField("200", text: $iso)
                        .keyboardType(.numberPad)
                }
                Section {
                    Picker("LUT color space", selection: $encoding) {
                        Text(verbatim: "sRGB").tag(LUTColorEncoding.sRGB)
                        Text(verbatim: "Rec.709 Gamma 2.4").tag(LUTColorEncoding.rec709Gamma24)
                    }
                    Button("LUT compatibility", systemImage: "info.circle") { showCompatibility = true }
                }
            }
            .disabled(isImporting)
            .scrollContentBackground(.hidden)
            .appPageBackground()
            .navigationTitle("Import LUT")
            .navigationBarTitleDisplayMode(.inline)
            .softScrollEdges()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onConfirm)
                        .bold()
                        .disabled(isImporting)
                }
            }
            .overlay { if isImporting { ProgressView() } }
            .alert("LUT compatibility", isPresented: $showCompatibility) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Import a 3D .cube with a 0–1 input range. Input and output must both use the selected SDR color space. Camera Log, HDR and 1D shaper LUTs must first be converted to an sRGB-to-sRGB look in a color-managed editor. A .cube file cannot reliably identify its color space. Existing imports keep their sRGB interpretation.")
            }
        }
    }
}
