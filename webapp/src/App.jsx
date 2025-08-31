import React, { useState, useRef } from 'react';

const SERVER_BASE = 'http://192.168.4.21:3001';
// If you're opening the frontend from the same Mac, set this to the Mac's LAN IP + server port, e.g.
// const SERVER_BASE = 'http://192.168.1.50:3001';
//
// If you serve client separately and want to upload to server on same host, put full URL here.

export default function App() {
    const [files, setFiles] = useState([]);
    const [progress, setProgress] = useState(0);
    const [statusMsg, setStatusMsg] = useState('');
    const fileInputRef = useRef();

    const handleSelect = (e) => {
        const f = Array.from(e.target.files || []);
        setFiles(f);
        setProgress(0);
        setStatusMsg(`${f.length} selected`);
    };

    function uploadFiles() {
        if (!files.length) {
            setStatusMsg('No files selected');
            return;
        }

        const fd = new FormData();
        files.forEach((file) => fd.append('photos', file, file.name));

        setStatusMsg('Uploading...');
        const xhr = new XMLHttpRequest();
        xhr.open('POST', (SERVER_BASE || '') + '/upload');

        // ---- ADD AUTH HEADER ----
        const username = "admin";               // must match BASIC_AUTH_USER
        const password = "change_this_password"; // must match BASIC_AUTH_PASS
        const token = btoa(`${username}:${password}`);
        xhr.setRequestHeader("Authorization", "Basic " + token);
        // -------------------------

        xhr.upload.onprogress = (ev) => {
            if (ev.lengthComputable) {
                const pct = Math.round((ev.loaded / ev.total) * 100);
                setProgress(pct);
            }
        };

        xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
                setStatusMsg('Upload finished');
                setProgress(100);
                try {
                    const res = JSON.parse(xhr.responseText);
                    setStatusMsg(`Uploaded ${res.files ? res.files.length : files.length} files`);
                } catch {
                    setStatusMsg('Upload finished (server response unreadable)');
                }
            } else {
                setStatusMsg(`Upload failed: ${xhr.statusText || xhr.status}`);
            }
        };

        xhr.onerror = () => setStatusMsg('Upload failed (network error)');

        xhr.send(fd);
    }

    return (
        <div style={{ fontFamily: 'system-ui, -apple-system, sans-serif', padding: 16 }}>
            <h2>iPhone → Mac Photo Backup</h2>

            <div style={{ marginBottom: 12 }}>
                <input
                    ref={fileInputRef}
                    type="file"
                    accept="image/*,video/*"
                    multiple
                    onChange={handleSelect}
                    style={{ width: '100%' }}
                />
                <div style={{ fontSize: 13, color: '#555', marginTop: 6 }}>
                    Tip: tap "Photos" in the picker and select multiple images. On iPhone you can tap "Select" then choose many photos.
                </div>
            </div>

            <div style={{ marginBottom: 12 }}>
                <button onClick={uploadFiles} style={{ padding: '8px 12px', fontSize: 16 }}>
                    Upload to Mac
                </button>
                <button
                    onClick={() => {
                        setFiles([]);
                        setProgress(0);
                        setStatusMsg('');
                        if (fileInputRef.current) fileInputRef.current.value = '';
                    }}
                    style={{ marginLeft: 8 }}
                >
                    Clear
                </button>
            </div>

            <div style={{ marginBottom: 12 }}>
                <div style={{ height: 12, background: '#eee', borderRadius: 6 }}>
                    <div
                        style={{
                            width: `${progress}%`,
                            height: '100%',
                            borderRadius: 6,
                            background: 'linear-gradient(90deg, #3b82f6, #06b6d4)'
                        }}
                    />
                </div>
                <div style={{ marginTop: 6 }}>{progress}% — {statusMsg}</div>
            </div>

            <div style={{ marginTop: 18 }}>
                <strong>Selected files</strong>
                <ul>
                    {files.map((f, i) => (
                        <li key={i}>
                            {f.name} — {(f.size / 1024 / 1024).toFixed(2)} MB ({f.type})
                        </li>
                    ))}
                </ul>
            </div>

            <div style={{ marginTop: 18, fontSize: 13, color: '#666' }}>
                <div>Server URL: Enter your Mac server address in the React code (SERVER_BASE). Example: <code>http://192.168.1.50:3001</code></div>
                <div>On iPhone, open Safari and visit that address (same Wi-Fi). Select photos and upload. The server will save files to your external drive.</div>
            </div>
        </div>
    );
}
