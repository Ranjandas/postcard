(() => {
  const dropZone = document.getElementById('drop-zone');
  const fileInput = document.getElementById('file-input');
  const globalControls = document.getElementById('global-controls');
  const radiusSlider = document.getElementById('radius-slider');
  const radiusValue = document.getElementById('radius-value');
  const paddingSlider = document.getElementById('padding-slider');
  const paddingValue = document.getElementById('padding-value');
  const globalBlurBtn = document.getElementById('global-blur-btn');
  const ratioButtons = Array.from(document.querySelectorAll('.ratio-btn'));
  const segmentedIndicator = document.querySelector('.segmented-indicator');
  const exportAllBtn = document.getElementById('export-all-btn');
  const revealBtn = document.getElementById('reveal-btn');
  const clipsContainer = document.getElementById('clips');
  const cardTemplate = document.getElementById('clip-card-template');

  const MIN_TRIM_GAP = 0.1;
  const MIN_CROP = 0.05;
  const clips = new Map(); // id -> clip state

  // Custom (prefixed) @font-face family names — see styles.css — so a caption never picks up a
  // system-installed font of the same common name instead of the exact bundled file the server
  // renders with (matched by the same key server-side; see CaptionFonts in CaptionRenderer.swift).
  const CAPTION_FONTS = {
    montserrat: 'PostcardMontserrat',
    playfair: 'PostcardPlayfair',
    pacifico: 'PostcardPacifico',
    caveat: 'PostcardCaveat',
    bebasneue: 'PostcardBebasNeue',
  };

  let currentAspect = readActiveAspectRatio();
  let activePlayingClip = null;
  // Not a forced/override state — just the default background mode assigned to newly uploaded
  // clips, and a bulk "set every current clip to this" action when clicked. Each clip keeps its
  // own independent backgroundMode afterward (see setClipBackgroundBlur/setClipBackgroundColor),
  // so this can drift out of sync with individual clips — that's expected, same as a "select all"
  // checkbox going stale the moment one item is changed by hand.
  let globalBlurDefault = false;

  // Corner radius is sized off the preview *element* (video/img/crop-wrapper — the fitted media
  // rect), while a caption is sized off the *canvas box* itself (`.canvas-preview`), so the same
  // observer branches on which kind of target it's reporting on.
  const resizeObserver = new ResizeObserver(entries => {
    for (const entry of entries) {
      if (entry.target.classList.contains('canvas-preview')) {
        const pill = entry.target.querySelector('.caption-pill');
        if (pill) applyCaptionSizeToPreviewElement(entry.target, pill);
      } else {
        applyRadiusToPreviewElement(entry.target);
      }
    }
  });

  function formatTime(seconds) {
    if (!isFinite(seconds) || seconds < 0) seconds = 0;
    const m = Math.floor(seconds / 60);
    const s = (seconds % 60).toFixed(1).padStart(4, '0');
    return `${m}:${s}`;
  }

  function clamp(v, lo, hi) {
    return Math.min(hi, Math.max(lo, v));
  }

  function currentRadiusPercent() {
    return Number(radiusSlider.value);
  }

  function currentPaddingPercent() {
    return Number(paddingSlider.value);
  }

  function readActiveAspectRatio() {
    const active = ratioButtons.find(btn => btn.classList.contains('active')) || ratioButtons[0];
    return { w: parseFloat(active.dataset.w), h: parseFloat(active.dataset.h) };
  }

  function moveIndicatorTo(btn, animate) {
    if (!segmentedIndicator || !btn) return;
    if (!animate) segmentedIndicator.classList.add('no-anim');
    segmentedIndicator.style.left = `${btn.offsetLeft}px`;
    segmentedIndicator.style.width = `${btn.offsetWidth}px`;
    if (!animate) {
      // Force layout so the position applies before re-enabling the transition.
      segmentedIndicator.offsetHeight;
      segmentedIndicator.classList.remove('no-anim');
    }
  }

  function updateSliderFill(input) {
    const min = Number(input.min) || 0;
    const max = Number(input.max) || 100;
    const pct = ((Number(input.value) - min) / (max - min)) * 100;
    input.style.setProperty('--fill', `${pct}%`);
  }

  // Corner radius is the one geometry control that needs recomputing after layout (it depends
  // on the preview element's own rendered size), whether that element is a <video>, an <img>, or
  // (in the editor) the crop-wrapper div — all expose clientWidth/clientHeight identically.
  function applyRadiusToPreviewElement(el) {
    const w = el.clientWidth;
    const h = el.clientHeight;
    if (!w || !h) return;
    const shortSide = Math.min(w, h);
    const radius = (shortSide / 2) * (currentRadiusPercent() / 100);
    el.style.borderRadius = `${radius}px`;
  }

  // Mirrors the server's captionBandRect/fontSize math (% of the *canvas* short side, not the
  // fitted media rect) — the per-clip size percent travels via a data attribute on the pill
  // itself so this stays a plain (previewBox, pillEl) function, symmetric with
  // applyRadiusToPreviewElement, rather than needing a clip lookup.
  function applyCaptionSizeToPreviewElement(previewBox, pillEl) {
    const w = previewBox.clientWidth;
    const h = previewBox.clientHeight;
    if (!w || !h) return;
    const shortSide = Math.min(w, h);
    const sizePercent = Number(pillEl.dataset.sizePercent) || 6;
    pillEl.style.fontSize = `${(shortSide * sizePercent) / 100}px`;
  }

  function hexToRgba(hex, opacityPercent) {
    const value = parseInt(hex.replace('#', ''), 16) || 0;
    const r = (value >> 16) & 0xff;
    const g = (value >> 8) & 0xff;
    const b = value & 0xff;
    return `rgba(${r}, ${g}, ${b}, ${clamp(opacityPercent, 0, 100) / 100})`;
  }

  // Full re-render of a caption pill from clip state — used by both the card's own caption
  // controls and the editor's (which bind to currentEditingClip instead), same shape as
  // renderEditorBackground vs setupBackgroundControls below.
  function renderCaptionPreview(previewBox, overlayEl, pillEl, clip) {
    pillEl.textContent = clip.caption;
    pillEl.style.fontFamily = CAPTION_FONTS[clip.captionFont] || CAPTION_FONTS.montserrat;
    pillEl.style.color = clip.captionColor;
    pillEl.dataset.sizePercent = clip.captionSizePercent;
    const hasBg = clip.captionBgOpacityPercent > 0;
    pillEl.classList.toggle('has-bg', hasBg);
    pillEl.style.backgroundColor = hasBg ? hexToRgba(clip.captionBgColor, clip.captionBgOpacityPercent) : '';
    overlayEl.classList.remove('caption-pos-top', 'caption-pos-middle', 'caption-pos-bottom');
    overlayEl.classList.add(`caption-pos-${clip.captionAnchor}`);
    applyCaptionSizeToPreviewElement(previewBox, pillEl);
  }

  // Aspect ratio and padding are applied directly to the preview box via CSS
  // (aspect-ratio + percentage padding, which is relative to the box's own width — the
  // same "% of canvas width" semantics the server uses), so the browser's own layout
  // does the "contain, centered, inset" math; only the corner radius needs recomputing
  // afterwards, since it depends on the preview element's resulting rendered size.
  function applyGlobalControlsToCard(clip) {
    clip.previewBox.style.aspectRatio = `${currentAspect.w} / ${currentAspect.h}`;
    const pad = `${currentPaddingPercent()}%`;
    clip.previewBox.style.paddingLeft = pad;
    clip.previewBox.style.paddingRight = pad;
    applyRadiusToPreviewElement(clip.previewEl);
  }

  function applyGlobalControlsToAll() {
    clips.forEach(applyGlobalControlsToCard);
    refreshEditorIfOpen();
  }

  // Background is per-clip (color swatches, or that clip's own blur toggle) — but the card's own
  // controls and the editor's controls (whichever clip is currently open in it) are two separate
  // DOM regions showing the *same* clip's state, so every mutation needs to refresh both. `els` is
  // just {bgSwatches, bgCustomSwatch, bgColorInput, bgBlurBtn} for whichever region is being
  // refreshed — a video card's own row (clip.ownBackgroundEls) or the shared editor sidebar.
  function clearBackgroundActiveState(els) {
    if (!els) return;
    els.bgSwatches.querySelectorAll('.bg-swatch').forEach(el => el.classList.remove('active'));
    els.bgCustomSwatch.classList.remove('active');
    els.bgBlurBtn.classList.remove('active');
  }

  function findSwatchForColor(els, hex) {
    const match = Array.from(els.bgSwatches.querySelectorAll('.bg-swatch')).find(el => el.dataset.hex === hex);
    return match || els.bgCustomSwatch;
  }

  function refreshBackgroundControlUI(els, clip) {
    if (!els) return;
    clearBackgroundActiveState(els);
    if (clip.backgroundMode === 'blur') {
      els.bgBlurBtn.classList.add('active');
    } else {
      els.bgColorInput.value = clip.backgroundColor;
      findSwatchForColor(els, clip.backgroundColor).classList.add('active');
    }
  }

  function applyClipBackgroundVisual(clip) {
    const isBlur = clip.backgroundMode === 'blur';
    clip.previewBox.classList.toggle('bg-is-blur', isBlur);
    clip.previewBox.style.backgroundColor = isBlur ? '' : clip.backgroundColor;
    refreshBackgroundControlUI(clip.ownBackgroundEls, clip);
    if (currentEditingClip === clip) {
      editorCanvasPreview.classList.toggle('bg-is-blur', isBlur);
      editorCanvasPreview.style.backgroundColor = isBlur ? '' : clip.backgroundColor;
      refreshBackgroundControlUI(editorBackgroundEls, clip);
    }
  }

  function setClipBackgroundColor(clip, hex) {
    clip.backgroundColor = hex;
    clip.backgroundMode = 'color';
    applyClipBackgroundVisual(clip);
  }

  function setClipBackgroundBlur(clip, isBlur) {
    clip.backgroundMode = isBlur ? 'blur' : 'color';
    applyClipBackgroundVisual(clip);
  }

  // The global button is a bulk action, not a per-clip override: it sets every clip *currently*
  // loaded to match, and becomes the default handed to clips uploaded from now on — but each clip
  // remains independently switchable afterward via its own Blur button (card row, or editor).
  globalBlurBtn.addEventListener('click', () => {
    globalBlurDefault = !globalBlurDefault;
    globalBlurBtn.classList.toggle('active', globalBlurDefault);
    clips.forEach(clip => setClipBackgroundBlur(clip, globalBlurDefault));
  });

  radiusSlider.addEventListener('input', () => {
    radiusValue.textContent = `${radiusSlider.value}%`;
    updateSliderFill(radiusSlider);
    clips.forEach(clip => applyRadiusToPreviewElement(clip.previewEl));
    refreshEditorIfOpen();
  });

  paddingSlider.addEventListener('input', () => {
    paddingValue.textContent = `${paddingSlider.value}%`;
    updateSliderFill(paddingSlider);
    applyGlobalControlsToAll();
  });

  updateSliderFill(radiusSlider);
  updateSliderFill(paddingSlider);

  ratioButtons.forEach(btn => {
    btn.addEventListener('click', () => {
      ratioButtons.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      currentAspect = { w: parseFloat(btn.dataset.w), h: parseFloat(btn.dataset.h) };
      moveIndicatorTo(btn, true);
      applyGlobalControlsToAll();
    });
  });

  const initialActiveRatioBtn = ratioButtons.find(btn => btn.classList.contains('active')) || ratioButtons[0];
  moveIndicatorTo(initialActiveRatioBtn, false);
  window.addEventListener('resize', () => {
    const active = ratioButtons.find(btn => btn.classList.contains('active')) || ratioButtons[0];
    moveIndicatorTo(active, false);
    if (currentEditingClip && !cropStage.hidden) renderCropRectFromClip();
  });

  // --- Drag & drop / file picking -----------------------------------------

  ['dragenter', 'dragover'].forEach(evt => {
    dropZone.addEventListener(evt, e => {
      e.preventDefault();
      dropZone.classList.add('drag-over');
    });
  });
  ['dragleave', 'drop'].forEach(evt => {
    dropZone.addEventListener(evt, e => {
      e.preventDefault();
      dropZone.classList.remove('drag-over');
    });
  });
  dropZone.addEventListener('drop', e => {
    const files = Array.from(e.dataTransfer.files)
      .filter(f => f.type.startsWith('video/') || f.type.startsWith('image/'));
    handleFiles(files);
  });
  dropZone.addEventListener('click', () => fileInput.click());
  dropZone.addEventListener('keydown', e => {
    if (e.key === 'Enter' || e.key === ' ') fileInput.click();
  });
  fileInput.addEventListener('change', () => {
    handleFiles(Array.from(fileInput.files));
    fileInput.value = '';
  });

  async function handleFiles(files) {
    for (const file of files) {
      await uploadFile(file);
    }
  }

  // --- Upload ---------------------------------------------------------------

  async function uploadFile(file) {
    const cardEl = createCardElement(file.name);
    const statusText = cardEl.querySelector('.status-text');
    statusText.textContent = 'Uploading…';
    try {
      const res = await fetch('/api/upload', {
        method: 'POST',
        headers: { 'X-Filename': encodeURIComponent(file.name) },
        body: file,
      });
      if (!res.ok) throw new Error(`upload failed (${res.status})`);
      const data = await res.json();
      initializeClip(cardEl, data);
      statusText.textContent = 'Ready';
      const wasHidden = globalControls.hidden;
      globalControls.hidden = false;
      if (wasHidden) {
        const active = ratioButtons.find(btn => btn.classList.contains('active')) || ratioButtons[0];
        moveIndicatorTo(active, false);
      }
    } catch (err) {
      statusText.textContent = `Upload failed: ${err.message}`;
      statusText.classList.add('error');
      cardEl.classList.add('error');
    }
  }

  function createCardElement(filename) {
    const fragment = cardTemplate.content.cloneNode(true);
    const cardEl = fragment.querySelector('.clip-card');
    cardEl.querySelector('.clip-name').textContent = filename;
    clipsContainer.appendChild(fragment);
    return clipsContainer.lastElementChild;
  }

  function initializeClip(cardEl, data) {
    const isPhoto = data.mediaKind === 'photo';
    cardEl.classList.add(isPhoto ? 'is-photo' : 'is-video');
    if (isPhoto) {
      initializePhotoClip(cardEl, data);
    } else {
      initializeVideoClip(cardEl, data);
    }
  }

  // Used by the video card's own background controls (photos edit background in the editor
  // instead — see setupEditorBackgroundControls below, which follows the same shape but binds to
  // whichever clip is currently open rather than one fixed at setup time).
  function setupBackgroundControls(cardEl, clip, suggestedColors) {
    const bgSwatches = cardEl.querySelector('.bg-swatches');
    const bgCustomSwatch = cardEl.querySelector('.bg-custom-swatch');
    const bgColorInput = cardEl.querySelector('.bg-color-input');
    const bgBlurBtn = cardEl.querySelector('.bg-blur-btn');
    clip.ownBackgroundEls = { bgSwatches, bgCustomSwatch, bgColorInput, bgBlurBtn };

    (suggestedColors || []).forEach(hex => {
      const swatch = document.createElement('button');
      swatch.type = 'button';
      swatch.className = 'bg-swatch';
      swatch.style.background = hex;
      swatch.title = hex;
      swatch.dataset.hex = hex;
      swatch.addEventListener('click', () => setClipBackgroundColor(clip, hex));
      bgSwatches.appendChild(swatch);
    });

    bgColorInput.addEventListener('input', () => setClipBackgroundColor(clip, bgColorInput.value));
    bgBlurBtn.addEventListener('click', () => setClipBackgroundBlur(clip, clip.backgroundMode !== 'blur'));
  }

  // Video-card-only (photo captions are edited in the big editor instead, matching how
  // background works — see the .clip-card.is-photo CSS rule that hides this block on photo
  // cards). Progressive disclosure: the styling row only appears once there's caption text.
  function setupCaptionControls(cardEl, clip) {
    const textInput = cardEl.querySelector('.caption-text-input');
    const styleRow = cardEl.querySelector('.caption-style-row');
    const fontSelect = cardEl.querySelector('.caption-font-select');
    const colorInput = cardEl.querySelector('.caption-color-input');
    const bgColorInput = cardEl.querySelector('.caption-bgcolor-input');
    const bgOpacitySlider = cardEl.querySelector('.caption-bgopacity-slider');
    const posButtons = Array.from(cardEl.querySelectorAll('.caption-pos-btn'));
    const overlayEl = cardEl.querySelector('.caption-overlay');
    const pillEl = cardEl.querySelector('.caption-pill');

    function refresh() {
      styleRow.hidden = clip.caption.length === 0;
      renderCaptionPreview(clip.previewBox, overlayEl, pillEl, clip);
    }

    textInput.addEventListener('input', () => {
      clip.caption = textInput.value;
      refresh();
    });

    fontSelect.addEventListener('change', () => {
      clip.captionFont = fontSelect.value;
      refresh();
    });

    colorInput.addEventListener('input', () => {
      clip.captionColor = colorInput.value;
      refresh();
    });

    bgColorInput.addEventListener('input', () => {
      clip.captionBgColor = bgColorInput.value;
      refresh();
    });

    bgOpacitySlider.addEventListener('input', () => {
      clip.captionBgOpacityPercent = Number(bgOpacitySlider.value);
      updateSliderFill(bgOpacitySlider);
      refresh();
    });

    posButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        posButtons.forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        clip.captionAnchor = btn.dataset.pos;
        refresh();
      });
    });

    updateSliderFill(bgOpacitySlider);
    refresh();
  }

  function initializeVideoClip(cardEl, data) {
    const video = cardEl.querySelector('video.main-video');
    const bgBlurVideo = cardEl.querySelector('video.bg-blur-video');
    const previewBox = cardEl.querySelector('.canvas-preview');
    const playOverlay = cardEl.querySelector('.play-overlay');
    const startInput = cardEl.querySelector('.trim-start');
    const endInput = cardEl.querySelector('.trim-end');
    const rangeBar = cardEl.querySelector('.trim-range');
    const playhead = cardEl.querySelector('.trim-playhead');
    const startLabel = cardEl.querySelector('.trim-start-label');
    const endLabel = cardEl.querySelector('.trim-end-label');
    const durationLabel = cardEl.querySelector('.trim-duration-label');
    const exportBtn = cardEl.querySelector('.export-btn');
    const deleteBtn = cardEl.querySelector('.delete-btn');
    const statusText = cardEl.querySelector('.status-text');

    const duration = data.durationSeconds || 0;
    video.src = `/api/media/${data.id}`;
    bgBlurVideo.src = `/api/media/${data.id}`;
    cardEl.querySelector('.clip-meta').textContent =
      `${data.width}×${data.height} • ${formatTime(duration)}`;

    [startInput, endInput].forEach(input => {
      input.min = 0;
      input.max = duration;
      input.step = Math.min(0.1, duration / 100 || 0.1);
    });
    startInput.value = 0;
    endInput.value = duration;
    durationLabel.textContent = formatTime(duration);

    const clip = {
      id: data.id,
      kind: 'video',
      cardEl,
      video,
      previewEl: video,
      previewBox,
      startInput,
      endInput,
      rangeBar,
      startLabel,
      endLabel,
      exportBtn,
      deleteBtn,
      statusText,
      duration,
      backgroundColor: '#ffffff',
      backgroundMode: globalBlurDefault ? 'blur' : 'color',
      caption: '',
      captionFont: 'montserrat',
      captionSizePercent: 6,
      captionColor: '#000000',
      captionBgColor: '#000000',
      captionBgOpacityPercent: 0,
      captionAnchor: 'bottom',
    };
    clips.set(data.id, clip);

    setupBackgroundControls(cardEl, clip, data.suggestedColors);
    applyClipBackgroundVisual(clip);
    setupCaptionControls(cardEl, clip);

    function updateRangeBar() {
      const start = parseFloat(startInput.value);
      const end = parseFloat(endInput.value);
      const leftPct = (start / duration) * 100;
      const widthPct = ((end - start) / duration) * 100;
      rangeBar.style.left = `${leftPct}%`;
      rangeBar.style.width = `${Math.max(widthPct, 0)}%`;
      startLabel.textContent = formatTime(start);
      endLabel.textContent = formatTime(end);
    }

    function updatePlayhead() {
      const pct = duration ? (video.currentTime / duration) * 100 : 0;
      playhead.style.left = `${Math.min(Math.max(pct, 0), 100)}%`;
      if (bgBlurVideo.readyState > 0) bgBlurVideo.currentTime = video.currentTime;
    }

    startInput.addEventListener('input', () => {
      let start = parseFloat(startInput.value);
      const end = parseFloat(endInput.value);
      if (start > end - MIN_TRIM_GAP) {
        start = Math.max(0, end - MIN_TRIM_GAP);
        startInput.value = start;
      }
      video.currentTime = start;
      updateRangeBar();
      updatePlayhead();
    });

    endInput.addEventListener('input', () => {
      const start = parseFloat(startInput.value);
      let end = parseFloat(endInput.value);
      if (end < start + MIN_TRIM_GAP) {
        end = Math.min(duration, start + MIN_TRIM_GAP);
        endInput.value = end;
      }
      video.currentTime = end;
      updateRangeBar();
      updatePlayhead();
    });

    // --- Playback (overlay button + in/out markers) -----------------------

    function setInMarker() {
      const end = parseFloat(endInput.value);
      const start = Math.min(Math.max(video.currentTime, 0), end - MIN_TRIM_GAP);
      startInput.value = start;
      updateRangeBar();
    }

    function setOutMarker() {
      const start = parseFloat(startInput.value);
      const end = Math.max(Math.min(video.currentTime, duration), start + MIN_TRIM_GAP);
      endInput.value = end;
      updateRangeBar();
    }

    function togglePlay() {
      if (video.paused) {
        if (activePlayingClip && activePlayingClip !== clip) {
          activePlayingClip.video.pause();
        }
        const start = parseFloat(startInput.value);
        const end = parseFloat(endInput.value);
        if (video.currentTime < start || video.currentTime >= end) {
          video.currentTime = start;
        }
        video.play().catch(() => {});
      } else {
        video.pause();
      }
    }

    previewBox.addEventListener('click', togglePlay);

    let playheadRaf = null;
    function tickPlayhead() {
      updatePlayhead();
      playheadRaf = requestAnimationFrame(tickPlayhead);
    }

    video.addEventListener('play', () => {
      activePlayingClip = clip;
      previewBox.classList.add('is-playing');
      playOverlay.setAttribute('aria-label', 'Pause');
      if (playheadRaf === null) playheadRaf = requestAnimationFrame(tickPlayhead);
      bgBlurVideo.play().catch(() => {});
    });

    video.addEventListener('pause', () => {
      if (activePlayingClip === clip) activePlayingClip = null;
      previewBox.classList.remove('is-playing');
      playOverlay.setAttribute('aria-label', 'Play');
      if (playheadRaf !== null) {
        cancelAnimationFrame(playheadRaf);
        playheadRaf = null;
      }
      updatePlayhead();
      bgBlurVideo.pause();
    });

    video.addEventListener('timeupdate', () => {
      const end = parseFloat(endInput.value);
      if (video.currentTime >= end) {
        video.currentTime = parseFloat(startInput.value);
      }
    });

    video.addEventListener('ended', () => {
      video.currentTime = parseFloat(startInput.value);
      video.play().catch(() => {});
    });

    video.addEventListener('loadedmetadata', () => applyRadiusToPreviewElement(video));
    resizeObserver.observe(video);
    resizeObserver.observe(previewBox);

    exportBtn.addEventListener('click', () => exportClip(clip));
    deleteBtn.addEventListener('click', () => removeClip(clip));

    applyGlobalControlsToCard(clip);
    updateRangeBar();
    updatePlayhead();
    clip.setInMarker = setInMarker;
    clip.setOutMarker = setOutMarker;
  }

  function initializePhotoClip(cardEl, data) {
    const img = cardEl.querySelector('img.main-img');
    const bgBlurImg = cardEl.querySelector('img.bg-blur-img');
    const previewBox = cardEl.querySelector('.canvas-preview');
    const exportBtn = cardEl.querySelector('.export-btn');
    const deleteBtn = cardEl.querySelector('.delete-btn');
    const statusText = cardEl.querySelector('.status-text');
    const editOverlay = cardEl.querySelector('.edit-overlay');

    img.src = `/api/media/${data.id}`;
    bgBlurImg.src = `/api/media/${data.id}`;
    cardEl.querySelector('.clip-meta').textContent = `${data.width}×${data.height}`;

    const clip = {
      id: data.id,
      kind: 'photo',
      cardEl,
      previewEl: img,
      previewBox,
      exportBtn,
      deleteBtn,
      statusText,
      naturalWidth: data.width,
      naturalHeight: data.height,
      suggestedColors: data.suggestedColors || [],
      backgroundColor: '#ffffff',
      backgroundMode: globalBlurDefault ? 'blur' : 'color',
      crop: { x: 0, y: 0, width: 1, height: 1 },
      exposure: 0,
      highlights: 0,
      shadows: 0,
      brightness: 0,
      contrast: 0,
      blackpoint: 0,
      caption: '',
      captionFont: 'montserrat',
      captionSizePercent: 6,
      captionColor: '#000000',
      captionBgColor: '#000000',
      captionBgOpacityPercent: 0,
      captionAnchor: 'bottom',
    };
    clips.set(data.id, clip);
    applyClipBackgroundVisual(clip);

    img.addEventListener('load', () => applyRadiusToPreviewElement(img));
    resizeObserver.observe(img);
    resizeObserver.observe(previewBox);

    exportBtn.addEventListener('click', () => exportClip(clip));
    deleteBtn.addEventListener('click', () => removeClip(clip));
    editOverlay.addEventListener('click', e => {
      e.stopPropagation();
      openEditor(clip);
    });
    previewBox.addEventListener('click', () => openEditor(clip));

    applyGlobalControlsToCard(clip);
  }

  document.addEventListener('keydown', e => {
    if (!activePlayingClip) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const active = document.activeElement;
    if (active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA' || active.isContentEditable)) return;
    const key = e.key.toLowerCase();
    if (key === 'i') {
      e.preventDefault();
      activePlayingClip.setInMarker();
    } else if (key === 'o') {
      e.preventDefault();
      activePlayingClip.setOutMarker();
    }
  });

  // --- Photo editor (large view: crop + tonal adjustments + background) --------------------
  //
  // There's exactly one editor overlay in the DOM, reused for whichever photo is currently being
  // edited. Its control listeners are wired once, here, and read/write `currentEditingClip`
  // dynamically rather than closing over a specific clip — that avoids rebinding (and leaking
  // duplicate) listeners every time a different photo is opened. `renderEditor*` functions are
  // what actually repopulate the UI for a given clip; call them on open and whenever that clip's
  // state changes some other way.

  const photoEditor = document.getElementById('photo-editor');
  const editorBackdrop = photoEditor.querySelector('.editor-backdrop');
  const editorCloseBtn = photoEditor.querySelector('.editor-close-btn');
  const editorClipName = photoEditor.querySelector('.editor-clip-name');
  const editorCanvasPreview = photoEditor.querySelector('.editor-canvas-preview');
  const editorBgBlurImg = photoEditor.querySelector('.editor-bg-blur-img');
  const editorCropWrapper = photoEditor.querySelector('.editor-crop-wrapper');
  const editorMainImg = photoEditor.querySelector('.editor-main-img');
  const editorExportBtn = photoEditor.querySelector('.editor-export-btn');
  const editorStatusText = photoEditor.querySelector('.editor-status-text');

  const editorBgSwatches = photoEditor.querySelector('.editor-background-control .bg-swatches');
  const editorBgCustomSwatch = photoEditor.querySelector('.editor-background-control .bg-custom-swatch');
  const editorBgColorInput = photoEditor.querySelector('.editor-background-control .bg-color-input');
  const editorBgBlurBtn = photoEditor.querySelector('.editor-background-control .bg-blur-btn');
  const editorBackgroundEls = {
    bgSwatches: editorBgSwatches, bgCustomSwatch: editorBgCustomSwatch,
    bgColorInput: editorBgColorInput, bgBlurBtn: editorBgBlurBtn,
  };

  const editorCaptionOverlay = photoEditor.querySelector('.editor-caption-overlay');
  const editorCaptionPill = editorCaptionOverlay.querySelector('.caption-pill');
  const editorCaptionTextInput = photoEditor.querySelector('.editor-caption-control .caption-text-input');
  const editorCaptionStyleRow = photoEditor.querySelector('.editor-caption-control .caption-style-row');
  const editorCaptionFontSelect = photoEditor.querySelector('.editor-caption-control .caption-font-select');
  const editorCaptionColorInput = photoEditor.querySelector('.editor-caption-control .caption-color-input');
  const editorCaptionBgColorInput = photoEditor.querySelector('.editor-caption-control .caption-bgcolor-input');
  const editorCaptionBgOpacitySlider = photoEditor.querySelector('.editor-caption-control .caption-bgopacity-slider');
  const editorCaptionPosButtons = Array.from(photoEditor.querySelectorAll('.editor-caption-control .caption-pos-btn'));

  const cropToolBtn = photoEditor.querySelector('.crop-tool-btn');
  const cropDoneBtn = photoEditor.querySelector('.crop-done-btn');
  const cropResetBtn = photoEditor.querySelector('.crop-reset-btn');
  const cropStage = photoEditor.querySelector('.crop-stage');
  const cropStageImg = photoEditor.querySelector('.crop-stage-img');
  const cropRect = photoEditor.querySelector('.crop-rect');

  const toneFuncR = photoEditor.querySelector('#editor-tone-curve feFuncR');
  const toneFuncG = photoEditor.querySelector('#editor-tone-curve feFuncG');
  const toneFuncB = photoEditor.querySelector('#editor-tone-curve feFuncB');
  editorMainImg.style.filter = 'url(#editor-tone-curve)';
  editorBgBlurImg.style.filter = 'url(#editor-tone-curve) blur(20px)';

  let currentEditingClip = null;

  function refreshEditorIfOpen() {
    if (currentEditingClip) applyEditorCanvasControls(currentEditingClip);
  }

  // Mirrors the server's fittedRect(fitting:in:horizontalPadding:) exactly (same "contain,
  // centered, inset" formula). Needed here — rather than just setting `aspect-ratio` on the
  // wrapper and letting CSS size it, the way the rest of this app's previews work — because
  // `.editor-crop-wrapper`'s only child (`.editor-main-img`) is `position: absolute` so it
  // contributes no intrinsic size; a plain <div> with only `aspect-ratio` and no explicit
  // width/height has nothing for the browser to size it *from* in that situation (confirmed via
  // getBoundingClientRect() while debugging: the wrapper rendered at 0×0), so the fit has to be
  // computed explicitly instead of left to CSS.
  function fittedBox(contentWidth, contentHeight, boundsWidth, boundsHeight, horizontalPadding) {
    const availableWidth = Math.max(boundsWidth - horizontalPadding * 2, 1);
    const scale = Math.min(availableWidth / contentWidth, boundsHeight / contentHeight);
    return { width: contentWidth * scale, height: contentHeight * scale };
  }

  function applyCropToPreview(containerEl, wrapperEl, imgEl, naturalWidth, naturalHeight, crop, horizontalPaddingPercent) {
    const cropWidthPx = crop.width * naturalWidth;
    const cropHeightPx = crop.height * naturalHeight;
    const containerBox = containerEl.getBoundingClientRect();
    const horizontalPadding = containerBox.width * (horizontalPaddingPercent / 100);
    const fitted = fittedBox(cropWidthPx, cropHeightPx, containerBox.width, containerBox.height, horizontalPadding);
    wrapperEl.style.width = `${fitted.width}px`;
    wrapperEl.style.height = `${fitted.height}px`;
    imgEl.style.width = `${(naturalWidth / cropWidthPx) * fitted.width}px`;
    imgEl.style.height = `${(naturalHeight / cropHeightPx) * fitted.height}px`;
    imgEl.style.left = `${-(crop.x * naturalWidth / cropWidthPx) * fitted.width}px`;
    imgEl.style.top = `${-(crop.y * naturalHeight / cropHeightPx) * fitted.height}px`;
  }

  function applyEditorCanvasControls(clip) {
    editorCanvasPreview.style.aspectRatio = `${currentAspect.w} / ${currentAspect.h}`;
    const paddingPercent = currentPaddingPercent();
    const pad = `${paddingPercent}%`;
    editorCanvasPreview.style.paddingLeft = pad;
    editorCanvasPreview.style.paddingRight = pad;
    applyCropToPreview(
      editorCanvasPreview, editorCropWrapper, editorMainImg,
      clip.naturalWidth, clip.naturalHeight, clip.crop, paddingPercent
    );
    applyRadiusToPreviewElement(editorCropWrapper);
    applyCaptionSizeToPreviewElement(editorCanvasPreview, editorCaptionPill);
  }

  // --- Background (shared shape with setupBackgroundControls, bound to currentEditingClip) ---

  editorBgColorInput.addEventListener('input', () => {
    if (currentEditingClip) setClipBackgroundColor(currentEditingClip, editorBgColorInput.value);
  });

  editorBgBlurBtn.addEventListener('click', () => {
    if (currentEditingClip) setClipBackgroundBlur(currentEditingClip, currentEditingClip.backgroundMode !== 'blur');
  });

  function renderEditorBackground(clip) {
    editorBgSwatches.innerHTML = '';
    clip.suggestedColors.forEach(hex => {
      const swatch = document.createElement('button');
      swatch.type = 'button';
      swatch.className = 'bg-swatch';
      swatch.style.background = hex;
      swatch.title = hex;
      swatch.dataset.hex = hex;
      swatch.addEventListener('click', () => setClipBackgroundColor(clip, hex));
      editorBgSwatches.appendChild(swatch);
    });
    applyClipBackgroundVisual(clip);
  }

  // --- Caption (editor side — mirrors setupCaptionControls above, bound to currentEditingClip
  // instead of a fixed clip; also keeps the card's own thumbnail preview in sync on every change,
  // the same way editorSelectBackgroundColor writes through to clip.previewBox). ---

  function editorRefreshCaption() {
    if (!currentEditingClip) return;
    editorCaptionStyleRow.hidden = currentEditingClip.caption.length === 0;
    renderCaptionPreview(editorCanvasPreview, editorCaptionOverlay, editorCaptionPill, currentEditingClip);
    const cardOverlay = currentEditingClip.cardEl.querySelector('.caption-overlay');
    const cardPill = currentEditingClip.cardEl.querySelector('.caption-pill');
    renderCaptionPreview(currentEditingClip.previewBox, cardOverlay, cardPill, currentEditingClip);
  }

  editorCaptionTextInput.addEventListener('input', () => {
    if (!currentEditingClip) return;
    currentEditingClip.caption = editorCaptionTextInput.value;
    editorRefreshCaption();
  });

  editorCaptionFontSelect.addEventListener('change', () => {
    if (!currentEditingClip) return;
    currentEditingClip.captionFont = editorCaptionFontSelect.value;
    editorRefreshCaption();
  });

  editorCaptionColorInput.addEventListener('input', () => {
    if (!currentEditingClip) return;
    currentEditingClip.captionColor = editorCaptionColorInput.value;
    editorRefreshCaption();
  });

  editorCaptionBgColorInput.addEventListener('input', () => {
    if (!currentEditingClip) return;
    currentEditingClip.captionBgColor = editorCaptionBgColorInput.value;
    editorRefreshCaption();
  });

  editorCaptionBgOpacitySlider.addEventListener('input', () => {
    if (!currentEditingClip) return;
    currentEditingClip.captionBgOpacityPercent = Number(editorCaptionBgOpacitySlider.value);
    updateSliderFill(editorCaptionBgOpacitySlider);
    editorRefreshCaption();
  });

  editorCaptionPosButtons.forEach(btn => {
    btn.addEventListener('click', () => {
      if (!currentEditingClip) return;
      editorCaptionPosButtons.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      currentEditingClip.captionAnchor = btn.dataset.pos;
      editorRefreshCaption();
    });
  });

  function renderEditorCaption(clip) {
    editorCaptionTextInput.value = clip.caption;
    editorCaptionFontSelect.value = clip.captionFont;
    editorCaptionColorInput.value = clip.captionColor;
    editorCaptionBgColorInput.value = clip.captionBgColor;
    editorCaptionBgOpacitySlider.value = clip.captionBgOpacityPercent;
    updateSliderFill(editorCaptionBgOpacitySlider);
    editorCaptionPosButtons.forEach(b => b.classList.toggle('active', b.dataset.pos === clip.captionAnchor));
    editorRefreshCaption();
  }

  // --- Tonal adjustment sliders + live tone-curve preview ---------------------------------
  //
  // CSS alone can't approximate highlights/shadows/black-point (no matching filter primitive),
  // so the preview instead computes a 1D lookup curve in JS — weighting each slider's
  // contribution by where it sits in the 0...1 input range (shadows biased low, highlights
  // biased high, black point a levels-style floor shift) — and renders it as an SVG
  // feComponentTransfer table filter applied to the editor's <img>. Like every other preview
  // approximation in this app, it's tuned to look directionally right, not to bit-match the
  // server's actual CIExposureAdjust/CIHighlightShadowAdjust/CIColorControls/CIColorMatrix
  // chain — the export is the source of truth.

  const ADJUST_SLIDERS = [
    { slider: photoEditor.querySelector('.adjust-exposure'), valueEl: photoEditor.querySelector('.exposure-value'), key: 'exposure' },
    { slider: photoEditor.querySelector('.adjust-highlights'), valueEl: photoEditor.querySelector('.highlights-value'), key: 'highlights' },
    { slider: photoEditor.querySelector('.adjust-shadows'), valueEl: photoEditor.querySelector('.shadows-value'), key: 'shadows' },
    { slider: photoEditor.querySelector('.adjust-brightness'), valueEl: photoEditor.querySelector('.brightness-value'), key: 'brightness' },
    { slider: photoEditor.querySelector('.adjust-contrast'), valueEl: photoEditor.querySelector('.contrast-value'), key: 'contrast' },
    { slider: photoEditor.querySelector('.adjust-blackpoint'), valueEl: photoEditor.querySelector('.blackpoint-value'), key: 'blackpoint' },
  ];

  ADJUST_SLIDERS.forEach(({ slider, valueEl, key }) => {
    slider.addEventListener('input', () => {
      if (!currentEditingClip) return;
      currentEditingClip[key] = Number(slider.value);
      valueEl.textContent = currentEditingClip[key];
      updateSliderFill(slider);
      updateToneCurve(currentEditingClip);
    });
  });

  function renderEditorSliders(clip) {
    ADJUST_SLIDERS.forEach(({ slider, valueEl, key }) => {
      slider.value = clip[key];
      valueEl.textContent = clip[key];
      updateSliderFill(slider);
    });
  }

  function toneCurveTable(clip) {
    const N = 32;
    const exposureMul = Math.pow(2, (clip.exposure / 100) * 4);
    const shadowAmt = (clip.shadows / 100) * 0.35;
    const highlightAmt = (clip.highlights / 100) * 0.35;
    const brightnessAmt = (clip.brightness / 100) * 0.5;
    const contrastAmt = clip.contrast / 100;
    const blackAmt = clip.blackpoint / 100;
    const t = Math.abs(blackAmt) * 0.3;
    const values = [];
    for (let i = 0; i <= N; i++) {
      const x = i / N;
      let y = x * exposureMul;
      y += shadowAmt * (1 - x) * (1 - x);
      y += highlightAmt * x * x;
      y += brightnessAmt;
      y = 0.5 + (y - 0.5) * (1 + contrastAmt);
      y = blackAmt >= 0 ? t + y * (1 - t) : (y - t) / (1 - t);
      values.push(clamp(y, 0, 1));
    }
    return values;
  }

  function updateToneCurve(clip) {
    const table = toneCurveTable(clip).join(' ');
    toneFuncR.setAttribute('tableValues', table);
    toneFuncG.setAttribute('tableValues', table);
    toneFuncB.setAttribute('tableValues', table);
  }

  // --- Crop tool: full-image stage with a draggable/resizable selection rect --------------

  function stageImageBox() {
    const stageRect = cropStage.getBoundingClientRect();
    const imgRect = cropStageImg.getBoundingClientRect();
    return {
      left: imgRect.left - stageRect.left,
      top: imgRect.top - stageRect.top,
      width: imgRect.width,
      height: imgRect.height,
    };
  }

  function renderCropRectFromClip() {
    if (!currentEditingClip) return;
    const box = stageImageBox();
    const crop = currentEditingClip.crop;
    cropRect.style.left = `${box.left + crop.x * box.width}px`;
    cropRect.style.top = `${box.top + crop.y * box.height}px`;
    cropRect.style.width = `${crop.width * box.width}px`;
    cropRect.style.height = `${crop.height * box.height}px`;
  }

  function beginCropPointerDrag(e, mode, edge) {
    if (!currentEditingClip) return;
    e.preventDefault();
    e.stopPropagation();
    const box = stageImageBox();
    const startX = e.clientX;
    const startY = e.clientY;
    const startCrop = { ...currentEditingClip.crop };

    function onMove(ev) {
      const dx = (ev.clientX - startX) / box.width;
      const dy = (ev.clientY - startY) / box.height;
      let x = startCrop.x, y = startCrop.y, width = startCrop.width, height = startCrop.height;
      if (mode === 'move') {
        x = clamp(startCrop.x + dx, 0, 1 - width);
        y = clamp(startCrop.y + dy, 0, 1 - height);
      } else {
        let x1 = startCrop.x, y1 = startCrop.y;
        let x2 = startCrop.x + startCrop.width, y2 = startCrop.y + startCrop.height;
        if (edge.includes('w')) x1 = clamp(startCrop.x + dx, 0, x2 - MIN_CROP);
        if (edge.includes('e')) x2 = clamp(x2 + dx, x1 + MIN_CROP, 1);
        if (edge.includes('n')) y1 = clamp(startCrop.y + dy, 0, y2 - MIN_CROP);
        if (edge.includes('s')) y2 = clamp(y2 + dy, y1 + MIN_CROP, 1);
        x = x1; y = y1; width = x2 - x1; height = y2 - y1;
      }
      currentEditingClip.crop = { x, y, width, height };
      renderCropRectFromClip();
    }
    function onUp() {
      window.removeEventListener('pointermove', onMove);
      window.removeEventListener('pointerup', onUp);
    }
    window.addEventListener('pointermove', onMove);
    window.addEventListener('pointerup', onUp);
  }

  cropRect.addEventListener('pointerdown', e => {
    if (e.target !== cropRect) return;
    beginCropPointerDrag(e, 'move');
  });
  cropRect.querySelectorAll('.crop-handle').forEach(handle => {
    handle.addEventListener('pointerdown', e => beginCropPointerDrag(e, 'resize', handle.dataset.edge));
  });

  function enterCropTool() {
    if (!currentEditingClip) return;
    editorCanvasPreview.hidden = true;
    cropStage.hidden = false;
    cropToolBtn.hidden = true;
    cropDoneBtn.hidden = false;
    cropResetBtn.hidden = false;
    cropStageImg.src = `/api/media/${currentEditingClip.id}`;
    if (cropStageImg.complete) renderCropRectFromClip();
  }

  function exitCropTool() {
    editorCanvasPreview.hidden = false;
    cropStage.hidden = true;
    cropToolBtn.hidden = false;
    cropDoneBtn.hidden = true;
    cropResetBtn.hidden = true;
  }

  function confirmCropTool() {
    exitCropTool();
    applyEditorCanvasControls(currentEditingClip);
  }

  cropStageImg.addEventListener('load', renderCropRectFromClip);
  cropToolBtn.addEventListener('click', enterCropTool);
  cropDoneBtn.addEventListener('click', confirmCropTool);
  cropResetBtn.addEventListener('click', () => {
    if (!currentEditingClip) return;
    currentEditingClip.crop = { x: 0, y: 0, width: 1, height: 1 };
    renderCropRectFromClip();
  });

  // --- Open / close --------------------------------------------------------------------

  function openEditor(clip) {
    currentEditingClip = clip;
    photoEditor.hidden = false;
    document.body.style.overflow = 'hidden';
    editorClipName.textContent = clip.cardEl.querySelector('.clip-name').textContent;
    editorMainImg.src = `/api/media/${clip.id}`;
    editorBgBlurImg.src = `/api/media/${clip.id}`;
    editorStatusText.textContent = '';
    editorStatusText.classList.remove('error', 'success');
    exitCropTool();
    renderEditorBackground(clip);
    renderEditorCaption(clip);
    renderEditorSliders(clip);
    updateToneCurve(clip);
    applyEditorCanvasControls(clip);
  }

  function closeEditor() {
    currentEditingClip = null;
    photoEditor.hidden = true;
    document.body.style.overflow = '';
  }

  editorCloseBtn.addEventListener('click', closeEditor);
  editorBackdrop.addEventListener('click', closeEditor);
  document.addEventListener('keydown', e => {
    if (photoEditor.hidden) return;
    if (!cropStage.hidden && e.key === 'Enter') {
      e.preventDefault();
      confirmCropTool();
    } else if (e.key === 'Escape') {
      closeEditor();
    }
  });
  editorExportBtn.addEventListener('click', () => {
    if (currentEditingClip) exportClip(currentEditingClip, editorStatusText);
  });

  // --- Export -----------------------------------------------------------

  async function exportClip(clip, extraStatusEl) {
    const statusEls = extraStatusEl ? [clip.statusText, extraStatusEl] : [clip.statusText];
    clip.exportBtn.disabled = true;
    if (currentEditingClip === clip) editorExportBtn.disabled = true;
    statusEls.forEach(el => {
      el.classList.remove('error', 'success');
      el.innerHTML = '<span class="spinner"></span>Exporting…';
    });
    try {
      const res = await fetch(`/api/export/${clip.id}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          trimStart: clip.kind === 'video' ? parseFloat(clip.startInput.value) : 0,
          trimEnd: clip.kind === 'video' ? parseFloat(clip.endInput.value) : 0,
          cornerRadiusPercent: currentRadiusPercent(),
          aspectRatioWidth: currentAspect.w,
          aspectRatioHeight: currentAspect.h,
          paddingPercent: currentPaddingPercent(),
          backgroundMode: clip.backgroundMode,
          backgroundColorHex: clip.backgroundColor,
          cropX: clip.crop ? clip.crop.x : 0,
          cropY: clip.crop ? clip.crop.y : 0,
          cropWidth: clip.crop ? clip.crop.width : 1,
          cropHeight: clip.crop ? clip.crop.height : 1,
          exposurePercent: clip.exposure || 0,
          highlightsPercent: clip.highlights || 0,
          shadowsPercent: clip.shadows || 0,
          brightnessPercent: clip.brightness || 0,
          contrastPercent: clip.contrast || 0,
          blackPercent: clip.blackpoint || 0,
          captionText: clip.caption || '',
          captionFontKey: clip.captionFont || 'montserrat',
          captionSizePercent: clip.captionSizePercent || 6,
          captionColorHex: clip.captionColor || '#000000',
          captionBgColorHex: clip.captionBgColor || '#000000',
          captionBgOpacityPercent: clip.captionBgOpacityPercent || 0,
          captionAnchor: clip.captionAnchor || 'bottom',
        }),
      });
      if (!res.ok) throw new Error(`export failed (${res.status})`);
      const data = await res.json();
      const filename = data.outputPath.split('/').pop();
      statusEls.forEach(el => {
        el.textContent = `Exported → ${filename}`;
        el.classList.add('success');
      });
    } catch (err) {
      statusEls.forEach(el => {
        el.textContent = `Export failed: ${err.message}`;
        el.classList.add('error');
      });
    } finally {
      clip.exportBtn.disabled = false;
      if (currentEditingClip === clip) editorExportBtn.disabled = false;
    }
  }

  function removeClip(clip) {
    if (activePlayingClip === clip) activePlayingClip = null;
    if (currentEditingClip === clip) closeEditor();
    if (clip.video) clip.video.pause();
    resizeObserver.unobserve(clip.previewEl);
    resizeObserver.unobserve(clip.previewBox);
    clips.delete(clip.id);
    clip.cardEl.remove();
    if (clips.size === 0) globalControls.hidden = true;
    fetch(`/api/clip/${clip.id}`, { method: 'DELETE' }).catch(() => {});
  }

  exportAllBtn.addEventListener('click', async () => {
    exportAllBtn.disabled = true;
    for (const clip of clips.values()) {
      await exportClip(clip);
    }
    exportAllBtn.disabled = false;
  });

  revealBtn.addEventListener('click', () => {
    fetch('/api/reveal-output', { method: 'POST' });
  });
})();
