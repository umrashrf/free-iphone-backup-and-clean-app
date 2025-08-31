import SwiftUI
import Photos

struct UploadItem: Identifiable, Hashable {
    let id = UUID()
    let identifier: String
    let albumName: String
    let fileName: String
    var progress: Double = 0
    var isCompleted: Bool = false
    var isFailed: Bool = false
}

struct ContentView: View {
    @State private var statusMessage = "Idle"
    @State private var isUploading = false
    @State private var uploadedFiles = Set<String>()
    @State private var deleteAfterUpload = false
    @State private var stopAfterCurrent = false
    @State private var uploadItems: [UploadItem] = []  // all uploads
    @State private var totalUploaded: Int = 0
    @State private var retryCounts: [String: Int] = [:]
    @State private var useDirectUpload = true

    // New UI state
    @State private var currentAlbumName: String = ""
    @State private var totalPhotoCount: Int = 0
    @State private var albumUploadProgress: [String: Int] = [:]

    let serverURL = URL(string: "http://192.168.4.21:3001/upload")!
    let username = "admin"
    let password = "change_this_password"

    var overallProgress: Double {
        guard totalPhotoCount > 0 else { return 0 }
        return Double(totalUploaded) / Double(totalPhotoCount)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("iPhone → Mac Backup").font(.title)

            // Display current album and total photos
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
                        ForEach(uploadItems.prefix(20)) { item in
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
            Toggle("Use direct asset upload", isOn: $useDirectUpload).padding()

            Button(action: startBackup) {
                Text(isUploading ? "Uploading..." : "Start Backup")
                    .padding()
                    .background(isUploading ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }.disabled(isUploading)
        }
        .padding()
        .onAppear { loadUploadedFiles() }
    }

    // MARK: - Backup Methods

    func startBackup() {
        stopAfterCurrent = false
        totalUploaded = 0
        totalPhotoCount = 0
        uploadItems = []
        albumUploadProgress = [:]

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized else {
                DispatchQueue.main.async { statusMessage = "Full access required" }
                return
            }
            DispatchQueue.main.async {
                isUploading = true
                statusMessage = "Enumerating albums..."
                UIApplication.shared.isIdleTimerDisabled = true
            }

            let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)

            // First, process all albums
            self.processAlbums(albums) {
                // After all albums/videos are uploaded, process unassigned photos
                self.uploadUnassignedPhotos()
            }
        }
    }

    func processAlbums(_ albums: PHFetchResult<PHAssetCollection>, index: Int = 0, completion: @escaping () -> Void = {}) {
        guard index < albums.count else {
            completion() // All albums done
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.processAlbums(albums, index: index + 1, completion: completion)
            }
            return
        }

        DispatchQueue.main.async {
            self.currentAlbumName = albumName
            self.totalPhotoCount += assetsArray.count
            self.statusMessage = "Processing \(albumName)"
        }

        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        var filteredAssets: [PHAsset] = []
        let filterGroup = DispatchGroup()

        for asset in assetsArray {
            filterGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                asset.requestContentEditingInput(with: options) { input, _ in
                    if input?.fullSizeImageURL != nil || input?.audiovisualAsset != nil {
                        filteredAssets.append(asset)
                    }
                    filterGroup.leave()
                }
            }
        }

        filterGroup.notify(queue: .main) {
            guard !filteredAssets.isEmpty else {
                self.processAlbums(albums, index: index + 1, completion: completion)
                return
            }

            self.processAssetsIncremental(filteredAssets, albumName: albumName) {
                if self.deleteAfterUpload { self.deleteAlbum(album) }
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
        let totalBatches = Int(ceil(Double(assets.count) / Double(batchSize)))
        var currentBatch = 0

        func processNextBatch() {
            guard currentBatch < totalBatches else {
                completion() // all batches done
                return
            }

            let start = currentBatch * batchSize
            let end = min(start + batchSize, assets.count)
            let batchAssets = Array(assets[start..<end])
            currentBatch += 1

            let uploadQueue = OperationQueue()
            uploadQueue.maxConcurrentOperationCount = 3
            uploadQueue.qualityOfService = .userInitiated

            for asset in batchAssets {
                let assetKey = "\(albumName)/\(asset.localIdentifier)"

                // Add to UI only if visible slots available
                DispatchQueue.main.async {
                    let item = UploadItem(
                        identifier: assetKey,
                        albumName: albumName,
                        fileName: asset.localIdentifier
                    )
                    self.uploadItems.insert(item, at: 0)
                }

                func startUpload() {
                    uploadQueue.addOperation {
                        let semaphore = DispatchSemaphore(value: 0)

                        self.uploadAsset(asset: asset, albumName: albumName, useDirect: self.useDirectUpload) { progress, completed, failed in
                            DispatchQueue.main.async {
                                if let index = self.uploadItems.firstIndex(where: { $0.identifier == assetKey }) {
                                    self.uploadItems[index].progress = progress

                                    if completed {
                                        self.uploadItems[index].isCompleted = true
                                        self.uploadItems[index].isFailed = false
                                        self.totalUploaded += 1
                                        self.uploadedFiles.insert(assetKey)
                                        self.saveUploadedFiles()
                                        if self.deleteAfterUpload { /* delete asset */ }
                                        semaphore.signal()
                                    } else if failed {
                                        let retries = self.retryCounts[assetKey] ?? 0
                                        if retries == 0 {
                                            self.retryCounts[assetKey] = 1
                                            let delay = Double.random(in: 5...30)
                                            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                                                startUpload() // retry without leaving the queue
                                            }
                                        } else {
                                            self.uploadItems[index].isFailed = true
                                            self.totalUploaded += 1
                                            semaphore.signal()
                                        }
                                    }
                                } else if completed || failed {
                                    self.totalUploaded += 1
                                    semaphore.signal()
                                }
                            }
                        }

                        // Wait until upload completes (or retry triggers new Operation)
                        _ = semaphore.wait(timeout: .distantFuture)
                    }
                }

                startUpload()
            }

            // Notify when this batch finishes
            uploadQueue.addBarrierBlock {
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
    
    func uploadAsset(asset: PHAsset, albumName: String, useDirect: Bool = true, progressHandler: @escaping (Double, Bool, Bool) -> Void) {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        
        asset.requestContentEditingInput(with: options) { input, _ in
            guard let url = input?.fullSizeImageURL ?? input?.audiovisualAsset?.value(forKey: "URL") as? URL else {
                progressHandler(0, true, true)
                return
            }
            
            DispatchQueue.global(qos: .userInitiated).async {
                var request = URLRequest(url: serverURL)
                request.httpMethod = "POST"
                
                // Basic Auth
                let loginString = "\(username):\(password)"
                let base64Login = loginString.data(using: .utf8)?.base64EncodedString() ?? ""
                request.setValue("Basic \(base64Login)", forHTTPHeaderField: "Authorization")
                
                // Boundary for multipart
                let boundary = "Boundary-\(UUID().uuidString)"
                let lineBreak = "\r\n"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                
                // Body prefix & suffix
                let bodyPrefix = NSMutableData()
                bodyPrefix.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
                bodyPrefix.append("Content-Disposition: form-data; name=\"album\"\(lineBreak + lineBreak)".data(using: .utf8)!)
                bodyPrefix.append("\(albumName)\(lineBreak)".data(using: .utf8)!)
                bodyPrefix.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
                bodyPrefix.append("Content-Disposition: form-data; name=\"photos\"; filename=\"\(url.lastPathComponent)\"\(lineBreak)".data(using: .utf8)!)
                let contentType = asset.mediaType == .video ? "video/mp4" : "image/jpeg"
                bodyPrefix.append("Content-Type: \(contentType)\(lineBreak + lineBreak)".data(using: .utf8)!)
                
                let bodySuffix = "\r\n--\(boundary)--\(lineBreak)".data(using: .utf8)!
                
                if useDirect {
                    // Direct upload via temporary combined file
                    let tempDataURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    var fullData = Data()
                    fullData.append(bodyPrefix as Data)
                    if let fileData = try? Data(contentsOf: url) { fullData.append(fileData) }
                    fullData.append(bodySuffix)
                    try? fullData.write(to: tempDataURL)
                    
                    let task = URLSession.shared.uploadTask(with: request, fromFile: tempDataURL) { _, response, _ in
                        defer { try? FileManager.default.removeItem(at: tempDataURL) }
                        if let resp = response as? HTTPURLResponse, resp.statusCode == 200 {
                            progressHandler(1.0, true, false)
                        } else {
                            progressHandler(0.0, true, true)
                        }
                    }
                    task.resume()
                    
                } else {
                    // Streamed upload with progress
                    let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    guard FileManager.default.createFile(atPath: tempFileURL.path, contents: nil, attributes: nil) else {
                        DispatchQueue.main.async { progressHandler(0, true, true) }
                        return
                    }
                    
                    if let outStream = OutputStream(url: tempFileURL, append: false),
                       let fileStream = InputStream(url: url) {
                        outStream.open()
                        fileStream.open()
                        
                        // Write body prefix
                        let prefixData = bodyPrefix as Data
                        prefixData.withUnsafeBytes { bytes in
                            _ = outStream.write(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: prefixData.count)
                        }
                        
                        // Stream file data in chunks
                        let bufferSize = 1024 * 1024 // 1 MB
                        var buffer = [UInt8](repeating: 0, count: bufferSize)
                        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 1
                        var totalBytes: Int64 = 0
                        var lastProgressUpdate: TimeInterval = 0
                        let throttleInterval: TimeInterval = 0.1
                        
                        while fileStream.hasBytesAvailable {
                            let read = fileStream.read(&buffer, maxLength: bufferSize)
                            if read > 0 {
                                _ = outStream.write(buffer, maxLength: read)
                                totalBytes += Int64(read)
                                let now = Date().timeIntervalSince1970
                                if now - lastProgressUpdate > throttleInterval {
                                    lastProgressUpdate = now
                                    DispatchQueue.main.async { progressHandler(Double(totalBytes)/Double(fileSize), false, false) }
                                }
                            } else {
                                break
                            }
                        }
                        
                        // Write body suffix
                        bodySuffix.withUnsafeBytes { bytes in
                            _ = outStream.write(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: bodySuffix.count)
                        }
                        
                        outStream.close()
                        fileStream.close()
                        
                        let task = URLSession.shared.uploadTask(with: request, fromFile: tempFileURL) { _, response, _ in
                            defer { try? FileManager.default.removeItem(at: tempFileURL) }
                            if let resp = response as? HTTPURLResponse, resp.statusCode == 200 {
                                DispatchQueue.main.async { progressHandler(1.0, true, false) }
                            } else {
                                DispatchQueue.main.async { progressHandler(0.0, true, true) }
                            }
                        }
                        task.resume()
                    }
                }
            }
        }
    }
    
    func deleteAsset(asset: PHAsset) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([asset] as NSFastEnumeration)
        }) { success, error in
            if success { print("Deleted asset: \(asset.localIdentifier)") }
            else { print("Failed to delete: \(error?.localizedDescription ?? "unknown error")") }
        }
    }
    
    func saveUploadedFiles() { UserDefaults.standard.set(Array(uploadedFiles), forKey: "uploadedFiles") }
    func loadUploadedFiles() {
        if let saved = UserDefaults.standard.array(forKey: "uploadedFiles") as? [String] {
            uploadedFiles = Set(saved)
        }
    }
}
