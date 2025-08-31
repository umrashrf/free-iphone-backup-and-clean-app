import SwiftUI
import Photos

struct ContentView: View {
    @State private var statusMessage = "Idle"
    @State private var isUploading = false
    @State private var uploadedFiles = Set<String>()
    @State private var currentUploadProgress: Double = 0
    @State private var currentFileName: String = ""
    
    @State private var deleteAfterUpload = false
    @State private var stopAfterCurrent = false
    
    let serverURL = URL(string: "http://192.168.4.21:3001/upload")!
    let username = "admin"
    let password = "change_this_password"

    var body: some View {
        VStack(spacing: 20) {
            Text("iPhone → Mac Backup").font(.title)
            Text(statusMessage).foregroundColor(.gray)
            
            if isUploading {
                VStack {
                    Text("Uploading: \(currentFileName)")
                    ProgressView(value: currentUploadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 250)
                    
                    Button("Stop After Current File") {
                        stopAfterCurrent = true
                    }
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
            
            Toggle("Delete file after upload", isOn: $deleteAfterUpload)
                .padding()
            
            Button(action: startBackup) {
                Text(isUploading ? "Uploading..." : "Start Backup")
                    .padding()
                    .background(isUploading ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(isUploading)
            
            if !uploadedFiles.isEmpty {
                List(Array(uploadedFiles), id: \.self) { file in
                    Text(file)
                }
                .frame(height: 200)
            }
        }
        .padding()
        .onAppear {
            loadUploadedFiles()
        }
    }
    
    func startBackup() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized else {
                DispatchQueue.main.async { statusMessage = "Full access required" }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                DispatchQueue.main.async {
                    isUploading = true
                    statusMessage = "Enumerating albums..."
                    // Keep device awake while uploading
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                processAlbums(albums)
            }
        }
    }
    
    func processAlbums(_ albums: PHFetchResult<PHAssetCollection>, index: Int = 0) {
        guard index < albums.count else {
            DispatchQueue.main.async {
                isUploading = false
                statusMessage = "Backup completed"
                currentUploadProgress = 0
                currentFileName = ""
                stopAfterCurrent = false
                // Allow sleep
                UIApplication.shared.isIdleTimerDisabled = false
            }
            return
        }
        if stopAfterCurrent {
            DispatchQueue.main.async {
                isUploading = false
                statusMessage = "Stopped"
                currentUploadProgress = 0
                currentFileName = ""
                stopAfterCurrent = false
                // Allow sleep
                UIApplication.shared.isIdleTimerDisabled = false
            }
            return
        }
        
        let album = albums.object(at: index)
        let albumName = album.localizedTitle ?? "UnknownAlbum"
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        
        var videoAssets: [PHAsset] = []
        var photoAssets: [PHAsset] = []
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            if asset.mediaType == .video { videoAssets.append(asset) }
            else if asset.mediaType == .image { photoAssets.append(asset) }
        }
        let combinedAssets = videoAssets + photoAssets
        
        processAssetsSequentially(combinedAssets, albumName: albumName) {
            self.processAlbums(albums, index: index + 1)
        }
    }
    
    func processAssetsSequentially(_ assets: [PHAsset], albumName: String, completion: @escaping () -> Void, index: Int = 0) {
        guard index < assets.count else { completion(); return }
        let asset = assets[index]
        let identifier = "\(albumName)/\(asset.localIdentifier)"

        if uploadedFiles.contains(identifier) {
            processAssetsSequentially(assets, albumName: albumName, completion: completion, index: index + 1)
            return
        }

        DispatchQueue.main.async {
            currentFileName = asset.localIdentifier
            currentUploadProgress = 0
            statusMessage = "Uploading \(asset.localIdentifier)"
        }

        uploadAsset(asset: asset, albumName: albumName) { success in
            if success {
                DispatchQueue.main.async {
                    self.uploadedFiles.insert(identifier)
                    self.saveUploadedFiles()
                    if deleteAfterUpload {
                        deleteAsset(asset: asset)
                    }
                }
            }

            if stopAfterCurrent {
                DispatchQueue.main.async {
                    isUploading = false
                    statusMessage = "Stopped"
                    currentUploadProgress = 0
                    currentFileName = ""
                    stopAfterCurrent = false
                    // Allow sleep
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            } else {
                self.processAssetsSequentially(assets, albumName: albumName, completion: completion, index: index + 1)
            }
        }
    }
    
    func uploadAsset(asset: PHAsset, albumName: String, completion: @escaping (Bool) -> Void) {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        asset.requestContentEditingInput(with: options) { input, _ in
            guard let url = input?.fullSizeImageURL ?? input?.audiovisualAsset?.value(forKey: "URL") as? URL else {
                completion(false)
                return
            }

            var request = URLRequest(url: serverURL)
            request.httpMethod = "POST"
            let loginString = "\(username):\(password)"
            let base64Login = loginString.data(using: .utf8)?.base64EncodedString() ?? ""
            request.setValue("Basic \(base64Login)", forHTTPHeaderField: "Authorization")

            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"album\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(albumName)\r\n".data(using: .utf8)!)

            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"photos\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
            let mimeType = asset.mediaType == .video ? "video/mp4" : "image/jpeg"
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)

            let fileStream = InputStream(url: url)!
            fileStream.open()
            let bufferSize = 1024 * 64
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            var totalBytesRead: Int64 = 0
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 1

            while fileStream.hasBytesAvailable {
                let read = fileStream.read(&buffer, maxLength: bufferSize)
                if read > 0 {
                    body.append(contentsOf: buffer[0..<read])
                    totalBytesRead += Int64(read)
                    DispatchQueue.main.async {
                        self.currentUploadProgress = Double(totalBytesRead) / Double(fileSize)
                    }
                }
            }
            fileStream.close()
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
                if let error = error {
                    print("Upload error: \(error)")
                    completion(false)
                    return
                }
                if let resp = response as? HTTPURLResponse, resp.statusCode == 200 {
                    completion(true)
                } else {
                    completion(false)
                }
            }.resume()
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

    func saveUploadedFiles() {
        UserDefaults.standard.set(Array(uploadedFiles), forKey: "uploadedFiles")
    }

    func loadUploadedFiles() {
        if let saved = UserDefaults.standard.array(forKey: "uploadedFiles") as? [String] {
            uploadedFiles = Set(saved)
        }
    }
}
