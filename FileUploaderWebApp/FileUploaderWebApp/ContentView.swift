import SwiftUI
import Photos

struct UploadItem: Identifiable, Hashable {
    let id = UUID()
    let identifier: String
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
    
    @State private var uploadItems: [UploadItem] = [] // only active uploads
    @State private var totalToUpload: Int = 0
    @State private var totalUploaded: Int = 0
    
    @State private var retryCounts: [String: Int] = [:] // key = asset identifier
    @State private var useDirectUpload = true // new toggle
    
    let serverURL = URL(string: "http://192.168.4.21:3001/upload")!
    let username = "admin"
    let password = "change_this_password"
    
    var overallProgress: Double {
        guard totalToUpload > 0 else { return 0 }
        return Double(totalUploaded) / Double(totalToUpload)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("iPhone → Mac Backup").font(.title)
            Text(statusMessage).foregroundColor(.gray)
            
            if isUploading {
                VStack(spacing: 16) {
                    VStack {
                        Text("\(totalUploaded) of \(totalToUpload) files uploaded")
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
                                    Text(item.fileName).lineLimit(1)
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
        totalToUpload = 0
        totalUploaded = 0
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
            processAlbums(albums)
        }
    }
    
    func processAlbums(_ albums: PHFetchResult<PHAssetCollection>, index: Int = 0) {
        guard index < albums.count else {
            DispatchQueue.main.async {
                isUploading = false
                statusMessage = "Backup completed"
                UIApplication.shared.isIdleTimerDisabled = false
            }
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

        if assetsArray.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.processAlbums(albums, index: index + 1)
            }
            return
        }

        // Filter assets with valid URL on background queue
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
                self.processAlbums(albums, index: index + 1)
                return
            }

            self.totalToUpload += filteredAssets.count

            // Process assets in batches
            self.processAssetsIncremental(filteredAssets, albumName: albumName) {
                // After all assets (including retries) finish, delete album if needed
                if self.deleteAfterUpload {
                    self.deleteAlbum(album)
                }
                // Continue with next album
                self.processAlbums(albums, index: index + 1)
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

            let semaphore = DispatchSemaphore(value: 3)
            let group = DispatchGroup()

            for asset in batchAssets {
                if stopAfterCurrent { break }
                group.enter()

                let assetKey = "\(albumName)/\(asset.localIdentifier)"

                // Add to UI only if visible slots available
                DispatchQueue.main.async {
                    if self.uploadItems.count < 20 {
                        let item = UploadItem(identifier: assetKey, fileName: asset.localIdentifier)
                        self.uploadItems.insert(item, at: 0)
                    }
                }

                func startUpload() {
                    DispatchQueue.global(qos: .userInitiated).async {
                        semaphore.wait()
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
                                        group.leave()
                                    } else if failed {
                                        let retries = self.retryCounts[assetKey] ?? 0
                                        if retries == 0 {
                                            self.retryCounts[assetKey] = 1
                                            let delay = Double.random(in: 5...30)
                                            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                                                startUpload() // retry
                                            }
                                        } else {
                                            self.uploadItems[index].isFailed = true
                                            self.totalUploaded += 1
                                            semaphore.signal()
                                            group.leave()
                                        }
                                    }
                                } else if completed || failed {
                                    self.totalUploaded += 1
                                    semaphore.signal()
                                    group.leave()
                                }
                            }
                        }
                    }
                }

                startUpload()
            }

            group.notify(queue: .main) {
                // After this batch finishes, process the next one
                processNextBatch()
            }
        }

        processNextBatch()
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
                let loginString = "\(username):\(password)"
                let base64Login = loginString.data(using: .utf8)?.base64EncodedString() ?? ""
                request.setValue("Basic \(base64Login)", forHTTPHeaderField: "Authorization")
                
                let boundary = "Boundary-\(UUID().uuidString)"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                
                let bodyPrefix = """
                --\(boundary)\r
                Content-Disposition: form-data; name="album"\r\n\r
                \(albumName)\r
                --\(boundary)\r
                Content-Disposition: form-data; name="photos"; filename="\(url.lastPathComponent)"\r
                Content-Type: \(asset.mediaType == .video ? "video/mp4" : "image/jpeg")\r\n\r
                """.data(using: .utf8)!
                
                let bodySuffix = "\r\n--\(boundary)--\r\n".data(using: .utf8)!
                
                if useDirect {
                    // Direct upload via temporary combined file
                    let tempDataURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    var fullData = Data()
                    fullData.append(bodyPrefix)
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
                    // Old temp file method with buffered streaming
                    let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    guard FileManager.default.createFile(atPath: tempFileURL.path, contents: nil, attributes: nil) else {
                        DispatchQueue.main.async { progressHandler(0, true, true) }
                        return
                    }
                    
                    if let outStream = OutputStream(url: tempFileURL, append: false),
                       let fileStream = InputStream(url: url) {
                        outStream.open()
                        fileStream.open()
                        
                        let bufferSize = 1024 * 1024 // 1 MB
                        var buffer = [UInt8](repeating: 0, count: bufferSize)
                        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 1
                        var totalBytes: Int64 = 0
                        var lastProgressUpdate: TimeInterval = 0
                        let throttleInterval: TimeInterval = 0.1
                        
                        bodyPrefix.withUnsafeBytes { _ = outStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: bodyPrefix.count) }
                        
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
                            }
                        }
                        
                        bodySuffix.withUnsafeBytes { _ = outStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: bodySuffix.count) }
                        
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
