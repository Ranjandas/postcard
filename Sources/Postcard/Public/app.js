(() => {
  const dropZone = document.getElementById('drop-zone');
  const fileInput = document.getElementById('file-input');
  const globalControls = document.getElementById('global-controls');
  const radiusSlider = document.getElementById('radius-slider');
  const radiusValue = document.getElementById('radius-value');
  const paddingSlider = document.getElementById('padding-slider');
  const paddingValue = document.getElementById('padding-value');
  const ratioButtons = Array.from(document.querySelectorAll('.ratio-btn'));
  const exportAllBtn = document.getElementById('export-all-btn');
  const revealBtn = document.getElementById('reveal-btn');
  const clipsContainer = document.getElementById('clips');
  const cardTemplate = document.getElementById('clip-card-template');

  const MIN_TRIM_GAP = 0.1;
  const clips = new Map(); // id -> clip state

  let currentAspect = readActiveAspectRatio();

  const resizeObserver = new ResizeObserver(entries => {
    for (const entry of entries) {
      const video = entry.target;
      applyRadiusToVideo(video);
    }
  });

  function formatTime(seconds) {
    if (!isFinite(seconds) || seconds < 0) seconds = 0;
    const m = Math.floor(seconds / 60);
    const s = (seconds % 60).toFixed(1).padStart(4, '0');
    return `${m}:${s}`;
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

  function applyRadiusToVideo(video) {
    const w = video.clientWidth;
    const h = video.clientHeight;
    if (!w || !h) return;
    const shortSide = Math.min(w, h);
    const radius = (shortSide / 2) * (currentRadiusPercent() / 100);
    video.style.borderRadius = `${radius}px`;
  }

  // Aspect ratio and padding are applied directly to the preview box via CSS
  // (aspect-ratio + percentage padding, which is relative to the box's own width — the
  // same "% of canvas width" semantics the server uses), so the browser's own layout
  // does the "contain, centered, inset" math; only the corner radius needs recomputing
  // afterwards, since it depends on the video element's resulting rendered size.
  function applyGlobalControlsToCard(clip) {
    clip.previewBox.style.aspectRatio = `${currentAspect.w} / ${currentAspect.h}`;
    const pad = `${currentPaddingPercent()}%`;
    clip.previewBox.style.paddingLeft = pad;
    clip.previewBox.style.paddingRight = pad;
    applyRadiusToVideo(clip.video);
  }

  function applyGlobalControlsToAll() {
    clips.forEach(applyGlobalControlsToCard);
  }

  radiusSlider.addEventListener('input', () => {
    radiusValue.textContent = `${radiusSlider.value}%`;
    clips.forEach(clip => applyRadiusToVideo(clip.video));
  });

  paddingSlider.addEventListener('input', () => {
    paddingValue.textContent = `${paddingSlider.value}%`;
    applyGlobalControlsToAll();
  });

  ratioButtons.forEach(btn => {
    btn.addEventListener('click', () => {
      ratioButtons.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      currentAspect = { w: parseFloat(btn.dataset.w), h: parseFloat(btn.dataset.h) };
      applyGlobalControlsToAll();
    });
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
    const files = Array.from(e.dataTransfer.files).filter(f => f.type.startsWith('video/'));
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
      const formData = new FormData();
      formData.append('file', file, file.name);
      const res = await fetch('/api/upload', { method: 'POST', body: formData });
      if (!res.ok) throw new Error(`upload failed (${res.status})`);
      const data = await res.json();
      initializeClip(cardEl, data);
      statusText.textContent = 'Ready';
      globalControls.hidden = false;
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
    const video = cardEl.querySelector('video');
    const previewBox = cardEl.querySelector('.canvas-preview');
    const startInput = cardEl.querySelector('.trim-start');
    const endInput = cardEl.querySelector('.trim-end');
    const rangeBar = cardEl.querySelector('.trim-range');
    const startLabel = cardEl.querySelector('.trim-start-label');
    const endLabel = cardEl.querySelector('.trim-end-label');
    const durationLabel = cardEl.querySelector('.trim-duration-label');
    const exportBtn = cardEl.querySelector('.export-btn');
    const statusText = cardEl.querySelector('.status-text');

    const duration = data.durationSeconds;
    video.src = `/api/media/${data.id}`;
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
      video,
      previewBox,
      startInput,
      endInput,
      rangeBar,
      startLabel,
      endLabel,
      exportBtn,
      statusText,
      duration,
    };
    clips.set(data.id, clip);

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

    startInput.addEventListener('input', () => {
      let start = parseFloat(startInput.value);
      const end = parseFloat(endInput.value);
      if (start > end - MIN_TRIM_GAP) {
        start = Math.max(0, end - MIN_TRIM_GAP);
        startInput.value = start;
      }
      video.currentTime = start;
      updateRangeBar();
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
    });

    video.addEventListener('loadedmetadata', () => applyRadiusToVideo(video));
    resizeObserver.observe(video);

    exportBtn.addEventListener('click', () => exportClip(clip));

    applyGlobalControlsToCard(clip);
    updateRangeBar();
  }

  // --- Export -----------------------------------------------------------

  async function exportClip(clip) {
    clip.exportBtn.disabled = true;
    clip.statusText.classList.remove('error', 'success');
    clip.statusText.innerHTML = '<span class="spinner"></span>Exporting…';
    try {
      const res = await fetch(`/api/export/${clip.id}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          trimStart: parseFloat(clip.startInput.value),
          trimEnd: parseFloat(clip.endInput.value),
          cornerRadiusPercent: currentRadiusPercent(),
          aspectRatioWidth: currentAspect.w,
          aspectRatioHeight: currentAspect.h,
          paddingPercent: currentPaddingPercent(),
        }),
      });
      if (!res.ok) throw new Error(`export failed (${res.status})`);
      const data = await res.json();
      const filename = data.outputPath.split('/').pop();
      clip.statusText.textContent = `Exported → ${filename}`;
      clip.statusText.classList.add('success');
    } catch (err) {
      clip.statusText.textContent = `Export failed: ${err.message}`;
      clip.statusText.classList.add('error');
    } finally {
      clip.exportBtn.disabled = false;
    }
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
