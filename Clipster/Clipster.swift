//
//  Clipster.swift
//  Clipster
//
//  Created by Rene Kumić on 17.02.2026.
//

import SwiftUI
import AppKit
internal import Combine
import Carbon
import ServiceManagement

// MARK: - Models

struct ClipboardItem: Identifiable, Codable {
    let id: UUID
    let content: String
    let timestamp: Date
    let type: ClipboardType
    var isPinned: Bool
    var imageFileName: String?

    // Runtime only — not persisted, loaded from disk on launch
    var imageData: Data? = nil

    enum CodingKeys: String, CodingKey {
        case id, content, timestamp, type, isPinned, imageFileName
    }
    
    enum ClipboardType: String, Codable {
        case text
        case url
        case code
        case image
    }
    
    init(content: String, type: ClipboardType = .text, isPinned: Bool = false, imageData: Data? = nil, imageFileName: String? = nil) {
        self.id = UUID()
        self.content = content
        self.timestamp = Date()
        self.type = type
        self.isPinned = isPinned
        self.imageData = imageData
        self.imageFileName = imageFileName
    }
    
    // Custom Codable implementation to exclude imageData
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        type = try container.decode(ClipboardType.self, forKey: .type)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        imageData = nil  // Not persisted
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(type, forKey: .type)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
        // imageData is intentionally not encoded
    }
}


// MARK: - Clipboard Manager

class ClipboardManager: ObservableObject {
    @Published var items: [ClipboardItem] = []
    private var lastChangeCount: Int = 0
    private var timer: Timer?
    private var expiryTimer: Timer?

    private var maxItems: Int {
        let val = UserDefaults.standard.integer(forKey: "maxItems")
        return val > 0 ? val : 100
    }

    private var expiryInterval: TimeInterval {
        let hours = UserDefaults.standard.integer(forKey: "expiryHours")
        if hours < 0 { return -1 }  // -1 means "Never"
        return TimeInterval(hours > 0 ? hours : 12) * 3600
    }

    // Screenshot directory polling
    private var screenshotTimer: Timer?
    private var knownScreenshotFiles: Set<String> = []
    private lazy var screenshotsDirectory: URL = {
        // Check the macOS screencapture preference for a custom save location
        if let customPath = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }()

    // Images stored as TIFF files in Application Support/Clipster/images/
    private static let imagesDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Clipster/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        loadHistory()
        seedKnownScreenshots()
        startMonitoring()
        startExpiryTimer()
        startScreenshotPolling()
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

    // MARK: - Screenshot Directory Polling

    /// Seed the known files set so we only pick up NEW screenshots after launch
    private func seedKnownScreenshots() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: screenshotsDirectory.path) else { return }
        knownScreenshotFiles = Set(files)
    }

    /// Poll the screenshots directory every 2 seconds for new PNG files.
    /// macOS shows a floating thumbnail for ~5 seconds before writing the file,
    /// so timer-based polling is more reliable than DispatchSource.
    private func startScreenshotPolling() {
        screenshotTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scanForNewScreenshots()
        }
    }

    private func scanForNewScreenshots() {
        guard UserDefaults.standard.object(forKey: "monitorScreenshots") == nil
              || UserDefaults.standard.bool(forKey: "monitorScreenshots") else { return }
        let fm = FileManager.default
        guard let allFiles = try? fm.contentsOfDirectory(atPath: screenshotsDirectory.path) else { return }
        let currentSet = Set(allFiles)
        let newFiles = currentSet.subtracting(knownScreenshotFiles)
        knownScreenshotFiles = currentSet

        guard !newFiles.isEmpty else { return }

        let now = Date()

        for fileName in newFiles {
            // Only pick up PNG files (macOS screenshots are PNG)
            guard fileName.lowercased().hasSuffix(".png") else { continue }

            let fileURL = screenshotsDirectory.appendingPathComponent(fileName)

            // Verify it was created recently (within 30 seconds to account for thumbnail delay)
            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                  let creationDate = attrs[.creationDate] as? Date,
                  now.timeIntervalSince(creationDate) < 30 else { continue }

            guard let imageData = try? Data(contentsOf: fileURL),
                  let nsImage = NSImage(data: imageData),
                  let tiffData = nsImage.tiffRepresentation else { continue }

            var newItem = ClipboardItem(content: "Screenshot", type: .image, imageData: tiffData)
            let storedName = "\(newItem.id.uuidString).tiff"
            saveImageFile(data: tiffData, named: storedName)
            newItem.imageFileName = storedName

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let insertIndex = self.items.firstIndex(where: { !$0.isPinned }) ?? self.items.endIndex
                self.items.insert(newItem, at: insertIndex)
                self.trimToMaxItems()
                self.saveHistory()
            }
        }
    }
    

    func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        
        // Check for image data first (screenshots and copied images).
        // NSImage(pasteboard:) handles all image UTIs (tiff, png, pict, etc.)
        if let image = NSImage(pasteboard: pasteboard), let imageData = image.tiffRepresentation {
            var newItem = ClipboardItem(content: "Image", type: .image, imageData: imageData)
            let fileName = "\(newItem.id.uuidString).tiff"
            saveImageFile(data: imageData, named: fileName)
            newItem.imageFileName = fileName
            
            DispatchQueue.main.async {
                let insertIndex = self.items.firstIndex(where: { !$0.isPinned }) ?? self.items.endIndex
                self.items.insert(newItem, at: insertIndex)
                self.trimToMaxItems()
                self.saveHistory()
            }
        } else if let string = pasteboard.string(forType: .string), !string.isEmpty {
            // Check against the first unpinned item to avoid duplicates
            let firstUnpinned = self.items.first(where: { !$0.isPinned })
            guard firstUnpinned?.content != string else { return }
            let type = detectType(for: string)
            let newItem = ClipboardItem(content: string, type: type)

            DispatchQueue.main.async {
                let insertIndex = self.items.firstIndex(where: { !$0.isPinned }) ?? self.items.endIndex
                self.items.insert(newItem, at: insertIndex)
                self.trimToMaxItems()
                self.saveHistory()
            }
        }
    }
    
    private func trimToMaxItems() {
        let unpinned = items.filter { !$0.isPinned }
        guard unpinned.count > maxItems else { return }
        let pruned = Array(unpinned.dropFirst(maxItems))
        for item in pruned where item.type == .image {
            if let fileName = item.imageFileName { deleteImageFile(named: fileName) }
        }
        let prunedIDs = Set(pruned.map { $0.id })
        items.removeAll { prunedIDs.contains($0.id) }
    }
    
    // MARK: - Expiry
    
    private func removeExpiredItems() {
        guard expiryInterval > 0 else { return }  // "Never" expire
        let cutoff = Date().addingTimeInterval(-expiryInterval)
        for item in items where !item.isPinned && item.timestamp < cutoff && item.type == .image {
            if let fileName = item.imageFileName { deleteImageFile(named: fileName) }
        }
        let before = items.count
        items.removeAll { !$0.isPinned && $0.timestamp < cutoff }
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
    
    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()

        // Re-sort: pinned items first, then unpinned, each group keeps its order
        let pinned = items.filter { $0.isPinned }
        let unpinned = items.filter { !$0.isPinned }
        items = pinned + unpinned
        saveHistory()
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
        
        if expiryInterval > 0 {
            let cutoff = Date().addingTimeInterval(-expiryInterval)
            // Delete image files for expired unpinned items before filtering
            for item in decoded where !item.isPinned && item.timestamp < cutoff && item.type == .image {
                if let fileName = item.imageFileName { deleteImageFile(named: fileName) }
            }
            decoded = decoded.filter { $0.isPinned || $0.timestamp >= cutoff }
        }
        
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

enum ClipboardTab: String, CaseIterable {
    case snippets = "Snippets"
    case screenshots = "Screenshots"
}

struct ContentView: View {
    @StateObject private var clipboardManager = ClipboardManager()
    @State private var searchText = ""
    @State private var hoveredItemId: UUID?
    @State private var selectedIndex: Int?
    @State private var keyMonitor: Any?
    @State private var selectedTab: ClipboardTab = .snippets
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var filteredItems: [ClipboardItem] {
        var base = clipboardManager.items

        // Filter by tab
        switch selectedTab {
        case .snippets:
            base = base.filter { $0.type != .image }
        case .screenshots:
            base = base.filter { $0.type == .image }
        }

        if searchText.isEmpty { return base }
        return base.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
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

                SettingsLink {
                    Image(systemName: "gear")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Preferences")

                Button(action: {
                    clipboardManager.clearAll()
                    selectedIndex = nil
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Clear all")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(ClipboardTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField(selectedTab == .snippets ? "Search snippets..." : "Search screenshots...", text: $searchText)
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
                    Image(systemName: selectedTab == .snippets ? "doc.on.clipboard" : "camera.viewfinder")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text(selectedTab == .snippets ? "No snippets yet" : "No screenshots yet")
                        .foregroundColor(.secondary)
                    if selectedTab == .screenshots {
                        Text("Take a screenshot with \u{2318}\u{21E7}3 or \u{2318}\u{21E7}4")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            let pinnedItems = filteredItems.filter { $0.isPinned }
                            let unpinnedItems = filteredItems.filter { !$0.isPinned }

                            if !pinnedItems.isEmpty {
                                HStack {
                                    Image(systemName: "pin.fill")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                    Text("Pinned")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.orange)
                                    Spacer()
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                            }

                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                // Insert section header before first unpinned item
                                if !pinnedItems.isEmpty && item.id == unpinnedItems.first?.id {
                                    Divider().padding(.vertical, 2)
                                    HStack {
                                        Text("Recent")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                }

                                ClipboardItemView(
                                    item: item,
                                    isHovered: hoveredItemId == item.id,
                                    isSelected: selectedIndex == index,
                                    onCopy: {
                                        clipboardManager.copyToClipboard(item)
                                    },
                                    onDelete: {
                                        clipboardManager.deleteItem(item)
                                        if let sel = selectedIndex, sel >= filteredItems.count - 1 {
                                            selectedIndex = filteredItems.count > 1 ? sel - 1 : nil
                                        }
                                    },
                                    onPin: {
                                        clipboardManager.togglePin(item)
                                    }
                                )
                                .id(item.id)
                                .onHover { hovering in
                                    hoveredItemId = hovering ? item.id : nil
                                }

                                Divider()
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { newIndex in
                        if let idx = newIndex, idx >= 0, idx < filteredItems.count {
                            withAnimation {
                                proxy.scrollTo(filteredItems[idx].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
        .overlay {
            if !hasSeenOnboarding {
                OnboardingOverlay {
                    hasSeenOnboarding = true
                }
            }
        }
        .onChange(of: searchText) { _ in
            selectedIndex = nil
        }
        .onChange(of: selectedTab) { _ in
            selectedIndex = nil
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Keyboard Navigation

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return handleKeyEvent(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let items = filteredItems
        guard !items.isEmpty else { return false }

        // Cmd+P — toggle pin
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "p" {
            if let idx = selectedIndex, idx < items.count {
                clipboardManager.togglePin(items[idx])
            }
            return true
        }

        // Only handle navigation keys without modifiers (allow normal typing in search)
        // Arrow keys carry .function and .numericPad flags on macOS — strip both
        let cleanFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        guard cleanFlags.isEmpty else {
            return false
        }

        switch event.specialKey {
        case .downArrow:
            if let idx = selectedIndex {
                selectedIndex = (idx + 1) % items.count
            } else {
                selectedIndex = 0
            }
            return true
        case .upArrow:
            if let idx = selectedIndex {
                selectedIndex = (idx - 1 + items.count) % items.count
            } else {
                selectedIndex = items.count - 1
            }
            return true
        default:
            break
        }

        switch event.keyCode {
        case 36: // Return
            if let idx = selectedIndex, idx < items.count {
                clipboardManager.copyToClipboard(items[idx])
            }
            return true
        case 51: // Delete/Backspace
            if let idx = selectedIndex, idx < items.count {
                clipboardManager.deleteItem(items[idx])
                if items.count <= 1 {
                    selectedIndex = nil
                } else if idx >= items.count - 1 {
                    selectedIndex = idx - 1
                }
            }
            return true
        default:
            return false
        }
    }
}

struct ClipboardItemView: View {
    let item: ClipboardItem
    let isHovered: Bool
    let isSelected: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    @State private var showCopiedFlash = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundColor(iconColor)
                    .frame(width: 24)

                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                        .offset(x: 4, y: 4)
                }
            }

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
                } else if item.type == .code {
                    Text(item.content)
                        .lineLimit(3)
                        .font(.system(.body, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                        )
                } else {
                    Text(item.content)
                        .lineLimit(3)
                        .font(.system(.body, design: .default))
                }

                HStack(spacing: 4) {
                    Text(timeAgo(from: item.timestamp))
                        .font(.caption)
                        .foregroundColor(.gray)
                    if item.isPinned {
                        Text("• Pinned")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if item.type == .text || item.type == .code || item.type == .url {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.gray)
                        let charCount = item.content.count
                        let wordCount = item.content.split(whereSeparator: \.isWhitespace).count
                        Text("\(charCount) chars, \(wordCount) word\(wordCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }

            Spacer()

            // Actions (show on hover or selection)
            if isHovered || isSelected {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Button(action: onPin) {
                            Image(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                        .help(item.isPinned ? "Unpin (⌘P)" : "Pin (⌘P)")

                        Button(action: {
                            onCopy()
                            showCopiedFlash = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                showCopiedFlash = false
                            }
                        }) {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy (⏎)")

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete (⌫)")
                    }

                    HStack(spacing: 6) {
                        Text("⏎ Copy")
                        Text("⌫ Del")
                        Text("⌘P Pin")
                    }
                    .font(.system(size: 9))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }
        }
        .padding()
        .background(
            ZStack {
                isSelected ? Color.accentColor.opacity(0.15) : Color.clear
                if showCopiedFlash {
                    Color.green.opacity(0.15)
                        .transition(.opacity)
                }
            }
        )
        .animation(.easeInOut(duration: 0.3), value: showCopiedFlash)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onDrag {
            if item.type == .image, let data = item.imageData, let nsImage = NSImage(data: data) {
                return NSItemProvider(object: nsImage)
            } else {
                return NSItemProvider(object: item.content as NSString)
            }
        }
        .onTapGesture {
            onCopy()
            showCopiedFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                showCopiedFlash = false
            }
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

// MARK: - Onboarding Overlay

struct OnboardingOverlay: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)

                Text("Welcome to Clipster!")
                    .font(.title2)
                    .fontWeight(.bold)

                VStack(spacing: 12) {
                    shortcutRow(keys: "\u{2318}\u{21E7}V", label: "Open Clipster from anywhere")
                    shortcutRow(keys: "\u{2191}\u{2193}", label: "Navigate items")
                    shortcutRow(keys: "\u{23CE}", label: "Copy selected item")
                    shortcutRow(keys: "\u{232B}", label: "Delete selected item")
                    shortcutRow(keys: "\u{2318}P", label: "Pin / unpin item")
                }

                Text("Clipster lives in your menu bar and captures everything you copy.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Get Started") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
    }

    private func shortcutRow(keys: String, label: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .frame(width: 60, alignment: .trailing)
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("maxItems") private var maxItems: Int = 100
    @AppStorage("expiryHours") private var expiryHours: Int = 12
    @AppStorage("monitorScreenshots") private var monitorScreenshots: Bool = true
    @State private var launchAtLogin: Bool = false
    @State private var showClearConfirmation = false

    private var screenshotsPath: String {
        if let customPath = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return (customPath as NSString).expandingTildeInPath
        }
        return "~/Desktop"
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            screenshotsTab
                .tabItem {
                    Label("Screenshots", systemImage: "camera.viewfinder")
                }
        }
        .frame(width: 420, height: 320)
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = (SMAppService.mainApp.status == .enabled)
                        }
                    }
            } header: {
                Text("Startup")
            }

            Section {
                Picker("Max History Size", selection: $maxItems) {
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                }

                Picker("Auto-Expire After", selection: $expiryHours) {
                    Text("1 hour").tag(1)
                    Text("6 hours").tag(6)
                    Text("12 hours").tag(12)
                    Text("24 hours").tag(24)
                    Text("48 hours").tag(48)
                    Text("Never").tag(-1)
                }
            } header: {
                Text("History")
            }

            Section {
                Button("Clear All History") {
                    showClearConfirmation = true
                }
                .foregroundColor(.red)
                .alert("Clear All History?", isPresented: $showClearConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear All", role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "clipboardHistory")
                    }
                } message: {
                    Text("This will permanently delete all clipboard history including pinned items.")
                }
            } header: {
                Text("Danger Zone")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Screenshots Tab

    private var screenshotsTab: some View {
        Form {
            Section {
                Toggle("Monitor Screenshot Directory", isOn: $monitorScreenshots)
            } header: {
                Text("Capture")
            }

            Section {
                LabeledContent("Screenshot Location") {
                    Text(screenshotsPath)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("Change this in System Settings > Keyboard > Screenshots, or via the Screenshot app (\u{2318}\u{21E7}5).")
                    .font(.caption)
                    .foregroundColor(.gray)
            } header: {
                Text("Location")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    private var hotKeyRef: EventHotKeyRef?

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

        registerHotKey()
    }

    // Registers Cmd+Shift+V as a global hotkey via Carbon (no Accessibility permission needed)
    private func registerHotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x434C5053) // "CLPS"
        hotKeyID.id = 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.togglePopover() }
                return noErr
            },
            1, &eventType, selfPtr, nil
        )

        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),           // V key
            UInt32(cmdKey | shiftKey),     // Cmd+Shift
            hotKeyID,
            GetApplicationEventTarget(),
            0, &hotKeyRef
        )
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
            SettingsView()
        }
    }
}

// Made by Rene Kumic on 18.02.2026.
//This app is created when the MacOS lacked clipboard manager with screenshots and all features, and all apps that required payments are too expensive. 

