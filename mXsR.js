const express = require('express');
const { createCanvas, loadImage, registerFont } = require('canvas');
const path = require('path');

module.exports = function(app) {

// Daftarkan font
try {
    registerFont(path.join(__dirname, 'arial.ttf'), { family: 'Arial' });
} catch (error) {
    console.log("Font arial.ttf tidak ditemukan, menggunakan font default.");
}

app.get('/imgcreator/nulis', async (req, res) => {
    try {
        const text = req.query.text || '';
        const no = req.query.no || '';
        
        // --- PERUBAHAN UTAMA: 'date' tidak lagi diisi otomatis ---
        // Jika parameter 'date' tidak ada, maka variabel 'date' akan menjadi string kosong.
        const date = req.query.date || '';
        
        const lines = text.split('|');
        
        const templatePath = path.join(__dirname, 'buku.png');
        const templateImage = await loadImage(templatePath);

        const canvas = createCanvas(templateImage.width, templateImage.height);
        const context = canvas.getContext('2d');
        context.drawImage(templateImage, 0, 0, templateImage.width, templateImage.height);

        context.fillStyle = 'black';
        context.font = '24px Arial';
        context.textBaseline = 'middle';

        // Tulis Nomor dan Tanggal (sesuai koordinat Anda)
        context.fillText(no, 70, 145);
        context.fillText(date, 670, 150);

        // Tulis setiap baris teks (sesuai koordinat Anda)
        const startX = 90;
        const startY = 188;
        const lineHeight = 37;

        for (let i = 0; i < lines.length; i++) {
            if (i > 21) break;
            const lineText = lines[i].trim();
            const currentY = startY + (i * lineHeight);
            context.fillText(lineText, startX, currentY);
        }

        const buffer = canvas.toBuffer('image/png');
        res.setHeader('Content-Type', 'image/png');
        res.send(buffer);

    } catch (error) {
        console.error("Error pada endpoint /api/nulis:", error);
        if (error.code === 'ENOENT') {
            res.status(500).send("Error: File template 'buku.png' tidak ditemukan di server.");
        } else {
            res.status(500).send("Maaf, terjadi kesalahan di server.");
        }
    }
});
}