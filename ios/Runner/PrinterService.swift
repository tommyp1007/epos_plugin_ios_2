import Foundation
import UIKit
import CoreBluetooth
import CoreGraphics
import UserNotifications

// MARK: - Printer Service
class PrinterService: NSObject {
    
    static let shared = PrinterService()
    
    // FIX: This must match the ID in AppDelegate exactly (usually starts with "group.")
    private let APP_GROUP_ID = "group.com.lhdn.eposprinter"
    
    // Configuration
    private let WIDTH_58MM: Int = 384
    private let WIDTH_80MM: Int = 576
    
    // ESC/POS Commands
    private let INIT_PRINTER: [UInt8] = [0x1B, 0x40]
    private let FEED_PAPER: [UInt8] = [0x1B, 0x64, 0x04]
    private let CUT_PAPER: [UInt8] = [0x1D, 0x56, 0x42, 0x00]
    
    // Bluetooth Variables
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var targetMacAddress: String = "" 
    
    // State
    private var isPrinting = false
    private var printQueue: [URL] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    // Callbacks
    var onStatusChanged: ((String) -> Void)?
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        setupNotifications()
    }
    
    // MARK: - App Group Sync
    func syncToAppGroup(printerUUID: String, width: Int) {
        if let sharedDefaults = UserDefaults(suiteName: APP_GROUP_ID) {
            sharedDefaults.set(printerUUID, forKey: "selected_printer_uuid")
            sharedDefaults.set(width, forKey: "printer_width_dots")
            sharedDefaults.synchronize()
            print("PrinterService: Synced \(printerUUID) to App Group")
        } else {
            print("PrinterService: Error - Could not load App Group. Check ID: \(APP_GROUP_ID)")
        }
    }
    
    // MARK: - Helpers
    private func getCurrentLanguage() -> String {
        return UserDefaults.standard.string(forKey: "flutter.language_code") ?? "en"
    }
    
    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    private func showNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = getCurrentLanguage() == "ms" ? "Status Pencetak" : "Printer Status"
        content.body = message
        let request = UNNotificationRequest(identifier: "printer_status", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    // MARK: - Public API
    func printPdf(fileUrl: URL, macAddress: String? = nil) {
        guard !isPrinting else {
            printQueue.append(fileUrl)
            return
        }
        
        self.backgroundTask = UIApplication.shared.beginBackgroundTask {
            self.endBackgroundTask()
        }
        
        self.isPrinting = true
        
        if let mac = macAddress {
            self.targetMacAddress = mac
        } else {
            self.targetMacAddress = UserDefaults.standard.string(forKey: "flutter.selected_printer_mac") ?? ""
        }
        
        if connectedPeripheral?.state == .connected {
            self.processPdf(url: fileUrl)
        } else {
            startScan()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    // MARK: - Processing Logic
    private func processPdf(url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let savedWidth = UserDefaults.standard.integer(forKey: "flutter.printer_width_dots")
            var targetWidth = savedWidth > 0 ? savedWidth : self.WIDTH_58MM
            
            if let name = self.connectedPeripheral?.name?.uppercased() {
                if name.contains("80") || name.contains("T80") {
                    targetWidth = self.WIDTH_80MM
                }
            }
            
            guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
                self.finishPrintJob(success: false, error: "Invalid PDF")
                return
            }
            
            let pageCount = min(document.numberOfPages, 20)
            var dataToSend: [UInt8] = []
            dataToSend.append(contentsOf: self.INIT_PRINTER)
            
            for i in 1...pageCount {
                guard let page = document.page(at: i) else { continue }
                
                let pageRect = page.getBoxRect(.mediaBox)
                let scale = CGFloat(targetWidth) / pageRect.width
                let targetHeight = Int(pageRect.height * scale)
                
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                
                guard let context = CGContext(data: nil,
                                              width: targetWidth,
                                              height: targetHeight,
                                              bitsPerComponent: 8,
                                              bytesPerRow: 0,
                                              space: colorSpace,
                                              bitmapInfo: bitmapInfo) else { continue }
                
                context.interpolationQuality = .high
                context.setFillColor(UIColor.white.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
                
                context.saveGState()
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: 0, y: pageRect.height)
                context.scaleBy(x: 1.0, y: -1.0)
                context.drawPDFPage(page)
                context.restoreGState()
                
                guard let cgImage = context.makeImage() else { continue }
                let uiImage = UIImage(cgImage: cgImage)
                
                guard let trimmedImage = uiImage.trim() else { continue }
                let finalImage = trimmedImage.resize(to: targetWidth)
                let escPosData = self.convertImageToEscPos(image: finalImage)
                dataToSend.append(contentsOf: escPosData)
                
                usleep(10000)
            }
            
            dataToSend.append(contentsOf: self.FEED_PAPER)
            dataToSend.append(contentsOf: self.CUT_PAPER)
            self.sendToPrinter(data: dataToSend)
        }
    }
    
    private func sendToPrinter(data: [UInt8]) {
        guard let peripheral = connectedPeripheral, let char = writeCharacteristic else {
            finishPrintJob(success: false, error: "Printer disconnected")
            return
        }
        
        let chunkSize = 180
        for i in stride(from: 0, to: data.count, by: chunkSize) {
            let end = min(i + chunkSize, data.count)
            let chunk = Data(data[i..<end])
            peripheral.writeValue(chunk, for: char, type: .withoutResponse)
            usleep(20000)
        }
        
        finishPrintJob(success: true)
    }
    
    private func finishPrintJob(success: Bool, error: String? = nil) {
        DispatchQueue.main.async {
            self.isPrinting = false
            self.endBackgroundTask()
            
            if !success {
                let msg = self.getCurrentLanguage() == "ms" ? "Ralat: \(error ?? "")" : "Error: \(error ?? "")"
                self.showNotification(message: msg)
            } else {
                if !self.printQueue.isEmpty {
                    let nextUrl = self.printQueue.removeFirst()
                    self.printPdf(fileUrl: nextUrl)
                }
            }
        }
    }
    
    private func convertImageToEscPos(image: UIImage) -> [UInt8] {
        guard let inputCGImage = image.cgImage else { return [] }
        let width = inputCGImage.width
        let height = inputCGImage.height
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        var rawData = [UInt8](repeating: 0, count: height * width * 4)
        
        let context = CGContext(data: &rawData,
                                width: width,
                                height: height,
                                bitsPerComponent: bitsPerComponent,
                                bytesPerRow: bytesPerRow,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        
        context?.draw(inputCGImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        
        var grayPlane = [Int](repeating: 0, count: width * height)
        
        for i in 0..<(width * height) {
            let offset = i * 4
            let r = Double(rawData[offset])
            let g = Double(rawData[offset + 1])
            let b = Double(rawData[offset + 2])
            
            let rC = clamp(r * 1.2 - 20)
            let gC = clamp(g * 1.2 - 20)
            let bC = clamp(b * 1.2 - 20)
            
            grayPlane[i] = Int(0.299 * rC + 0.587 * gC + 0.114 * bC)
        }
        
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let oldPixel = grayPlane[i]
                let newPixel = oldPixel < 128 ? 0 : 255
                grayPlane[i] = newPixel
                
                let error = oldPixel - newPixel
                if x + 1 < width {
                    grayPlane[i + 1] = clamp(Double(grayPlane[i + 1]) + Double(error) * 7.0 / 16.0)
                }
                if y + 1 < height {
                    if x - 1 >= 0 {
                        grayPlane[i + width - 1] = clamp(Double(grayPlane[i + width - 1]) + Double(error) * 3.0 / 16.0)
                    }
                    grayPlane[i + width] = clamp(Double(grayPlane[i + width]) + Double(error) * 5.0 / 16.0)
                    if x + 1 < width {
                        grayPlane[i + width + 1] = clamp(Double(grayPlane[i + width + 1]) + Double(error) * 1.0 / 16.0)
                    }
                }
            }
        }
        
        var escPosData: [UInt8] = []
        let widthBytes = (width + 7) / 8
        let header: [UInt8] = [
            0x1D, 0x76, 0x30, 0x00,
            UInt8(widthBytes % 256), UInt8(widthBytes / 256),
            UInt8(height % 256), UInt8(height / 256)
        ]
        escPosData.append(contentsOf: header)
        
        for y in 0..<height {
            for xByte in 0..<widthBytes {
                var byteValue: UInt8 = 0
                for bit in 0..<8 {
                    let x = xByte * 8 + bit
                    if x < width {
                        if grayPlane[y * width + x] == 0 {
                            byteValue |= (1 << (7 - bit))
                        }
                    }
                }
                escPosData.append(byteValue)
            }
        }
        
        return escPosData
    }
    
    private func clamp(_ value: Double) -> Int {
        return Int(max(0, min(255, value)))
    }
}

// MARK: - Bluetooth Delegate
extension PrinterService: CBCentralManagerDelegate, CBPeripheralDelegate {
    
    func startScan() {
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScan()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        if name.contains("Printer") || name.contains("MTP") || name.contains("InnerPrinter") {
            self.connectedPeripheral = peripheral
            centralManager.stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
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
                self.writeCharacteristic = char
                
                let uuid = peripheral.identifier.uuidString
                var width = UserDefaults.standard.integer(forKey: "flutter.printer_width_dots")
                if width == 0 { width = WIDTH_58MM }
                if let name = peripheral.name?.uppercased(), (name.contains("80") || name.contains("T80")) {
                    width = WIDTH_80MM
                }
                self.syncToAppGroup(printerUUID: uuid, width: width)
                
                if isPrinting, let url = printQueue.first {
                    // Logic handled in printPdf
                }
            }
        }
    }
}

// MARK: - Image Extensions
extension UIImage {
    func resize(to width: Int) -> UIImage {
        let scale = CGFloat(width) / self.size.width
        let newHeight = self.size.height * scale
        UIGraphicsBeginImageContext(CGSize(width: CGFloat(width), height: newHeight))
        self.draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: newHeight))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage ?? self
    }
    
    func trim() -> UIImage? {
        guard let cgImage = self.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        var rawData = [UInt8](repeating: 0, count: height * width * 4)
        
        guard let context = CGContext(data: &rawData, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        
        var minX = width, maxX = 0, minY = height, maxY = 0, foundContent = false
        let threshold: UInt8 = 240
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = rawData[offset]
                let g = rawData[offset + 1]
                let b = rawData[offset + 2]
                if r < threshold || g < threshold || b < threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    foundContent = true
                }
            }
        }
        
        if !foundContent { return nil }
        let padding = 5
        minX = max(0, minX - padding); maxX = min(width, maxX + padding)
        minY = max(0, minY - padding); maxY = min(height, maxY + padding + 40)
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}