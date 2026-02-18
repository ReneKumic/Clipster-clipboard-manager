//
//  Clipster.swift
//  Clipster
//
//  Created by Rene Kumić on 17.02.2026.
//

import SwiftUI
import AppKit

// MARK: - Models

struct ClipboardItem: Identifiable, Codable {
    let id: UUID
    let content: String
    let timestamp: Date
    let type: ClipboardType
    var imageFileName: String?
    
    // Runtime only — not persisted, loaded from disk on launch
    var imageData: Data? = nil
    
    enum CodingKeys: String, CodingKey {
        case id, content, timestamp, type, imageFileName
    }
    
    enum ClipboardType: String, Codable {
        case text
        case url
        case code
        case image
    }
    
    init(content: String, type: ClipboardType = .text, imageData: Data? = nil, imageFileName: String? = nil) {
        self.id = UUID()
        self.content = content
        self.timestamp = Date()
        self.type = type
        self.imageData = imageData
        self.imageFileName = imageFileName
    }
}


// MARK: - Clipboard Manager

class ClipboardManager: ObservableObject {
    @Published var items: [ClipboardItem] = []
    private var lastChangeCount: Int = 0
    private var timer: Timer?
    private var expiryTimer: Timer?
    private let maxItems = 100
    private let expiryInterval: TimeInterval = 12 * 60 * 60  // 12 hours
    
    // Images stored as TIFF files in Application Support/Clipster/images/
    private static let imagesDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Clipster/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    init() {
        loadHistory()
        startMonitoring()
        startExpiryTimer()
    }
    
    // MARK: - Monitoring
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }
    
    private func startExpiryTimer() {
        // Check for expired items every hour
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.removeExpiredItems()
        }
    }
    

    func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        
        // Check for image data first (screenshots and copied images)
        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            var newItem = ClipboardItem(content: "Image", type: .image, imageData: imageData)
            let fileName = "\(newItem.id.uuidString).tiff"
            saveImageFile(data: imageData, named: fileName)
            newItem.imageFileName = fileName
            
            DispatchQueue.main.async {
                self.items.insert(newItem, at: 0)
                self.trimToMaxItems()
                self.saveHistory()
            }
        } else if let string = pasteboard.string(forType: .string), !string.isEmpty {
            guard items.first?.content != string else { return }
            let type = detectType(for: string)
            let newItem = ClipboardItem(content: string, type: type)
            
            DispatchQueue.main.async {
                self.items.insert(newItem, at: 0)
                self.trimToMaxItems()
                self.saveHistory()
            }
        }
    }
    
    private func trimToMaxItems() {
        guard items.count > maxItems else { return }
        let pruned = Array(items.dropFirst(maxItems))
        for item in pruned where item.type == .image {
            if let fileName = item.imageFileName { deleteImageFile(named: fileName) }
        }
        items = Array(items.prefix(maxItems))
    }
    
    // MARK: - Expiry
    
    private func removeExpiredItems() {
        let cutoff = Date().addingTimeInterval(-expiryInterval)
        for item in items where item.timestamp < cutoff && item.type == .image {
            if let fileName = item.imageFileName { deleteImageFile(named: fileName) }
        }
        let before = items.count
        items.removeAll { $0.timestamp < cutoff }
        if items.count != before { saveHistory() }
    }
    
    // MARK: - Actions
    

    func detectType(for string: String) -> ClipboardItem.ClipboardType {
        if string.starts(with: "http://") || string.starts(with: "https://") {
            return .url
        } else if string.contains("func ") || string.contains("import ") || string.contains("{") {
            return .code
        }
        return .text
    }
    
    func copyToClipboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        if item.type == .image {
            let data = item.imageData ?? item.imageFileName.flatMap { loadImageFile(named: $0) }
            if let imageData = data {
                pasteboard.setData(imageData, forType: .tiff)
            }
        } else {
            pasteboard.setString(item.content, forType: .string)
        }
        lastChangeCount = pasteboard.changeCount
        
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let movedItem = items.remove(at: index)
            items.insert(movedItem, at: 0)
            saveHistory()
        }
    }
    
    func deleteItem(_ item: ClipboardItem) {
        if item.type == .image, let fileName = item.imageFileName {
            deleteImageFile(named: fileName)
        }
        items.removeAll { $0.id == item.id }
        saveHistory()
    }
    
    func clearAll() {
        for item in items where item.type == .image {
            if let fileName = item.imageFileName { deleteImageFile(named: fileName) }
        }
        items.removeAll()
        saveHistory()
    }
    
    // MARK: - Image File Management
    
    private func saveImageFile(data: Data, named fileName: String) {
        let url = Self.imagesDirectory.appendingPathComponent(fileName)
        try? data.write(to: url)
    }
    
    private func loadImageFile(named fileName: String) -> Data? {
        let url = Self.imagesDirectory.appendingPathComponent(fileName)
        return try? Data(contentsOf: url)
    }
    
    private func deleteImageFile(named fileName: String) {
        let url = Self.imagesDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }
    
    // MARK: - Persistence
    

    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: "clipboardHistory")
        }
    }
    
    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "clipboardHistory"),
              var decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return }
        
        let cutoff = Date().addingTimeInterval(-expiryInterval)
        
        // Delete image files for expired items before filtering
        for item in decoded where item.timestamp < cutoff && item.type == .image {
            if let fileName = item.imageFileName { deleteImageFile(named: fileName) }
        }
        decoded = decoded.filter { $0.timestamp >= cutoff }
        
        // Load image data from disk for image items
        for i in decoded.indices {
            if decoded[i].type == .image, let fileName = decoded[i].imageFileName {
                decoded[i].imageData = loadImageFile(named: fileName)
            }
        }
        
        items = decoded
        saveHistory()  // Persist the filtered (non-expired) list
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var clipboardManager = ClipboardManager()
    @State private var searchText = ""
    @State private var hoveredItemId: UUID?
    
    var filteredItems: [ClipboardItem] {
        if searchText.isEmpty {
            return clipboardManager.items
        }
        return clipboardManager.items.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }
    

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("Clipster")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button(action: {
                    clipboardManager.clearAll()
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Clear all")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Search clipboard...", text: $searchText)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.bottom, 10)
            
            Divider()
            
            // Clipboard items list
            if filteredItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("No clipboard items yet")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredItems) { item in
                            ClipboardItemView(
                                item: item,
                                isHovered: hoveredItemId == item.id,
                                onCopy: {
                                    clipboardManager.copyToClipboard(item)
                                },
                                onDelete: {
                                    clipboardManager.deleteItem(item)
                                }
                            )
                            .onHover { hovering in
                                hoveredItemId = hovering ? item.id : nil
                            }
                            
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
    }
}

struct ClipboardItemView: View {
    let item: ClipboardItem
    let isHovered: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            Image(systemName: iconName)
                .font(.title3)
                .foregroundColor(iconColor)
                .frame(width: 24)
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                if item.type == .image {
                    if let data = item.imageData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 80)
                            .cornerRadius(4)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundColor(.gray)
                    }
                    Text("Image")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(item.content)
                        .lineLimit(3)
                        .font(.system(.body, design: .default))
                }
                
                Text(timeAgo(from: item.timestamp))
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            // Actions (show on hover)
            if isHovered {
                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture {
            onCopy()
        }
    }
    
    var iconName: String {
        switch item.type {
        case .text:  return "doc.text"
        case .url:   return "link"
        case .code:  return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        }
    }
    
    var iconColor: Color {
        switch item.type {
        case .text:  return .primary
        case .url:   return .blue
        case .code:  return .purple
        case .image: return .green
        }
    }
    
    func timeAgo(from date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 {
            return "Just now"
        } else if seconds < 3600 {
            let m = Int(seconds / 60)
            return "\(m) minute\(m == 1 ? "" : "s") ago"
        } else if seconds < 86400 {
            let h = Int(seconds / 3600)
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        } else {
            let d = Int(seconds / 86400)
            return "\(d) day\(d == 1 ? "" : "s") ago"
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipster")
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())
    }
    
    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}

// MARK: - App

@main
struct ClipsterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// Made by Rene Kumic on 18.02.2026.
//This app is created when the MacOS lacked clipboard manager with screenshots and all features, and all apps that required payments are too expensive. 
