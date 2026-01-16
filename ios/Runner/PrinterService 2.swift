import Foundation
import UIKit
import PDFKit

final class PrinterService {
    static let shared = PrinterService()
    private init() {}

    // If you plan to target a specific printer, pass its UIPrinter URL string via `macAddress`
    // or change the parameter to `printerURLString`.
    func printPdf(fileUrl: URL, macAddress: String?) {
        DispatchQueue.main.async {
            let controller = UIPrintInteractionController.shared
            let printInfo = UIPrintInfo.printInfo()
            printInfo.jobName = fileUrl.lastPathComponent
            printInfo.outputType = .general
            controller.printInfo = printInfo

            // Load PDF data
            if fileUrl.isFileURL {
                if let data = try? Data(contentsOf: fileUrl) {
                    controller.printingItem = data
                } else {
                    print("PrinterService: Failed to read local PDF at \(fileUrl)")
                    return
                }
            } else {
                // Remote URL: simple fetch (blocking avoided by async)
                let task = URLSession.shared.dataTask(with: fileUrl) { data, _, error in
                    DispatchQueue.main.async {
                        if let data = data {
                            controller.printingItem = data
                            self.presentPrintController(controller, macAddress: macAddress)
                        } else {
                            print("PrinterService: Failed to download PDF: \(error?.localizedDescription ?? "unknown error")")
                        }
                    }
                }
                task.resume()
                return
            }

            self.presentPrintController(controller, macAddress: macAddress)
        }
    }

    private func presentPrintController(_ controller: UIPrintInteractionController, macAddress: String?) {
        // If you have a printer URL (ipp:// or UIPrinter URL string), you can use:
        // let printer = UIPrinter(url: URL(string: printerURLString)!)
        // controller.print(to: printer) { _, completed, error in ... }

        if let mac = macAddress, !mac.isEmpty {
            // Placeholder: no direct AirPrint selection by MAC on iOS.
            // Implement your own mapping from MAC -> printer URL if available.
            print("PrinterService: macAddress provided (\(mac)) but AirPrint requires a printer URL. Presenting sheet.")
        }

        controller.present(animated: true) { (_, completed, error) in
            if let error = error {
                print("PrinterService: Print error: \(error.localizedDescription)")
            } else {
                print("PrinterService: Print completed: \(completed)")
            }
        }
    }
}
