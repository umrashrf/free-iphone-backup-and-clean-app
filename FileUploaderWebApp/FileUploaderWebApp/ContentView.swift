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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.processAlbums(albums, index: index + 1) }
            return
        }
        
        // Filter assets with valid URL synchronously
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        var filteredAssets: [PHAsset] = []
        let filterGroup = DispatchGroup()
        
        for asset in assetsArray {
            filterGroup.enter()
            asset.requestContentEditingInput(with: options) { input, _ in
                if input?.fullSizeImageURL != nil || input?.audiovisualAsset != nil {
                    filteredAssets.append(asset)
                }
                filterGroup.leave()
            }
        }
        
        filterGroup.notify(queue: .main) {
            guard !filteredAssets.isEmpty else {
                self.processAlbums(albums, index: index + 1)
                return
            }
            
            self.totalToUpload += filteredAssets.count
            self.processAssetsIncremental(filteredAssets, albumName: albumName) {
                // Delete the album after all assets uploaded if the toggle is enabled
                if self.deleteAfterUpload {
                    self.deleteAlbum(album)
                }
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
    
    func processAssetsIncremental(_ assets: [PHAsset], albumName: String, completion: @escaping () -> Void) {
        let semaphore = DispatchSemaphore(value: 3)
        let group = DispatchGroup()
        
        for asset in assets {
            if stopAfterCurrent { break }
            group.enter()
            
            DispatchQueue.main.async {
                let item = UploadItem(identifier: "\(albumName)/\(asset.localIdentifier)", fileName: asset.localIdentifier)
                self.uploadItems.insert(item, at: 0) // prepend active upload
                
                // Limit visible list to 20 most recent items
                if self.uploadItems.count > 20 {
                    self.uploadItems.removeLast(self.uploadItems.count - 20)
                }
            }
            
            DispatchQueue.global(qos: .userInitiated).async {
                semaphore.wait()
                self.uploadAsset(asset: asset, albumName: albumName) { progress, completed, failed in
                    DispatchQueue.main.async {
                        if let index = self.uploadItems.firstIndex(where: { $0.identifier == "\(albumName)/\(asset.localIdentifier)" }) {
                            self.uploadItems[index].progress = progress
                            if completed {
                                self.uploadItems[index].isCompleted = true
                                self.totalUploaded += 1
                                self.uploadedFiles.insert("\(albumName)/\(asset.localIdentifier)")
                                self.saveUploadedFiles()
                                if self.deleteAfterUpload { self.deleteAsset(asset: asset) }
                            }
                            if failed {
                                self.uploadItems[index].isFailed = true
                                self.totalUploaded += 1
                            }
                        } else if completed || failed {
                            // asset is no longer in visible list but still count towards overall
                            self.totalUploaded += 1
                        }
                    }
                    if completed || failed {
                        semaphore.signal()
                        group.leave()
                    }
                }
            }
        }
        
        group.notify(queue: .main) { completion() }
    }
    
    func uploadAsset(asset: PHAsset, albumName: String, progressHandler: @escaping (Double, Bool, Bool) -> Void) {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        asset.requestContentEditingInput(with: options) { input, _ in
            guard let url = input?.fullSizeImageURL ?? input?.audiovisualAsset?.value(forKey: "URL") as? URL else {
                progressHandler(0, true, true)
                return
            }
            
            var request = URLRequest(url: serverURL)
            request.httpMethod = "POST"
            let loginString = "\(username):\(password)"
            let base64Login = loginString.data(using: .utf8)?.base64EncodedString() ?? ""
            request.setValue("Basic \(base64Login)", forHTTPHeaderField: "Authorization")
            
            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            
            var bodyPrefix = Data()
            bodyPrefix.append("--\(boundary)\r\n".data(using: .utf8)!)
            bodyPrefix.append("Content-Disposition: form-data; name=\"album\"\r\n\r\n".data(using: .utf8)!)
            bodyPrefix.append("\(albumName)\r\n".data(using: .utf8)!)
            bodyPrefix.append("--\(boundary)\r\n".data(using: .utf8)!)
            bodyPrefix.append("Content-Disposition: form-data; name=\"photos\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
            let mimeType = asset.mediaType == .video ? "video/mp4" : "image/jpeg"
            bodyPrefix.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
            
            let bodySuffix = "\r\n--\(boundary)--\r\n".data(using: .utf8)!
            let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: tempFileURL.path, contents: nil, attributes: nil) else {
                progressHandler(0, true, true)
                return
            }
            
            if let outStream = OutputStream(url: tempFileURL, append: false),
               let fileStream = InputStream(url: url) {
                outStream.open()
                fileStream.open()
                
                bodyPrefix.withUnsafeBytes { _ = outStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: bodyPrefix.count) }
                
                let bufferSize = 64 * 1024
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 1
                var totalBytes: Int64 = 0
                
                while fileStream.hasBytesAvailable {
                    let read = fileStream.read(&buffer, maxLength: bufferSize)
                    if read > 0 {
                        _ = outStream.write(buffer, maxLength: read)
                        totalBytes += Int64(read)
                        DispatchQueue.main.async { progressHandler(Double(totalBytes)/Double(fileSize), false, false) }
                    }
                }
                
                bodySuffix.withUnsafeBytes { _ = outStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: bodySuffix.count) }
                
                outStream.close()
                fileStream.close()
            }
            
            let task = URLSession.shared.uploadTask(with: request, fromFile: tempFileURL) { _, response, _ in
                defer { try? FileManager.default.removeItem(at: tempFileURL) }
                if let resp = response as? HTTPURLResponse, resp.statusCode == 200 {
                    progressHandler(1.0, true, false)
                } else {
                    progressHandler(0.0, true, true)
                }
            }
            task.resume()
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
