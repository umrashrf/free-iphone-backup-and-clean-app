import SwiftUI
import Photos

struct ContentView: View {
    @State private var statusMessage = "Idle"
    @State private var isUploading = false
    @State private var uploadedFiles = Set<String>() // track uploaded files

    // Change this to your server IP + port
    let serverURL = URL(string: "http://192.168.4.21:3001/upload")!
    let username = "admin"
    let password = "change_this_password"

    var body: some View {
        VStack(spacing: 20) {
            Text("iPhone → Mac Backup").font(.title)
            Text(statusMessage).foregroundColor(.gray)
            Button(action: startBackup) {
                Text(isUploading ? "Uploading..." : "Start Backup")
                    .padding()
                    .background(isUploading ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(isUploading)
        }
        .padding()
        .onAppear {
            loadUploadedFiles()
        }
    }

    // MARK: - Backup Start
    func startBackup() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized else {
                DispatchQueue.main.async { statusMessage = "Full access required" }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                DispatchQueue.main.async { isUploading = true; statusMessage = "Enumerating albums..." }
                let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                processAlbums(albums)
            }
        }
    }

    // MARK: - Process albums sequentially
    func processAlbums(_ albums: PHFetchResult<PHAssetCollection>, index: Int = 0) {
        guard index < albums.count else {
            DispatchQueue.main.async { isUploading = false; statusMessage = "Backup completed" }
            return
        }
        let album = albums.object(at: index)
        let albumName = album.localizedTitle ?? "UnknownAlbum"
        let assets = PHAsset.fetchAssets(in: album, options: nil)

        // Videos first
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

    // MARK: - Process assets sequentially in an album
    func processAssetsSequentially(_ assets: [PHAsset], albumName: String, completion: @escaping () -> Void, index: Int = 0) {
        guard index < assets.count else { completion(); return }
        let asset = assets[index]
        let identifier = "\(albumName)/\(asset.localIdentifier)"

        if uploadedFiles.contains(identifier) {
            print("Skipping already uploaded: \(identifier)")
            processAssetsSequentially(assets, albumName: albumName, completion: completion, index: index + 1)
            return
        }

        uploadAsset(asset: asset, albumName: albumName) { success in
            if success {
                self.uploadedFiles.insert(identifier)
                self.saveUploadedFiles()
                deleteAsset(asset: asset)
            }
            self.processAssetsSequentially(assets, albumName: albumName, completion: completion, index: index + 1)
        }
    }

    // MARK: - Upload a single asset
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

            // Multipart header
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"album\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(albumName)\r\n".data(using: .utf8)!)

            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"photos\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
            let mimeType = asset.mediaType == .video ? "video/mp4" : "image/jpeg"
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)

            // Stream file safely
            let fileStream = InputStream(url: url)!
            fileStream.open()
            let bufferSize = 1024 * 64
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while fileStream.hasBytesAvailable {
                let read = fileStream.read(&buffer, maxLength: bufferSize)
                if read > 0 {
                    body.append(contentsOf: buffer[0..<read])
                }
            }
            fileStream.close()

            // Close multipart
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
                if let error = error {
                    print("Upload error: \(error)")
                    completion(false)
                    return
                }
                if let resp = response as? HTTPURLResponse, resp.statusCode == 200 {
                    print("Uploaded \(url.lastPathComponent) from album \(albumName)")
                    completion(true)
                } else {
                    completion(false)
                }
            }.resume()
        }
    }

    // MARK: - Delete asset after upload
    func deleteAsset(asset: PHAsset) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([asset] as NSFastEnumeration)
        }) { success, error in
            if success { print("Deleted asset: \(asset.localIdentifier)") }
            else { print("Failed to delete: \(error?.localizedDescription ?? "unknown error")") }
        }
    }

    // MARK: - Persist uploaded files
    func saveUploadedFiles() {
        UserDefaults.standard.set(Array(uploadedFiles), forKey: "uploadedFiles")
    }

    func loadUploadedFiles() {
        if let saved = UserDefaults.standard.array(forKey: "uploadedFiles") as? [String] {
            uploadedFiles = Set(saved)
        }
    }
}
