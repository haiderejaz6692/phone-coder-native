import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

struct PhoneCoderPairingSheet: View {
    let services: PhoneCoderServerServices
    let address: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var approval: PhoneCoderPairingApproval
    @State private var payload: PhoneCoderPairingPayload?
    @State private var qr: UIImage?
    @State private var encoded = ""
    @State private var error: String?
    @State private var expiresAt: Date?
    @State private var isIssuing = false
    init(services: PhoneCoderServerServices, address: String?) {
        self.services = services; self.address = address; self.approval = services.pairingApproval
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Connect your laptop") {
                    Text("Scan this code with your client, or copy the pairing payload. Then approve the named device on this phone.")
                    if let qr {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 300).padding().background(.white)
                            .accessibilityLabel("One-time pairing QR code. Copy pairing payload is also available below.")
                    }
                    if let expiresAt { Text("Expires \(expiresAt, style: .relative). A code can be used only once.").font(.footnote) }
                    if !encoded.isEmpty {
                        Button("Copy pairing payload", systemImage: "doc.on.doc") {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: encoded]], options: [.localOnly: true, .expirationDate: expiresAt ?? .now])
                        }.phoneCoderTarget()
                    }
                    PhoneCoderInlineError(message: error)
                    Button(payload == nil ? "Create pairing code" : "Replace pairing code") { Task { await issue() } }.disabled(isIssuing).phoneCoderTarget()
                    if isIssuing { ProgressView("Creating one-time code") }
                }
            }.navigationTitle("Pair device")
                .toolbar { Button("Done") { dismiss() } }
                .task { await issue() }
                .onDisappear {
                    let token = payload?.token
                    Task { if let token { await services.pairingExchange.invalidate(token: token) } }
                }
                .alert("Pair device?", isPresented: Binding(get: { approval.pending != nil }, set: { _ in }), presenting: approval.pending) { pending in
                    Button("Approve") { approval.resolve(id: pending.id, approved: true); dismiss() }
                    Button("Deny", role: .cancel) { approval.resolve(id: pending.id, approved: false) }
                } message: { pending in Text("Allow \(pending.name) to use this phone’s model?") }
        }
    }
    private func issue() async {
        guard !isIssuing else { return }
        isIssuing = true
        defer { isIssuing = false }
        if let payload { await services.pairingExchange.invalidate(token: payload.token) }
        payload = nil; qr = nil; encoded = ""
        guard let address, services.controller.servingRequested else {
            error = "Start the server with Tailscale connected, then reopen pairing."; return
        }
        do {
            let value = try await services.pairingExchange.issue(server: address, apiVersion: PhoneCoderBuildManifest.current.apiProfile, tailnetIdentity: address)
            let data = try JSONEncoder().encode(value)
            let filter = CIFilter.qrCodeGenerator(); filter.message = data
            guard let output = filter.outputImage,
                  let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else {
                await services.pairingExchange.invalidate(token: value.token)
                throw PhoneCoderPairingError.randomFailure
            }
            payload = value; encoded = String(decoding: data, as: UTF8.self)
            qr = UIImage(cgImage: image); expiresAt = .now.addingTimeInterval(300); error = nil
        } catch { self.error = phoneCoderError(error) }
    }
}
