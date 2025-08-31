![](video.mov)

## How to run (quick guide)

1. On your Mac, plug and mount your external drive (e.g. appears under /Volumes/MyDrive).
2. Create a folder on that drive: /Volumes/MyDrive/iPhoneBackups.
3. Edit server/.env and set UPLOAD_DIR=/Volumes/MyDrive/iPhoneBackups, set credentials if you want Basic Auth.
4. Start server:

```zsh
cd server
npm install
npm start
```

Server will print Photo backup server listening on port 3001 and upload dir. If you changed PORT, use that.
5. Start client:

```zsh
cd webapp
npm install
npm start
```

Client (Parcel) runs on port 3000 by default; you can also serve static built client files from Express if you prefer a single host.

6. Find your Mac's LAN IP: In Terminal: ipconfig getifaddr en0 (for Wi-Fi), or check System Settings → Network Suppose it is 192.168.1.50.
7. On your iPhone, connect to the same Wi-Fi. Open Safari and go to:
    - http://192.168.1.50:3000 (client) OR
    - If you built the client into static and serve from Express, open http://192.168.1.50:3001.
8. Use the UI to choose photos and tap Upload to Mac. Watch progress. Files will be saved into the folder on the external drive.