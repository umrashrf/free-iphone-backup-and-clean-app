import SwiftUI
import Photos
import MobileCoreServices
import AVFoundation

// MARK: - Model

struct UploadItem: Identifiable, Hashable {
    let id = UUID()
    let identifier: String   // albumName/localIdentifier
    let albumName: String
    let fileName: String
    var progress: Double = 0
    var isCompleted: Bool = false
    var isFailed: Bool = false
}

// MARK: - UploadOperation

final class UploadOperation: Operation {
    // Inputs
    private let asset: PHAsset
    private let albumName: String
    private let serverURL: URL
    private let username: String
    private let password: String
    private let deleteAfterUpload: Bool
    private let maxRetries: Int
    // Callbacks
    var progressHandler: ((Double) -> Void)?
    var completionHandler: ((Bool) -> Void)? // success or failure
    // Internal
    private var task: URLSessionUploadTask?
    private var currentRetry = 0
    private var tempFileURL: URL?
    
    // KVO for Operation
    private var _executing = false
    override var isExecuting: Bool { _executing }
    private var _finished = false
    override var isFinished: Bool { _finished }
    
    init(asset: PHAsset,
         albumName: String,
         serverURL: URL,
         username: String,
         password: String,
         deleteAfterUpload: Bool,
         maxRetries: Int = 2) {
        self.asset = asset
        self.albumName = albumName
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.deleteAfterUpload = deleteAfterUpload
        self.maxRetries = maxRetries
        super.init()
    }
    
    override func start() {
        if isCancelled {
            finish()
            return
        }
        willChangeValue(forKey: "isExecuting")
        _executing = true
        didChangeValue(forKey: "isExecuting")
        
        beginUploadAttempt()
    }
    
    private func finish() {
        task?.cancel()
        if let tmp = tempFileURL { try? FileManager.default.removeItem(at: tmp) }
        willChangeValue(forKey: "isExecuting")
        willChangeValue(forKey: "isFinished")
        _executing = false
        _finished = true
        didChangeValue(forKey: "isExecuting")
        didChangeValue(forKey: "isFinished")
    }
    
    private func beginUploadAttempt() {
        guard !isCancelled else { finish(); return }
        
        // 1) create temp file for multipart
        let tmpDir = FileManager.default.temporaryDirectory
        let multipartFile = tmpDir.appendingPathComponent("upload-\(UUID().uuidString).tmp")
        tempFileURL = multipartFile
        
        // prepare boundary and prefix/suffix bytes
        let boundary = "Boundary-\(UUID().uuidString)"
        let lineBreak = "\r\n"
        var prefix = Data()
        prefix.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        prefix.append("Content-Disposition: form-data; name=\"album\"\(lineBreak + lineBreak)".data(using: .utf8)!)
        prefix.append("\(albumName)\(lineBreak)".data(using: .utf8)!)
        prefix.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        // File field, server expects "photos" (match server)
        let filename = asset.localIdentifier + (asset.mediaType == .video ? ".mp4" : ".jpg")
        prefix.append("Content-Disposition: form-data; name=\"photos\"; filename=\"\(filename)\"\(lineBreak)".data(using: .utf8)!)
        let contentType = (asset.mediaType == .video) ? "video/mp4" : "image/jpeg"
        prefix.append("Content-Type: \(contentType)\(lineBreak + lineBreak)".data(using: .utf8)!)
        let suffix = ("\r\n--\(boundary)--\(lineBreak)").data(using: .utf8)!
        
        // create empty file and open for writing
        FileManager.default.createFile(atPath: multipartFile.path, contents: nil, attributes: nil)
        guard let outputStream = OutputStream(url: multipartFile, append: true) else {
            finish()
            completionHandler?(false)
            return
        }
        outputStream.open()
        defer { outputStream.close() }
        
        // write prefix
        _ = prefix.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return outputStream.write(base, maxLength: prefix.count)
        }
        
        // 2) stream asset bytes into file using PHAssetResourceManager.requestData
        // Find suitable PHAssetResource (original)
        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer original files
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto || $0.type == .photo || $0.type == .pairedVideo || $0.type == .video || $0.type == .fullSizeVideo }) ?? resources.first else {
            // cannot find resource → fail fast
            // write suffix to keep multipart well-formed
            _ = suffix.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return outputStream.write(base, maxLength: suffix.count)
            }
            finish()
            completionHandler?(false)
            return
        }
        
        let resourceManager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        
        // We don't know total size easily — try to get size from resource value if present
        var expectedSize: Int64? = nil
        if let val = resource.value(forKey: "fileSize") as? CLong {
            expectedSize = Int64(val)
        }
        // We'll accumulate progress based on bytes received
        var totalReceived: Int64 = 0
        
        // Use a DispatchGroup to wait for streaming completion before starting upload
        let group = DispatchGroup()
        group.enter()
        var streamingFailed = false
        
        resourceManager.requestData(for: resource, options: options, dataReceivedHandler: { chunk in
            if self.isCancelled {
                streamingFailed = true
                group.leave()
                return
            }
            // write chunk to outputStream
            chunk.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var written = 0
                while written < chunk.count {
                    let w = outputStream.write(base.advanced(by: written), maxLength: chunk.count - written)
                    if w <= 0 { break }
                    written += w
                }
            }
            totalReceived += Int64(chunk.count)
            // report progress (during file assembly). Normalized to [0, 0.6] so upload portion can move later.
            var p: Double = 0
            if let expected = expectedSize, expected > 0 {
                p = min(0.6, Double(totalReceived) / Double(expected) * 0.6)
            } else {
                // best-effort
                p = min(0.6, Double(totalReceived) / max(1.0, Double(totalReceived)) * 0.3 + 0.3)
            }
            DispatchQueue.main.async { self.progressHandler?(p) }
        }, completionHandler: { error in
            if let _ = error { streamingFailed = true }
            group.leave()
        })
        
        // Wait for streaming to finish or cancellation
        group.wait()
        if streamingFailed || isCancelled {
            // cleanup
            try? FileManager.default.removeItem(at: multipartFile)
            finish()
            completionHandler?(false)
            return
        }
        
        // write suffix
        _ = suffix.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return outputStream.write(base, maxLength: suffix.count)
        }
        
        // 3) perform upload using URLSession.uploadTask(fromFile:)
        // Build request with auth and content-type including boundary
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        let loginString = "\(username):\(password)"
        let base64Login = loginString.data(using: .utf8)?.base64EncodedString() ?? ""
        request.setValue("Basic \(base64Login)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Use dedicated session to capture progress via delegate if desired. Here we use shared and poll via observation.
        let session = URLSession(configuration: .default)
        
        // For progress reporting: we'll attempt to read file size and report uploaded bytes ratio in a timer.
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: multipartFile.path)[.size] as? NSNumber)?.int64Value ?? 0
        var lastUploadProgressReported: Double = 0
        
        // start upload task
        task = session.uploadTask(with: request, fromFile: multipartFile) { data, response, error in
            let success = (error == nil) && ((response as? HTTPURLResponse)?.statusCode == 200)
            DispatchQueue.main.async {
                self.progressHandler?(1.0)
            }
            if success {
                // optionally delete asset if requested (cannot delete from inside background thread without permission)
                if self.deleteAfterUpload {
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.deleteAssets([self.asset] as NSFastEnumeration)
                    }, completionHandler: { _, _ in })
                }
                self.completionHandler?(true)
                self.finish()
            } else {
                // retry if allowed
                self.currentRetry += 1
                if self.currentRetry <= self.maxRetries && !self.isCancelled {
                    // remove file and try again after a brief backoff
                    try? FileManager.default.removeItem(at: multipartFile)
                    // small backoff
                    let backoff = Double(self.currentRetry) * 2.0
                    DispatchQueue.global().asyncAfter(deadline: .now() + backoff) {
                        // reset and attempt again (note: this reuses same operation instance)
                        self.beginUploadAttempt()
                    }
                } else {
                    self.completionHandler?(false)
                    self.finish()
                }
            }
        }
        
        // Observe upload progress by polling file offset on disk (coarse) — not perfect but avoids delegate complexity.
        // Start upload
        task?.resume()
        
        // Optionally: spawn a short timer to report upload portion progress (0.6 -> 1.0)
        // This is coarse but avoids blocking; we stop when task completes.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let multipartURL = self.tempFileURL, fileSize > 0 else { return }
            while self.task != nil && self.task?.state == .running && !self.isCancelled {
                let uploadedBytes = self.task?.countOfBytesSent ?? 0
                let p = min(1.0, 0.6 + Double(uploadedBytes) / Double(max(1, fileSize)) * 0.4)
                if p - lastUploadProgressReported > 0.01 {
                    lastUploadProgressReported = p
                    DispatchQueue.main.async { self.progressHandler?(p) }
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var statusMessage = "Idle"
    @State private var isUploading = false
    @State private var uploadedFiles = Set<String>()
    @State private var deleteAfterUpload = false
    @State private var stopAfterCurrent = false
    @State private var uploadItems: [UploadItem] = []
    @State private var totalUploaded: Int = 0
    @State private var retryCounts: [String: Int] = [:]
    @State private var useDirectUpload = true // kept for UI but the implementation streams to disk always
    
    // New UI state
    @State private var currentAlbumName: String = ""
    @State private var totalPhotoCount: Int = 0
    @State private var albumUploadProgress: [String: Int] = [:]
    
    // server
    let serverURL = URL(string: "http://192.168.4.42:3001/upload")!
    let username = "admin"
    let password = "change_this_password"
    
    // operation queue
    private let uploadQueue = OperationQueue()
    private let uploadedFilesKey = "uploadedFiles"
    
    var overallProgress: Double {
        guard totalPhotoCount > 0 else { return 0 }
        return Double(totalUploaded) / Double(totalPhotoCount)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("iPhone → Mac Backup").font(.title)
            
            if isUploading {
                VStack(spacing: 4) {
                    Text("Current Album: \(currentAlbumName)").foregroundColor(.gray)
                    Text("Total Photos: \(totalPhotoCount)").foregroundColor(.gray)
                }
            }
            
            Text(statusMessage).foregroundColor(.gray)
            
            if isUploading {
                VStack(spacing: 16) {
                    VStack {
                        Text("\(totalUploaded) of \(totalPhotoCount) files uploaded")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        ProgressView(value: overallProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(height: 8)
                            .accentColor(overallProgress >= 1.0 ? .green : .blue)
                    }.padding(.horizontal)
                    
                    List {
                        ForEach(uploadItems) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(item.albumName)/\(item.fileName)").lineLimit(1)
                                    if !item.isCompleted && !item.isFailed {
                                        ProgressView(value: item.progress)
                                            .progressViewStyle(LinearProgressViewStyle())
                                    }
                                }
                                Spacer()
                                if item.isCompleted { Image(systemName: "checkmark.circle.fill").foregroundColor(.green) }
                                if item.isFailed { Image(systemName: "xmark.circle.fill").foregroundColor(.red) }
                            }
                        }
                    }
                    .frame(height: 300)
                    
                    Button("Stop After Current Batch") {
                        stopAfterCurrent = true
                    }
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
            
            Toggle("Delete file after upload", isOn: $deleteAfterUpload).padding()
            Toggle("Use direct asset upload (stream mode used regardless)", isOn: $useDirectUpload).padding()
            
            Button(action: startBackup) {
                Text(isUploading ? "Uploading..." : "Start Backup")
                    .padding()
                    .background(isUploading ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }.disabled(isUploading)
        }
        .padding()
        .onAppear {
            loadUploadedFiles()
            uploadQueue.maxConcurrentOperationCount = 3
            uploadQueue.qualityOfService = .userInitiated
        }
    }
    
    // MARK: - Backup Methods
    
    func startBackup() {
        stopAfterCurrent = false
        totalUploaded = 0
        totalPhotoCount = 0
        uploadItems = []
        albumUploadProgress = [:]
        
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            // accept multiple allowed authorized states
            let allowed: [PHAuthorizationStatus] = [.authorized, .limited]
            guard allowed.contains(status) else {
                DispatchQueue.main.async { statusMessage = "Full access required (or grant limited/read-write)" }
                return
            }
            DispatchQueue.main.async {
                isUploading = true
                statusMessage = "Enumerating albums..."
                UIApplication.shared.isIdleTimerDisabled = true
            }
            
            let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            self.processAlbums(albums) {
                self.uploadUnassignedPhotos()
            }
        }
    }
    
    func processAlbums(_ albums: PHFetchResult<PHAssetCollection>, index: Int = 0, completion: @escaping () -> Void = {}) {
        guard index < albums.count else {
            completion()
            return
        }
        if stopAfterCurrent {
            DispatchQueue.main.async {
                isUploading = false
                statusMessage = "Stopped"
                stopAfterCurrent = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
            return
        }
        let album = albums.object(at: index)
        let albumName = album.localizedTitle ?? "UnknownAlbum"
        let assetsFetch = PHAsset.fetchAssets(in: album, options: nil)
        var assetsArray: [PHAsset] = []
        for i in 0..<assetsFetch.count { assetsArray.append(assetsFetch.object(at: i)) }
        
        guard !assetsArray.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.processAlbums(albums, index: index + 1, completion: completion)
            }
            return
        }
        
        DispatchQueue.main.async {
            self.currentAlbumName = albumName
            self.totalPhotoCount += assetsArray.count
            self.statusMessage = "Processing \(albumName)"
        }
        
        // Filter assets that have workable resources (done on a serial queue to avoid races)
        let serial = DispatchQueue(label: "com.app.asset-filter")
        var filtered: [PHAsset] = []
        let group = DispatchGroup()
        for asset in assetsArray {
            group.enter()
            serial.async {
                // We avoid using requestContentEditingInput which may be nil; instead just see if assetResources are non-empty
                let resources = PHAssetResource.assetResources(for: asset)
                if !resources.isEmpty {
                    filtered.append(asset)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !filtered.isEmpty else {
                self.processAlbums(albums, index: index + 1, completion: completion)
                return
            }
            self.processAssetsIncremental(filtered, albumName: albumName) {
                if self.deleteAfterUpload {
                    self.deleteAlbum(album)
                }
                self.processAlbums(albums, index: index + 1, completion: completion)
            }
        }
    }
    
    func deleteAlbum(_ album: PHAssetCollection) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSFastEnumeration)
        }) { success, error in
            if success { print("Deleted album: \(album.localizedTitle ?? "Unknown")") }
            else { print("Failed to delete album: \(error?.localizedDescription ?? "unknown error")") }
        }
    }
    
    func processAssetsIncremental(_ assets: [PHAsset], albumName: String, batchSize: Int = 50, completion: @escaping () -> Void) {
        // Iterate by batches to respect stopAfterCurrent and not flood queue
        var cursor = 0
        func processNextBatch() {
            if stopAfterCurrent {
                DispatchQueue.main.async {
                    self.isUploading = false
                    self.statusMessage = "Stopped"
                    self.stopAfterCurrent = false
                    UIApplication.shared.isIdleTimerDisabled = false
                }
                completion()
                return
            }
            guard cursor < assets.count else {
                completion()
                return
            }
            let end = min(cursor + batchSize, assets.count)
            let batch = Array(assets[cursor..<end])
            cursor = end
            
            // Enqueue an operation per asset, but don't enqueue already uploaded assets
            let group = DispatchGroup()
            for asset in batch {
                let assetKey = "\(albumName)/\(asset.localIdentifier)"
                
                if uploadedFiles.contains(assetKey) {
                    DispatchQueue.main.async {
                        self.totalUploaded += 1
                    }
                    continue
                }
                
                group.enter()
                // Add UI item
                DispatchQueue.main.async {
                    let item = UploadItem(identifier: assetKey, albumName: albumName, fileName: asset.localIdentifier)
                    self.uploadItems.insert(item, at: 0)
                }
                
                let op = UploadOperation(asset: asset,
                                         albumName: albumName,
                                         serverURL: serverURL,
                                         username: username,
                                         password: password,
                                         deleteAfterUpload: deleteAfterUpload,
                                         maxRetries: 2)
                
                op.progressHandler = { p in
                    DispatchQueue.main.async {
                        if let idx = self.uploadItems.firstIndex(where: { $0.identifier == assetKey }) {
                            self.uploadItems[idx].progress = p
                        }
                    }
                }
                
                op.completionHandler = { success in
                    DispatchQueue.main.async {
                        if let idx = self.uploadItems.firstIndex(where: { $0.identifier == assetKey }) {
                            if success {
                                self.uploadItems[idx].isCompleted = true
                                self.uploadedFiles.insert(assetKey)
                                self.saveUploadedFiles()
                            } else {
                                self.uploadItems[idx].isFailed = true
                            }
                        } else {
                            // if UI item missing, still account
                        }
                        self.totalUploaded += 1
                        group.leave()
                    }
                }
                
                // If user asked to stop after current batch, we still allow current batch to finish but we won't start next batch
                uploadQueue.addOperation(op)
            }
            
            // When current batch completes, continue if not stopped
            DispatchQueue.global().async {
                group.wait()
                DispatchQueue.main.async {
                    processNextBatch()
                }
            }
        }
        processNextBatch()
    }
    
    func uploadUnassignedPhotos() {
        let allAssets = PHAsset.fetchAssets(with: nil)
        var assetsInAlbums = Set<String>()
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { album, _, _ in
            let albumAssets = PHAsset.fetchAssets(in: album, options: nil)
            albumAssets.enumerateObjects { asset, _, _ in
                assetsInAlbums.insert(asset.localIdentifier)
            }
        }
        var unassignedAssets: [PHAsset] = []
        allAssets.enumerateObjects { asset, _, _ in
            if !assetsInAlbums.contains(asset.localIdentifier) {
                unassignedAssets.append(asset)
            }
        }
        guard !unassignedAssets.isEmpty else {
            DispatchQueue.main.async {
                self.isUploading = false
                self.statusMessage = "Backup completed"
                UIApplication.shared.isIdleTimerDisabled = false
            }
            return
        }
        DispatchQueue.main.async {
            self.currentAlbumName = "Unsorted"
            self.totalPhotoCount += unassignedAssets.count
            self.statusMessage = "Uploading unassigned photos"
        }
        self.processAssetsIncremental(unassignedAssets, albumName: "Unsorted") {
            DispatchQueue.main.async {
                self.isUploading = false
                self.statusMessage = "Backup completed"
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
    
    // MARK: - Helpers
    
    func deleteAsset(asset: PHAsset) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([asset] as NSFastEnumeration)
        }) { success, error in
            if success { print("Deleted asset: \(asset.localIdentifier)") }
            else { print("Failed to delete: \(error?.localizedDescription ?? "unknown error")") }
        }
    }
    
    func saveUploadedFiles() {
        UserDefaults.standard.set(Array(uploadedFiles), forKey: uploadedFilesKey)
    }
    func loadUploadedFiles() {
        if let saved = UserDefaults.standard.array(forKey: uploadedFilesKey) as? [String] {
            uploadedFiles = Set(saved)
        }
    }
}
