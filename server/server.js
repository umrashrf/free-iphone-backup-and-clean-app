require('dotenv').config();
const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const cors = require('cors');

const app = express();
const PORT = process.env.PORT || 3001;
const UPLOAD_DIR = process.env.UPLOAD_DIR || path.join(__dirname, 'uploads');
const MAX_FILE_SIZE = parseInt(process.env.MAX_FILE_SIZE || '20000000', 10); // bytes

// Ensure upload dir exists
fs.mkdirSync(UPLOAD_DIR, { recursive: true });

// Basic CORS so your iPhone can talk to the Mac server
app.use(cors());

// Optional Basic Auth middleware
const basicUser = process.env.BASIC_AUTH_USER;
const basicPass = process.env.BASIC_AUTH_PASS;
if (basicUser && basicPass) {
    app.use((req, res, next) => {
        const auth = req.headers['authorization'];
        if (!auth) {
            res.setHeader('WWW-Authenticate', 'Basic realm="Upload Area"');
            return res.status(401).send('Authentication required');
        }
        const base64 = auth.split(' ')[1] || '';
        const [user, pass] = Buffer.from(base64, 'base64').toString().split(':');
        if (user === basicUser && pass === basicPass) return next();
        res.setHeader('WWW-Authenticate', 'Basic realm="Upload Area"');
        res.status(401).send('Authentication required');
    });
}

// Multer storage with sanitized filenames to avoid collisions / path traversal
const storage = multer.diskStorage({
    destination: (req, file, cb) => {
        const album = req.body.album || "UnknownAlbum";
        // sanitize folder name
        const safeAlbum = album.replace(/[<>:"/\\|?*]+/g, '_');
        const albumDir = path.join(UPLOAD_DIR, safeAlbum);
        fs.mkdirSync(albumDir, { recursive: true });
        cb(null, albumDir);
    },
    filename: (req, file, cb) => {
        const safeOriginal = path.basename(file.originalname).replace(/\s+/g, '_').replace(/[^a-zA-Z0-9_\-.]/g, '');
        const timestamp = Date.now();
        cb(null, `${timestamp}_${safeOriginal}`);
    }
});

const upload = multer({
    storage,
    limits: {
        fileSize: MAX_FILE_SIZE,
        files: 200 // max number of files per upload (tweak if needed)
    },
    fileFilter: (req, file, cb) => {
        if (file.mimetype) {
            if (file.mimetype.startsWith('image/') || file.mimetype.startsWith('video/')) {
                cb(null, true);
            } else {
                cb(new Error('Only image and video files are allowed'), false);
            }
        } else {
            cb(new Error('Unknown file type'), false);
        }
    }
});

// Simple status endpoint
app.get('/', (req, res) => {
    res.send({
        status: 'ok',
        uploadDir: UPLOAD_DIR
    });
});

// Upload endpoint: accepts 'photos' as multi-file field
app.post('/upload', upload.array('photos', 500), (req, res) => {
    // multer has saved files
    const saved = (req.files || []).map(f => ({
        originalName: f.originalname,
        savedAs: f.filename,
        size: f.size,
        path: f.path
    }));
    res.json({ success: true, files: saved });
});

// Error handler
app.use((err, req, res, next) => {
    console.error('Server error:', err.message);
    if (err instanceof multer.MulterError) {
        return res.status(400).json({ success: false, error: err.message });
    }
    res.status(500).json({ success: false, error: err.message || 'Internal error' });
});

app.listen(PORT, () => {
    console.log(`Photo backup server listening on port ${PORT}`);
    console.log(`Upload dir: ${UPLOAD_DIR}`);
});
