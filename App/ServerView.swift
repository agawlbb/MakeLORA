import SwiftUI
import AVFoundation
import VisionKit
import MakeLORACore

struct ServerView: View {
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = UIDevice.current.name
    @State private var scanning = false
    @State private var invitation: PairingInvitation?
    @State private var parseError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Text(pairing.status)
                    if let server=pairing.credential?.server { Text(server.absoluteString).font(.footnote) }
                    if let code=pairing.confirmation {
                        Text(code).font(.largeTitle.monospacedDigit())
                        Text("Approve this matching code on the server website, then check status.")
                    }
                    if pairing.hasConnection {
                        Button("Check status") { Task { await pairing.check() } }
                        Button("Disconnect",role:.destructive) { Task { await pairing.disconnect() } }
                    }
                }
                if !pairing.hasConnection {
                    Section("Pair a server") {
                        TextField("Device name",text:$name)
                        Button("Scan QR",systemImage:"qrcode.viewfinder") {
                            Task {
                                guard DataScannerViewController.isSupported else { parseError="QR scanning is unavailable. Paste the invitation instead."; return }
                                let allowed=await AVCaptureDevice.requestAccess(for:.video)
                                if allowed && DataScannerViewController.isAvailable { scanning=true }
                                else { parseError="Camera access is unavailable. Allow camera access in Settings or paste the invitation." }
                            }
                        }
                        TextEditor(text:$text).frame(minHeight:100).accessibilityLabel("Pairing invitation")
                        Button("Review invitation") { review(text) }.disabled(text.isEmpty)
                    }
                }
                if let error=pairing.error ?? parseError { Section { Text(error).foregroundStyle(.red) } }
                Section { Text("Pairing currently grants no file storage or model-run access.") }
            }
            .navigationTitle("Server")
            .toolbar { Button("Done") { dismiss() } }
            .disabled(pairing.busy)
            .sheet(isPresented:$scanning) {
                NavigationStack { PairingScanner { value in scanning=false; review(value) }.ignoresSafeArea(edges:.bottom).toolbar { Button("Cancel") { scanning=false } } }
            }
            .alert("Connect to this server?",isPresented:Binding(get:{invitation != nil},set:{if !$0 { invitation=nil }}),presenting:invitation) { value in
                Button("Connect") { Task { await pairing.pair(value,name:name.trimmingCharacters(in:.whitespacesAndNewlines)) } }
                Button("Cancel",role:.cancel) { }
            } message: { value in Text(value.server.absoluteString) }
        }
    }
    private func review(_ value:String) {
        do {
            guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.unicodeScalars.count<=100 else { parseError="Enter a device name of 1–100 characters."; return }
            invitation=try PairingInvitation.parse(value); parseError=nil
        } catch { parseError=error.localizedDescription }
    }
}

private struct PairingScanner: UIViewControllerRepresentable {
    let found: (String)->Void
    func makeCoordinator()->Coordinator { Coordinator(found:found) }
    func makeUIViewController(context:Context)->DataScannerViewController {
        let controller=DataScannerViewController(recognizedDataTypes:[.barcode(symbologies:[.qr])],qualityLevel:.balanced,recognizesMultipleItems:false,isHighlightingEnabled:true)
        controller.delegate=context.coordinator
        do { try controller.startScanning() } catch { DispatchQueue.main.async { context.coordinator.found("") } }
        return controller
    }
    func updateUIViewController(_ controller:DataScannerViewController,context:Context) {}
    static func dismantleUIViewController(_ controller:DataScannerViewController,coordinator:Coordinator) { controller.stopScanning() }
    final class Coordinator:NSObject,DataScannerViewControllerDelegate {
        let found:(String)->Void
        var delivered=false
        init(found:@escaping(String)->Void) { self.found=found }
        func dataScanner(_ dataScanner:DataScannerViewController,didAdd addedItems:[RecognizedItem],allItems:[RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems { if case .barcode(let barcode)=item, let value=barcode.payloadStringValue { delivered=true; dataScanner.stopScanning(); found(value); return } }
        }
    }
}
