import UIKit
import Social
import MobileCoreServices
import CoreBluetooth
import CoreGraphics

class ShareViewController: SLComposeServiceViewController {

    // MARK: - Configuration
    // TODO: CHANGE THIS TO YOUR EXACT APP GROUP ID
    private let appGroupID = "group.com.lhdn.eposprinter" 
    
    private let printerHelper = BluetoothPrinterHelper()
    private var printerWidth: Int = 384 // Default 58mm
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 1. Fix UIKeyboard Error: Disable editing so keyboard doesn't pop up
        self.textView.isEditable = false
        self.placeholder = "Preparing to print..."
        
        // 2. Hide the Post button (We are auto-printing)
        self.navigationController?.navigationBar.topItem?.rightBarButtonItem = nil
        
        // 3. Load Settings from App Group
        loadSettings()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 4. Start immediately without user interaction
        handleIncomingContent()
    }

    // MARK: - Logic
    private func loadSettings() {
        if let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            let savedWidth = sharedDefaults.integer(forKey: "printer_width_dots")
            if savedWidth > 0 {
                self.printerWidth = savedWidth
            }
            
            // Get UUID saved by the main app
            if let savedUUIDStr = sharedDefaults.string(forKey: "selected_printer_uuid") {
                printerHelper.targetUUID = UUID(uuidString: savedUUIDStr)
            }
        }
    }

    private func handleIncomingContent() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            return
        }

        // We only process the first valid attachment to save memory
        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(kUTTypePDF as String) {
                provider.loadItem(forTypeIdentifier: kUTTypePDF as String, options: nil) { [weak self] (data, error) in
                    if let url = data as? URL {
                        self?.processPdfAndPrint(url: url)
                    }
                }
                return // Stop after finding one
            } 
            else if provider.hasItemConformingToTypeIdentifier(kUTTypeImage as String) {
                provider.loadItem(forTypeIdentifier: kUTTypeImage as String, options: nil) { [weak self] (data, error) in
                    if let url = data as? URL, let image = UIImage(contentsOfFile: url.path) {
                        self?.processImageAndPrint(image: image)
                    } else if let image = data as? UIImage {
                        self?.processImageAndPrint(image: image)
                    }
                }
                return
            }
        }
        
        // If nothing found
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - Processing & Printing
    
    // OPTIMIZED: Connects first, then renders/prints page-by-page to save memory
    private func processPdfAndPrint(url: URL) {
        DispatchQueue.main.async { self.textView.text = "Connecting to Printer..." }
        
        // 1. Connect first
        printerHelper.connect { [weak self] success, message in
            guard let self = self else { return }
            
            if !success {
                DispatchQueue.main.async { self.textView.text = "Connection Failed: \(message)" }
                return
            }
            
            // 2. Render and Print Page by Page
            DispatchQueue.global(qos: .userInitiated).async {
                guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return }
                
                // Send Init Command
                self.printerHelper.sendRawData(self.printerHelper.INIT_PRINTER)
                
                let pageCount = min(document.numberOfPages, 10) // Limit pages safety
                
                for i in 1...pageCount {
                    // AUTORELEASEPOOL IS CRITICAL FOR MEMORY IN EXTENSIONS
                    autoreleasepool {
                        DispatchQueue.main.async { self.textView.text = "Printing Page \(i)/\(pageCount)..." }
                        
                        guard let page = document.page(at: i) else { return }
                        
                        let pageRect = page.getBoxRect(.mediaBox)
                        let scale = CGFloat(self.printerWidth) / pageRect.width
                        let targetHeight = Int(pageRect.height * scale)
                        
                        let colorSpace = CGColorSpaceCreateDeviceRGB()
                        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                        
                        guard let context = CGContext(data: nil,
                                                      width: self.printerWidth,
                                                      height: targetHeight,
                                                      bitsPerComponent: 8,
                                                      bytesPerRow: 0,
                                                      space: colorSpace,
                                                      bitmapInfo: bitmapInfo) else { return }
                        
                        context.setFillColor(UIColor.white.cgColor)
                        context.fill(CGRect(x: 0, y: 0, width: self.printerWidth, height: targetHeight))
                        
                        context.saveGState()
                        context.scaleBy(x: scale, y: scale)
                        context.translateBy(x: 0, y: pageRect.height)
                        context.scaleBy(x: 1.0, y: -1.0)
                        context.drawPDFPage(page)
                        context.restoreGState()
                        
                        if let cgImage = context.makeImage() {
                            let uiImage = UIImage(cgImage: cgImage)
                            if let trimmed = uiImage.trim()?.resize(to: self.printerWidth) {
                                let escData = trimmed.convertToEscPos(width: self.printerWidth)
                                // Send immediately (Streaming)
                                self.printerHelper.sendRawData(escData)
                            }
                        }
                        
                        // Small delay between pages to let printer catch up
                        usleep(500000) // 0.5 sec
                    }
                }
                
                // Cut Paper
                self.printerHelper.sendRawData(self.printerHelper.FEED_PAPER)
                self.printerHelper.sendRawData(self.printerHelper.CUT_PAPER)
                
                // Disconnect and Finish
                self.printerHelper.disconnect()
                
                DispatchQueue.main.async {
                    self.textView.text = "Done!"
                    // Close extension
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                    }
                }
            }
        }
    }
    
    private func processImageAndPrint(image: UIImage) {
        DispatchQueue.main.async { self.textView.text = "Connecting..." }
        
        printerHelper.connect { [weak self] success, message in
            guard let self = self else { return }
            if !success {
                DispatchQueue.main.async { self.textView.text = "Error: \(message)" }
                return
            }
            
            DispatchQueue.global(qos: .userInitiated).async {
                self.printerHelper.sendRawData(self.printerHelper.INIT_PRINTER)
                
                if let resized = image.resize(to: self.printerWidth).trim() {
                     let final = resized.resize(to: self.printerWidth)
                     let escData = final.convertToEscPos(width: self.printerWidth)
                     self.printerHelper.sendRawData(escData)
                }
                
                self.printerHelper.sendRawData(self.printerHelper.FEED_PAPER)
                self.printerHelper.sendRawData(self.printerHelper.CUT_PAPER)
                self.printerHelper.disconnect()
                
                DispatchQueue.main.async {
                    self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
            }
        }
    }

    // Standard Overrides
    override func isContentValid() -> Bool { return false } // Disable Post button
    override func didSelectPost() { }
    override func configurationItems() -> [Any]! { return [] }
}

// MARK: - Optimized Bluetooth Helper
class BluetoothPrinterHelper: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    var centralManager: CBCentralManager!
    var targetPeripheral: CBPeripheral?
    var writeCharacteristic: CBCharacteristic?
    var connectionCompletion: ((Bool, String) -> Void)?
    var targetUUID: UUID?
    
    let INIT_PRINTER: [UInt8] = [0x1B, 0x40]
    let FEED_PAPER: [UInt8] = [0x1B, 0x64, 0x04]
    let CUT_PAPER: [UInt8] = [0x1D, 0x56, 0x42, 0x00]
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func connect(completion: @escaping (Bool, String) -> Void) {
        self.connectionCompletion = completion
        if centralManager.state == .poweredOn {
            startScan()
        }
        // If not powered on, delegate will trigger scan
    }
    
    func disconnect() {
        if let p = targetPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
    }
    
    func startScan() {
        // Try to connect to specific UUID if we have it from App Group
        if let uuid = targetUUID {
            let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let device = known.first {
                connectTo(device)
                return
            }
        }
        
        // Fallback: Scan broadly
        centralManager.scanForPeripherals(withServices: nil, options: nil)
        
        // Timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            if self.targetPeripheral == nil {
                self.centralManager.stopScan()
                self.connectionCompletion?(false, "Printer not found")
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScan()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Match UUID if available
        if let target = targetUUID, peripheral.identifier == target {
            connectTo(peripheral)
        } 
        // Heuristic fallback if UUID is missing
        else if targetUUID == nil {
             let name = peripheral.name ?? "Unknown"
             if name.contains("Printer") || name.contains("MTP") {
                 connectTo(peripheral)
             }
        }
    }
    
    func connectTo(_ peripheral: CBPeripheral) {
        centralManager.stopScan()
        targetPeripheral = peripheral
        targetPeripheral?.delegate = self
        centralManager.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics {
            if char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = char
                // Signal Ready
                connectionCompletion?(true, "Connected")
                connectionCompletion = nil // Clear so we don't call twice
                return
            }
        }
    }
    
    func sendRawData(_ data: [UInt8]) {
        guard let p = targetPeripheral, let c = writeCharacteristic else { return }
        
        let chunkSize = 150 // Safe chunk size
        for i in stride(from: 0, to: data.count, by: chunkSize) {
            let end = min(i + chunkSize, data.count)
            let chunk = Data(data[i..<end])
            let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            p.writeValue(chunk, for: c, type: type)
            usleep(10000) 
        }
    }
}
// Note: Keep your existing UIImage extension (resize, trim, convertToEscPos) here at the bottom of the file