cat > scraper.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const { URL } = require('url');
const PRIMARY_SOURCE_URL = process.env.NEFUSOFT_URL;
const COVER_SOURCE_URL = process.env.NEFUSOFT_COVER;

const fetchHTML = async (url) => {
    try {
        const { data, request } = await axios.get(url, { headers: { 'User-Agent': 'Mozilla/5.0' } });
        return { data, finalUrl: request.res.responseUrl || url };
    } catch (error) {
        return null;
    }
};

const getAnisearchCover = async (primaryTitle, alternativeTitle) => {
    const trySearch = async (title) => {
        if (!title) return null;
        try {
            const searchUrl = `${COVER_SOURCE_URL}/search?q=${encodeURIComponent(title)}`;
            const searchResult = await fetchHTML(searchUrl);
            if (!searchResult || !searchResult.data) return null;
            const $s = cheerio.load(searchResult.data);
            const detailPath = $s('section h2.headerA:contains("Anime")').first().next('ul.covers').find('li a.anime-item').first().attr('href');
            if (!detailPath) return null;
            const detailUrl = new URL(detailPath, COVER_SOURCE_URL).toString();
            const detailResult = await fetchHTML(detailUrl);
            if (!detailResult || !detailResult.data) return null;
            const $d = cheerio.load(detailResult.data);
            const coverImg = $d('#details-cover');
            return coverImg.attr('data-src') || coverImg.attr('src') || null;
        } catch (e) {
            return null;
        }
    };
    const altTitleFirstPart = (alternativeTitle || "").split(/[,.]/)[0].trim();
    let coverUrl = await trySearch(altTitleFirstPart);
    if (!coverUrl) {
        coverUrl = await trySearch(primaryTitle);
    }
    return coverUrl;
};

const scrapeListPage = async (url) => {
    const result = await fetchHTML(url);
    if (!result) return { anime: [], totalPages: 1 };
    const { data } = result;
    const $ = cheerio.load(data);
    const anime = [];
    $('.post-article article, .archive-a article').each((i, el) => {
        const img = $(el).find('.thumbnail img');
        anime.push({
            title: $(el).find('h2 a').text().trim(),
            detailUrl: $(el).find('h2 a').attr('href'),
            thumbnail: img.attr('data-src') || img.attr('src'),
        });
    });
    return anime;
};

const scrapeOngoing = async () => {
    const html = await fetchHTML(`${PRIMARY_SOURCE_URL}/anime-terbaru-sub-indo/`);
    if (!html) return {};
    const $ = cheerio.load(html.data);
    const ongoingData = {};
    $('.rilis_ongoing .wrapper-3, .schedule-widget .post-3').each((i, dayElement) => {
        const day = $(dayElement).find('h3.title').text().trim();
        let animeList = [];
        $(dayElement).find('article').each((j, el) => {
            const img = $(el).find('.thumbnail img');
            animeList.push({
                title: $(el).find('h3 a').text().trim(),
                detailUrl: $(el).find('h3 a').attr('href'),
                latestEpisode: $(el).find('.eps_ongo').text().trim(),
                thumbnail: img.attr('data-src') || img.attr('src'),
            });
        });
        if (day && animeList.length > 0) {
            ongoingData[day.toLowerCase().replace("'",'')] = animeList;
        }
    });
    return ongoingData;
};

const scrapeDetail = async (url, options = {}) => {
    const { fetchStreams = true } = options;
    const result = await fetchHTML(url);
    if (!result) return null;
    const { data, finalUrl } = result;
    const $ = cheerio.load(data);
    const detail = {};
    detail.url = finalUrl;
    const info = {};
    $('.info2 table tr').each((i, el) => {
        const key = $(el).find('td.tablex').text().split(':')[0].trim().toLowerCase().replace(/[\s/]+/g, '_');
        const value = $(el).find('td:not(.tablex)').text().trim() || $(el).find('td:not(.tablex) a').text().trim();
        if (key && value) info[key] = value;
    });
    detail.information = info;
    detail.title = info.judul || $('h1.title').text().trim().replace(/ Sub Indo : Episode.*$/, '');
    detail.synopsis = $('#Sinopsis p').map((i, el) => $(el).text().trim()).get().join('\n\n');
    const releaseInfo = {};
    $('.single .info ul li').each((i, el) => {
        const icon = $(el).find('i').attr('class');
        if (icon && icon.includes('fa-calendar-alt')) releaseInfo.date = $(el).text().trim();
        if (icon && icon.includes('fa-clock')) releaseInfo.time = $(el).text().trim();
    });
    detail.releaseInfo = releaseInfo;

    const episodePromises = $('.download_box .download > h4').map(async (i, el) => {
        const episodeTitle = $(el).text().trim().replace(' Sub Indo', '');
        const escapedTitle = episodeTitle.replace(/"/g, '\\"');
        const episodeNumMatch = episodeTitle.match(/Episode\s*(\d+(\.\d+)?)/i);
        const episodeNum = episodeNumMatch ? parseFloat(episodeNumMatch[1]) : i + 1;
        let streams = [];
        const streamDataBase64 = $(`.streaming_eps_box .list_eps_stream li[title*="${escapedTitle}"]`).attr('data');
        if (streamDataBase64 && fetchStreams) {
            try {
                const decoded = Buffer.from(streamDataBase64, 'base64').toString('utf-8');
                const resolutionLinks = JSON.parse(decoded);
                streams = await Promise.all(resolutionLinks.map(async (resLink) => {
                    const streamingPageUrl = resLink.url[0];
                    if (!streamingPageUrl) return null;
                    const streamingPageResult = await fetchHTML(streamingPageUrl);
                    if (!streamingPageResult) return null;
                    const $streamPage = cheerio.load(streamingPageResult.data);
                    const providers = $streamPage('.daftar_server ul li').map((idx, liEl) => {
                        const providerName = $streamPage(liEl).text().trim();
                        const videoUrl = $streamPage(liEl).attr('data-url');
                        return videoUrl ? { provider: providerName, url: videoUrl } : null;
                    }).get().filter(Boolean);
                    return { resolution: resLink.format, providers };
                }));
            } catch (e) { streams = []; }
        }
        return { episodeNum, episodeTitle, streams: streams.filter(s => s && s.providers.length > 0) };
    }).get();
    
    detail.episodes = (await Promise.all(episodePromises)).sort((a,b) => a.episodeNum - b.episodeNum);
    
    const anisearchCover = await getAnisearchCover(info.judul, info.judul_alternatif);
    const primaryPosterImg = $('.coverthumbnail img');
    const primaryPoster = primaryPosterImg.attr('data-src') || primaryPosterImg.attr('src') || '';
    const primaryBannerImg = $('.thumbnail-a img');
    const primaryBanner = primaryBannerImg.attr('data-src') || primaryBannerImg.attr('src') || '';

    detail.thumbnail = anisearchCover || primaryPoster || '';
    detail.bannerImageForHome = anisearchCover || primaryBanner || primaryPoster || '';
    detail.bannerImageForDetail = primaryBanner || anisearchCover || primaryPoster || '';
    
    return detail;
};

module.exports = { scrapeOngoing, scrapeListPage, scrapeDetail, getAnisearchCover };
EOF

cat > server.js << 'EOF'
const express = require('express');
const path = require('path');
const cors = require('cors');
const { scrapeOngoing, scrapeListPage, scrapeDetail, getAnisearchCover } = require('./scraper');

const app = express();
const PORT = process.env.PORT || 3000;

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));
app.use((req, res, next) => {
    if (req.path.endsWith('/') && req.path.length > 1) {
        res.redirect(301, req.path.slice(0, -1) + (req.url.slice(req.path.length) || ''));
    } else {
        next();
    }
});

const cache = new Map();
const urlMap = new Map();
const CACHE_TTL = 15 * 60 * 1000;

const getFromCacheOrScrape = async (key, scrapeFunction, ...args) => {
    if (cache.has(key) && Date.now() - cache.get(key).timestamp < CACHE_TTL) {
        return cache.get(key).data;
    }
    const data = await scrapeFunction(...args);
    if (data && (typeof data !== 'object' || Object.keys(data).length > 0)) {
        cache.set(key, { timestamp: Date.now(), data });
    }
    return data;
};

const slugify = (text) => text.toString().toLowerCase().replace(/\s+/g, '-').replace(/[^\w\-]+/g, '').replace(/\-\-+/g, '-').replace(/^-+/, '').replace(/-+$/, '');

app.get('/', (req, res) => res.render('welcome'));
app.get('/anime', (req, res) => res.render('anime'));

app.get('/api/home-data', async (req, res) => {
    try {
        const ongoingRaw = await getFromCacheOrScrape('ongoing', scrapeOngoing);
        const allOngoingAnimes = Object.values(ongoingRaw).flat();
        
        const processedOngoing = await Promise.all(allOngoingAnimes.map(async (anime) => {
            const slug = slugify(anime.title);
            if (!urlMap.has(slug)) urlMap.set(slug, { url: anime.detailUrl, timestamp: Date.now() });
            const coverUrl = await getFromCacheOrScrape(`cover:${slug}`, getAnisearchCover, anime.title, anime.alternativeTitle);
            return { ...anime, slug, thumbnail: coverUrl };
        }));

        const bannerAnimes = processedOngoing.slice(0, 7);
        const bannerDetails = (await Promise.all(
            bannerAnimes.map(anime => getFromCacheOrScrape(`detail:${anime.slug}`, scrapeDetail, anime.detailUrl, { fetchStreams: false }))
        )).filter(Boolean).map(detail => {
            const slug = slugify(detail.information.judul || detail.title);
            return { ...detail, slug };
        });

        res.json({ bannerData: bannerDetails, ongoingData: processedOngoing });
    } catch (e) {
        res.status(500).json({ error: "Gagal memuat data." });
    }
});

app.get('/detail/:slug', async (req, res) => {
    const { slug } = req.params;
    let mapEntry = urlMap.get(slug);

    if (!mapEntry) {
        try {
            const searchTitle = slug.replace(/-/g, ' ');
            const searchResult = await scrapeListPage(`https://nimegami.id/?s=${encodeURIComponent(searchTitle)}&post_type=post`);
            const foundAnime = searchResult.find(item => slugify(item.title) === slug);
            if (foundAnime) {
                mapEntry = { url: foundAnime.detailUrl };
                urlMap.set(slug, { url: foundAnime.detailUrl, timestamp: Date.now() });
            } else {
                return res.status(404).render('error', { message: '404 - Halaman Tidak Ditemukan' });
            }
        } catch (error) {
            return res.status(500).render('error', { message: '500 - Terjadi Kesalahan Internal' });
        }
    }

    try {
        const data = await getFromCacheOrScrape(`detail:${slug}`, scrapeDetail, mapEntry.url, { fetchStreams: false });
        if (!data) return res.status(404).render('error', { message: '404 - Halaman Tidak Ditemukan' });
        if (data.episodes) data.episodes.reverse();
        res.render('detail', { data, slug });
    } catch (error) {
        res.status(500).render('error', { message: '500 - Terjadi Kesalahan Internal' });
    }
});

app.get('/stream/:slug/episode-:epNum', async (req, res, next) => {
    const { slug, epNum } = req.params;
    const mapEntry = urlMap.get(slug);
    if (!mapEntry) {
        return res.status(404).render('error', { message: '404 - Halaman Anime Tidak Ditemukan, Silakan kembali' });
    }
    try {
        const data = await getFromCacheOrScrape(`detail-full:${slug}`, scrapeDetail, mapEntry.url, { fetchStreams: true });
        if (!data || !data.episodes) return res.status(404).render('error', { message: '404 - Daftar episode tidak ditemukan.' });

        const currentEpisode = data.episodes.find(ep => ep.episodeNum == epNum);
        if (!currentEpisode) return res.status(404).render('error', { message: `404 - Episode ${epNum} tidak ditemukan.` });

        res.render('stream', { data, slug, currentEpisode });
    } catch (error) {
        return next(error);
    }
});

app.get('/api/search', async (req, res) => {
    const { q } = req.query;
    if (!q) return res.status(400).json({ error: 'Query "q" dibutuhkan.' });
    try {
        const url = `https://nimegami.id/?s=${encodeURIComponent(q)}&post_type=post`;
        const data = await scrapeListPage(url);
        const resultsWithCovers = await Promise.all(data.map(async (anime) => {
            const slug = slugify(anime.title);
            if (!urlMap.has(slug)) urlMap.set(slug, { url: anime.detailUrl, timestamp: Date.now() });
            const coverUrl = await getFromCacheOrScrape(`cover:${slug}`, getAnisearchCover, anime.title);
            return { ...anime, slug, thumbnail: coverUrl };
        }));
        res.json(resultsWithCovers);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

app.use((req, res, next) => {
    res.status(404).render('error', { message: '404 - Halaman Tidak Ditemukan' });
});

app.use((err, req, res, next) => {
    console.error(err.stack);
    res.status(500).render('error', { message: '500 - Terjadi Kesalahan Internal' });
});

app.listen(PORT, () => console.log(`🚀 Server berjalan di http://localhost:${PORT}`));
EOF

cat > public/js/main.js << 'EOF'
document.addEventListener('DOMContentLoaded', () => {
    const searchInput = document.getElementById('search-input');
    const searchResults = document.getElementById('search-results');
    const contextMenu = document.getElementById('custom-context-menu');
    let bannerInterval;

    const buildBanner = (bannerData) => {
        const imageWrapper = document.getElementById('banner-image-wrapper');
        const contentWrapper = document.getElementById('banner-content-wrapper');
        const indicatorsWrapper = document.getElementById('banner-indicators');
        
        contentWrapper.innerHTML = bannerData.map(banner => {
            const firstEpisode = banner.episodes && banner.episodes.length > 0 ? banner.episodes[0].episodeNum : 1;
            const genres = (banner.information.kategori || "").split(",").map(g => `<span class="genre">${g.trim()}</span>`).join("");
            return `<div class="banner-content"><h1 class="anime-title">${banner.information.judul || banner.title}</h1><div class="anime-details-banner"><span>${banner.information.studio?.replace(/,/g, '') || 'N/A'}</span> • <span>${banner.information.type || 'N/A'}</span> • <span>${banner.information.musim_rilis || 'N/A'}</span></div><div class="anime-genres">${genres}</div><div class="banner-buttons"><a href="/stream/${banner.slug}/episode-${firstEpisode}" class="banner-button watch"><span class="material-icons">play_arrow</span> Watch Now</a><a href="/detail/${banner.slug}" class="banner-button detail"><span class="material-icons">info</span> Detail</a></div></div>`;
        }).join('');
        
        imageWrapper.innerHTML = bannerData.map(banner => `<div class="banner-image-slide" style="background-image: url('${banner.bannerImageForHome}')"></div>`).join('');
        indicatorsWrapper.innerHTML = bannerData.map(() => '<span></span>').join('');

        contentWrapper.classList.remove('placeholder');

        const imageSlides = imageWrapper.querySelectorAll('.banner-image-slide');
        const contentSlides = contentWrapper.querySelectorAll('.banner-content');
        const indicators = indicatorsWrapper.querySelectorAll('span');
        let currentBannerIndex = 0;
        
        if (imageSlides.length > 0) {
            imageSlides[currentBannerIndex].classList.add('active');
            contentSlides[currentBannerIndex].classList.add('active');
            if (indicators.length) indicators[currentBannerIndex].classList.add('active');
            const updateBanner = () => {
                imageSlides[currentBannerIndex].classList.remove('active');
                contentSlides[currentBannerIndex].classList.remove('active');
                if (indicators.length) indicators[currentBannerIndex].classList.remove('active');
                currentBannerIndex = (currentBannerIndex + 1) % imageSlides.length;
                imageSlides[currentBannerIndex].classList.add('active');
                contentSlides[currentBannerIndex].classList.add('active');
                if (indicators.length) indicators[currentBannerIndex].classList.add('active');
            };
            clearInterval(bannerInterval);
            if (imageSlides.length > 1) bannerInterval = setInterval(updateBanner, 5000);
        }
    };

    const buildOngoing = (ongoingData) => {
        const ongoingGrid = document.getElementById('ongoing-grid');
        if (ongoingData.length > 0) {
            ongoingGrid.innerHTML = ongoingData.map(anime => `<a href="/detail/${anime.slug}" class="anime-card reveal"><div class="img-wrapper placeholder"><img src="${anime.thumbnail || ''}" alt="${anime.title}" class="card-img" loading="lazy"></div><div class="card-content"><p class="card-title">${anime.title}</p><span class="card-episodes">${anime.latestEpisode || 'N/A'}</span></div></a>`).join('');
            document.querySelectorAll('.anime-card .card-img').forEach(img => {
                if (img.complete && img.naturalHeight !== 0) {
                    img.parentElement.classList.remove('placeholder');
                } else {
                    img.onload = () => img.parentElement.classList.remove('placeholder');
                    img.onerror = () => img.parentElement.classList.remove('placeholder');
                }
            });
        } else {
            ongoingGrid.innerHTML = '<p>Tidak ada anime ongoing.</p>';
        }
    };
    
    const loadHomePageData = async () => {
        const cachedData = sessionStorage.getItem('homeData');
        if (cachedData) {
            const data = JSON.parse(cachedData);
            buildBanner(data.bannerData);
            buildOngoing(data.ongoingData);
            return;
        }
        try {
            const response = await fetch('/api/home-data');
            const data = await response.json();
            sessionStorage.setItem('homeData', JSON.stringify(data));
            buildBanner(data.bannerData);
            buildOngoing(data.ongoingData);
        } catch (error) {
            console.error('Gagal memuat data:', error);
        }
    };
    
    if (document.body.classList.contains('anime-page')) loadHomePageData();

    let searchTimeout;
    const handleSearch = async () => {
        const query = searchInput.value.trim();
        if (query.length < 3) { searchResults.style.display = 'none'; return; }
        searchResults.style.display = 'block';
        searchResults.classList.remove('visible');
        searchResults.innerHTML = '<div class="search-result-item"><p>Mencari...</p></div>';
        try {
            const response = await fetch(`/api/search?q=${encodeURIComponent(query)}`);
            const data = await response.json();
            searchResults.innerHTML = data.length > 0 ? data.map(anime => `<a href="/detail/${anime.slug}" class="search-result-item"><img src="${anime.thumbnail}" loading="lazy"><div><p>${anime.title}</p></div></a>`).join('') : '<div class="search-result-item"><p>Tidak ada hasil.</p></div>';
            setTimeout(() => searchResults.classList.add('visible'), 10);
        } catch (error) { searchResults.innerHTML = '<div class="search-result-item"><p>Error pencarian.</p></div>'; }
    };
    
    searchInput.addEventListener('input', () => { clearTimeout(searchTimeout); searchTimeout = setTimeout(handleSearch, 400); });
    document.addEventListener('contextmenu', (e) => { e.preventDefault(); contextMenu.style.top = `${e.pageY}px`; contextMenu.style.left = `${e.pageX}px`; contextMenu.style.display = 'block'; });
    document.addEventListener('click', (e) => {
        if (contextMenu) contextMenu.style.display = 'none';
        if (searchResults && !e.target.closest('.search-container')) searchResults.style.display = 'none';
    });
});
EOF

cat > public/js/stream.js << 'EOF'
document.addEventListener('DOMContentLoaded', () => {
    if (!currentEpisodeData) return;

    const playerContainer = document.querySelector('.plyr-container');
    const video = document.getElementById('video-player');
    const loadingOverlay = document.querySelector('.plyr-loading-overlay');
    const playPauseBtn = document.querySelector('[data-plyr="play"]');
    const rewindBtn = document.querySelector('[data-plyr="rewind"]');
    const forwardBtn = document.querySelector('[data-plyr="forward"]');
    const progress = document.querySelector('.plyr-progress');
    const currentTimeEl = document.querySelector('.plyr-current-time');
    const durationEl = document.querySelector('.plyr-duration');
    const settingsBtn = document.querySelector('[data-plyr="settings"]');
    const settingsMenu = document.querySelector('.plyr-menu-options');
    const fullscreenBtn = document.querySelector('[data-plyr="fullscreen"]');
    const serverButtonsContainer = document.getElementById('server-buttons');

    let controlsTimeout;
    let currentResolution = '';
    let currentProviderIndex = 0;

    const formatTime = (time) => new Date(time * 1000).toISOString().substr(14, 5);

    const showControls = () => {
        playerContainer.classList.add('controls-visible');
        clearTimeout(controlsTimeout);
        if (!video.paused) {
            controlsTimeout = setTimeout(() => playerContainer.classList.remove('controls-visible'), 3000);
        }
    };
    
    const toggleControls = (e) => {
        if (e.target !== playerContainer && e.target !== video) return;
        if (playerContainer.classList.contains('controls-visible')) {
            clearTimeout(controlsTimeout);
            playerContainer.classList.remove('controls-visible');
        } else {
            showControls();
        }
    };
    
    const updateProgress = () => {
        const value = (video.currentTime / video.duration) * 100 || 0;
        progress.value = value;
        progress.style.background = `linear-gradient(to right, var(--primary-color) ${value}%, rgba(255, 255, 255, 0.3) ${value}%)`;
        currentTimeEl.textContent = formatTime(video.currentTime);
    };

    const loadStream = (resolution, providerIndex = 0) => {
        const resData = currentEpisodeData.streams.find(s => s.resolution === resolution);
        if (!resData || !resData.providers[providerIndex]) return;

        const wasPaused = video.paused;
        const currentTime = video.currentTime;
        video.src = resData.providers[providerIndex].url;
        
        video.onloadedmetadata = () => {
            if (currentTime > 0) video.currentTime = currentTime;
            if (!wasPaused) video.play();
        };

        currentResolution = resolution;
        currentProviderIndex = providerIndex;
        updateServerButtonsUI();
    };

    const updateServerButtonsUI = () => {
        document.querySelectorAll('#server-buttons .server-button').forEach(btn => {
            btn.classList.toggle('active', parseInt(btn.dataset.providerIndex) === currentProviderIndex);
        });
    };
    
    const populateServerButtons = (resolution) => {
        const resData = currentEpisodeData.streams.find(s => s.resolution === resolution);
        serverButtonsContainer.innerHTML = '';
        if (resData) {
            resData.providers.forEach((provider, index) => {
                const btn = document.createElement('button');
                btn.className = 'server-button';
                btn.textContent = provider.provider;
                btn.dataset.providerIndex = index;
                btn.onclick = () => loadStream(resolution, index);
                serverButtonsContainer.appendChild(btn);
            });
        }
    };

    const populateSettingsMenu = () => {
        settingsMenu.innerHTML = '';
        const resolutions = currentEpisodeData.streams.map(s => s.resolution);
        const speeds = ['0.5', '1', '1.5', '2'];

        const resTitle = document.createElement('div');
        resTitle.className = 'plyr-menu-title';
        resTitle.textContent = 'Resolution';
        settingsMenu.appendChild(resTitle);
        resolutions.forEach(res => {
            const btn = document.createElement('button');
            btn.textContent = res;
            btn.onclick = () => {
                document.querySelectorAll('.plyr-menu-options button[data-resolution]').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                populateServerButtons(res);
                loadStream(res, 0);
                settingsMenu.style.display = 'none';
                settingsBtn.classList.remove('active');
            };
            btn.dataset.resolution = res;
            if (res === currentResolution) btn.classList.add('active');
            settingsMenu.appendChild(btn);
        });
        
        const speedTitle = document.createElement('div');
        speedTitle.className = 'plyr-menu-title';
        speedTitle.textContent = 'Speed';
        settingsMenu.appendChild(speedTitle);
        speeds.forEach(speed => {
            const btn = document.createElement('button');
            btn.textContent = `${speed}x`;
            btn.onclick = () => {
                video.playbackRate = parseFloat(speed);
                document.querySelectorAll('.plyr-menu-options button[data-speed]').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                settingsMenu.style.display = 'none';
                settingsBtn.classList.remove('active');
            };
            btn.dataset.speed = speed;
            if (parseFloat(speed) === 1) btn.classList.add('active');
            settingsMenu.appendChild(btn);
        });
    };

    if (currentEpisodeData.streams && currentEpisodeData.streams.length > 0) {
        currentResolution = currentEpisodeData.streams[0].resolution;
        populateServerButtons(currentResolution);
        populateSettingsMenu();
        loadStream(currentResolution, 0);
    } else {
        document.querySelector('.stream-info').innerHTML = '<p style="text-align:center;">Maaf, tidak ada sumber streaming yang tersedia untuk episode ini.</p>';
        loadingOverlay.style.display = 'none';
    }

    playerContainer.addEventListener('click', toggleControls);
    playerContainer.addEventListener('mousemove', showControls);
    video.addEventListener('play', () => playPauseBtn.classList.add('is-playing'));
    video.addEventListener('pause', () => playPauseBtn.classList.remove('is-playing'));
    video.addEventListener('timeupdate', updateProgress);
    video.addEventListener('loadedmetadata', () => durationEl.textContent = formatTime(video.duration));
    video.addEventListener('waiting', () => loadingOverlay.style.display = 'flex');
    video.addEventListener('canplay', () => loadingOverlay.style.display = 'none');
    video.addEventListener('playing', () => loadingOverlay.style.display = 'none');
    playPauseBtn.addEventListener('click', (e) => { e.stopPropagation(); video.paused ? video.play() : video.pause(); });
    rewindBtn.addEventListener('click', (e) => { e.stopPropagation(); video.currentTime -= 10; });
    forwardBtn.addEventListener('click', (e) => { e.stopPropagation(); video.currentTime += 10; });
    progress.addEventListener('input', () => video.currentTime = (progress.value / 100) * video.duration);
    settingsBtn.addEventListener('click', e => {
        e.stopPropagation();
        settingsBtn.classList.toggle('active');
        settingsMenu.style.display = settingsMenu.style.display === 'block' ? 'none' : 'block';
    });
    fullscreenBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (!document.fullscreenElement) {
            playerContainer.requestFullscreen().then(() => {
                try { screen.orientation.lock('landscape'); } catch (e) {}
            });
        } else {
            document.exitFullscreen();
        }
    });
    document.addEventListener('click', e => {
        if (settingsMenu && !settingsBtn.contains(e.target)) {
            settingsMenu.style.display = 'none';
            settingsBtn.classList.remove('active');
        }
    });
});
EOF