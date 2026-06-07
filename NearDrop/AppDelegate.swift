//
//  AppDelegate.swift
//  NearDrop
//
//  Created by Grishka on 08.04.2023.
//

import Cocoa
import UserNotifications
import NearbyShare
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, MainAppDelegate{
	private var statusItem:NSStatusItem?
	private var activeIncomingTransfers:[String:TransferInfo]=[:]

    func applicationDidFinishLaunching(_ aNotification: Notification) {
		let menu=NSMenu()
		menu.addItem(withTitle: NSLocalizedString("VisibleToEveryone", value: "Visible to everyone", comment: ""), action: nil, keyEquivalent: "")
		menu.addItem(withTitle: String(format: NSLocalizedString("DeviceName", value: "Device name: %@", comment: ""), arguments: [Host.current().localizedName!]), action: nil, keyEquivalent: "")
		menu.addItem(NSMenuItem.separator())
		let changeDirItem = NSMenuItem(title: NSLocalizedString("ChangeSaveDestination", value: "Change Save Destination...", comment: ""), action: #selector(changeSaveDestination), keyEquivalent: "")
		changeDirItem.image = NSImage(named: NSImage.folderName)
		changeDirItem.image?.size = NSSize(width: 16, height: 16)
		menu.addItem(changeDirItem)
		menu.addItem(withTitle: NSLocalizedString("Quit", value: "Quit NearDrop", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
		statusItem=NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem?.button?.image=NSImage(named: "MenuBarIcon")
		statusItem?.menu=menu
		statusItem?.behavior = .removalAllowed
		
		let nc=UNUserNotificationCenter.current()
		nc.requestAuthorization(options: [.alert, .sound]) { granted, err in
			if !granted{
				DispatchQueue.main.async {
					self.showNotificationsDeniedAlert()
				}
			}
		}
		nc.delegate=self
		let incomingTransfersCategory=UNNotificationCategory(identifier: "INCOMING_TRANSFERS", actions: [
			UNNotificationAction(identifier: "ACCEPT", title: NSLocalizedString("Accept", comment: ""), options: UNNotificationActionOptions.authenticationRequired),
			UNNotificationAction(identifier: "DECLINE", title: NSLocalizedString("Decline", comment: ""))
		], intentIdentifiers: [])
		let errorsCategory=UNNotificationCategory(identifier: "ERRORS", actions: [], intentIdentifiers: [])
		nc.setNotificationCategories([incomingTransfersCategory, errorsCategory])
		NearbyConnectionManager.shared.mainAppDelegate=self
		NearbyConnectionManager.shared.becomeVisible()
	}
	
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		statusItem?.isVisible=true
		return true
	}

    func applicationWillTerminate(_ aNotification: Notification) {
		UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
	
	func showNotificationsDeniedAlert(){
		let alert=NSAlert()
		alert.alertStyle = .critical
		alert.messageText=NSLocalizedString("NotificationsDenied.Title", value: "Notification Permission Required", comment: "")
		alert.informativeText=NSLocalizedString("NotificationsDenied.Message", value: "NearDrop needs to be able to display notifications for incoming file transfers. Please allow notifications in System Settings.", comment: "")
		alert.addButton(withTitle: NSLocalizedString("NotificationsDenied.OpenSettings", value: "Open settings", comment: ""))
		alert.addButton(withTitle: NSLocalizedString("Quit", value: "Quit NearDrop", comment: ""))
		let result=alert.runModal()
		if result==NSApplication.ModalResponse.alertFirstButtonReturn{
			NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
		}else if result==NSApplication.ModalResponse.alertSecondButtonReturn{
			NSApplication.shared.terminate(nil)
		}
	}
	
	@objc func changeSaveDestination() {
		let openPanel = NSOpenPanel()
		openPanel.canChooseFiles = false
		openPanel.canChooseDirectories = true
		openPanel.canCreateDirectories = true
		openPanel.prompt = NSLocalizedString("Select", value: "Select", comment: "")
		openPanel.message = NSLocalizedString("SelectSaveDestination", value: "Select a folder to save incoming transfers", comment: "")
		
		NSApp.activate(ignoringOtherApps: true)
		if openPanel.runModal() == .OK {
			if let url = openPanel.url {
				do {
					let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
					SaveDestinationManager.shared.customDestinationBookmark = bookmarkData
				} catch {
					print("Failed to create bookmark data: \(error)")
				}
			}
		}
	}
	
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		let transferID=response.notification.request.content.userInfo["transferID"]! as! String
		NearbyConnectionManager.shared.submitUserConsent(transferID: transferID, accept: response.actionIdentifier=="ACCEPT")
		if response.actionIdentifier != "ACCEPT"{
			activeIncomingTransfers.removeValue(forKey: transferID)
		}
		completionHandler()
	}
	
	func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo) {
		let fileStr:String
		if let textTitle=transfer.textDescription{
			fileStr=textTitle
		}else if transfer.files.count==1{
			fileStr=transfer.files[0].name
		}else{
			fileStr=String.localizedStringWithFormat(NSLocalizedString("NFiles", value: "%d files", comment: ""), transfer.files.count)
		}
		
		self.activeIncomingTransfers[transfer.id]=TransferInfo(device: device, transfer: transfer)
		
		DispatchQueue.main.async {
			let alert = NSAlert()
			alert.messageText = "Incoming Transfer from \(device.name)"
			alert.informativeText = "PIN: \(transfer.pinCode ?? "")\n\n\(device.name) is sending you \(fileStr)."
			alert.alertStyle = .informational
			alert.addButton(withTitle: NSLocalizedString("Accept", comment: ""))
			alert.addButton(withTitle: NSLocalizedString("Decline", comment: ""))
			
			NSApp.activate(ignoringOtherApps: true)
			let response = alert.runModal()
			let accepted = (response == .alertFirstButtonReturn)
			NearbyConnectionManager.shared.submitUserConsent(transferID: transfer.id, accept: accepted)
			if !accepted {
				self.activeIncomingTransfers.removeValue(forKey: transfer.id)
			}
		}
	}
	
	func incomingTransfer(id: String, didFinishWith error: Error?) {
		ProgressStateManager.shared.removeTransfersForConnection(id: id)
		guard let transfer=self.activeIncomingTransfers[id] else {return}
		if let error=error{
			let notificationContent=UNMutableNotificationContent()
			notificationContent.title=String(format: NSLocalizedString("TransferError", value: "Failed to receive files from %@", comment: ""), arguments: [transfer.device.name])
			if let ne=(error as? NearbyError){
				switch ne{
				case .inputOutput:
					notificationContent.body="I/O Error";
				case .protocolError(_):
					notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
				case .requiredFieldMissing:
					notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
				case .ukey2:
					notificationContent.body=NSLocalizedString("Error.Crypto", value: "Encryption error", comment: "")
				case .canceled(reason: _):
					break; // can't happen for incoming transfers
				}
			}else{
				notificationContent.body=error.localizedDescription
			}
			notificationContent.categoryIdentifier="ERRORS"
			UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "transferError_"+id, content: notificationContent, trigger: nil))
		}
		self.activeIncomingTransfers.removeValue(forKey: id)
		ProgressStateManager.shared.removeTransfersForConnection(id: id)
	}
	
	func incomingTransfer(id: String, didStartWith deviceName: String, fileName: String, totalBytes: Int64, connectionId: String) {
		ProgressStateManager.shared.addTransfer(state: TransferState(id: id, connectionId: connectionId, deviceName: deviceName, fileName: fileName, totalBytes: totalBytes))
	}
	
	func incomingTransfer(id: String, didUpdateProgress bytesTransferred: Int64) {
		ProgressStateManager.shared.updateTransfer(id: id, bytes: bytesTransferred)
	}
}

struct TransferInfo{
	let device:RemoteDeviceInfo
	let transfer:TransferMetadata
}

class TransferState: ObservableObject, Identifiable {
    let id: String
    let connectionId: String
    let deviceName: String
    let fileName: String
    let totalBytes: Int64
    
    @Published var bytesTransferred: Int64 = 0
    @Published var speedBytesPerSecond: Double = 0.0
    
    private var lastUpdateTime = Date()
    private var lastBytesTransferred: Int64 = 0
    
    init(id: String, connectionId: String, deviceName: String, fileName: String, totalBytes: Int64) {
        self.id = id
        self.connectionId = connectionId
        self.deviceName = deviceName
        self.fileName = fileName
        self.totalBytes = totalBytes
    }
    
    func update(bytes: Int64) {
        let now = Date()
        let timeDiff = now.timeIntervalSince(self.lastUpdateTime)
        
        // Update speed calculations and UI at most 10 times a second (or if finished)
        if timeDiff > 0.1 || bytes == totalBytes {
            let bytesDiff = bytes - self.lastBytesTransferred
            if timeDiff > 0 {
                // Calculate speed smoothly
                self.speedBytesPerSecond = Double(bytesDiff) / timeDiff
            }
            self.lastUpdateTime = now
            self.lastBytesTransferred = bytes
            self.bytesTransferred = bytes // triggers SwiftUI update
        }
    }
}

class ProgressStateManager: ObservableObject {
    static let shared = ProgressStateManager()
    @Published var activeTransfers: [TransferState] = []
    
    func addTransfer(state: TransferState) {
        DispatchQueue.main.async {
            self.activeTransfers.append(state)
            if #available(macOS 11.0, *) {
                ProgressWindowController.shared.showWindow()
            }
        }
    }
    
    func updateTransfer(id: String, bytes: Int64) {
        DispatchQueue.main.async {
            if let transfer = self.activeTransfers.first(where: { $0.id == id }) {
                transfer.update(bytes: bytes)
            }
        }
    }
    
    func removeTransfer(id: String) {
        DispatchQueue.main.async {
            self.activeTransfers.removeAll(where: { $0.id == id })
            if self.activeTransfers.isEmpty {
                if #available(macOS 11.0, *) {
                    ProgressWindowController.shared.hideWindow()
                }
            }
        }
    }
    
    func removeTransfersForConnection(id: String) {
        DispatchQueue.main.async {
            self.activeTransfers.removeAll(where: { $0.connectionId == id })
            if self.activeTransfers.isEmpty {
                if #available(macOS 11.0, *) {
                    ProgressWindowController.shared.hideWindow()
                }
            }
        }
    }
}

@available(macOS 11.0, *)
struct ProgressViewUI: View {
    @ObservedObject var manager = ProgressStateManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manager.activeTransfers.isEmpty {
                Text("No active transfers")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(manager.activeTransfers) { transfer in
                    TransferRow(transfer: transfer)
                }
            }
        }
        .padding()
        .frame(width: 350)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

@available(macOS 11.0, *)
struct TransferRow: View {
    @ObservedObject var transfer: TransferState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(transfer.deviceName) - \(transfer.fileName)")
                .font(.headline)
            
            ProgressView(value: Double(transfer.bytesTransferred), total: Double(max(1, transfer.totalBytes)))
                .progressViewStyle(LinearProgressViewStyle())
            
            HStack {
                Text(formatBytes(transfer.bytesTransferred) + " / " + formatBytes(transfer.totalBytes))
                Spacer()
                Text(formatSpeed(transfer.speedBytesPerSecond) + " - " + formatTimeRemaining(transfer: transfer))
                
                Button(action: {
                    NearbyConnectionManager.shared.cancelIncomingTransfer(payloadId: transfer.id, connectionId: transfer.connectionId)
                    ProgressStateManager.shared.removeTransfer(id: transfer.id)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 4)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .shadow(radius: 1)
    }
    
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    func formatSpeed(_ speed: Double) -> String {
        if speed == 0 { return "Calculating..." }
        return formatBytes(Int64(speed)) + "/s"
    }
    
    func formatTimeRemaining(transfer: TransferState) -> String {
        if transfer.speedBytesPerSecond == 0 { return "" }
        let remainingBytes = transfer.totalBytes - transfer.bytesTransferred
        let seconds = remainingBytes / Int64(transfer.speedBytesPerSecond)
        if seconds < 60 {
            return "\(seconds)s left"
        } else {
            return "\(seconds / 60)m \(seconds % 60)s left"
        }
    }
}

@available(macOS 11.0, *)
class ProgressWindowController {
    static let shared = ProgressWindowController()
    var window: NSPanel?
    
    func showWindow() {
        if window == nil {
            let hostingController = NSHostingController(rootView: ProgressViewUI())
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 100),
                                styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .closable],
                                backing: .buffered,
                                defer: false)
            panel.title = "NearDrop Transfers"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.contentViewController = hostingController
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
    }
    
    func hideWindow() {
        window?.close()
        window = nil
    }
}
