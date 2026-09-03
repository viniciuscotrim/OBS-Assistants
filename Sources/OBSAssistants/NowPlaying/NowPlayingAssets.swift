import Foundation

/// The Now Playing overlay page (HTML/CSS/JS), embedded directly as Swift
/// string constants instead of shipped as a separate SwiftPM resource
/// bundle — same rationale as `OverlayAssets` (see its doc comment): a
/// hand-assembled .app has nowhere reliable to put a `Bundle.module`
/// resource bundle, so the built binary stays fully self-contained instead.
///
/// Keep these in sync with what you see in a browser when iterating — the
/// content below is plain HTML/CSS/JS, easiest edited by temporarily pasting
/// it into standalone .html/.css/.js files, then back in here.
enum NowPlayingAssets {
    static let html = #"""
    <!DOCTYPE html>
    <html lang="pt-BR">
    <head>
    <meta charset="UTF-8">
    <title>Now Playing — OBS Assistants</title>
    <link rel="stylesheet" href="overlay.css">
    </head>
    <body>
      <div id="card" class="card hidden">
        <div class="artwork-wrap">
          <img id="art-a" class="artwork" alt="">
          <img id="art-b" class="artwork" alt="">
        </div>
        <div class="info">
          <div class="marquee-mask" id="title-mask">
            <div class="marquee-track" id="title-track">
              <span class="title" id="title-text"></span>
            </div>
          </div>
          <div class="marquee-mask" id="artist-mask">
            <div class="marquee-track" id="artist-track">
              <span class="artist" id="artist-text"></span>
            </div>
          </div>
          <div class="progress-outer">
            <div class="progress-inner" id="progress-bar"></div>
          </div>
          <div class="time-row">
            <span id="time-current">0:00</span>
            <span id="time-total">0:00</span>
          </div>
        </div>
      </div>
      <script src="overlay.js"></script>
    </body>
    </html>
    """#

    static let css = #"""
    * {
      box-sizing: border-box;
    }

    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background: transparent; /* required for OBS Browser Source */
      overflow: hidden;
      font-family: -apple-system, "Segoe UI", "Helvetica Neue", Arial, sans-serif;
    }

    .card {
      position: absolute;
      left: 24px;
      bottom: 24px;
      display: flex;
      align-items: center;
      gap: 14px;
      padding: 12px 18px 12px 12px;
      border-radius: 14px;
      width: 420px;
      transition: opacity 0.6s ease;
      opacity: 1;
    }

    .card.hidden {
      opacity: 0;
    }

    /* ---------- Themes ---------- */
    body.theme-dark .card {
      background: rgba(18, 18, 20, 0.82);
      color: #ffffff;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35);
    }

    body.theme-twitch-purple .card {
      background: rgba(30, 16, 41, 0.85);
      border: 1px solid rgba(145, 71, 255, 0.6);
      color: #f3edff;
      box-shadow: 0 8px 24px rgba(89, 20, 156, 0.45);
    }

    body.theme-transparent .card {
      background: transparent;
      color: #ffffff;
      text-shadow: 0 1px 6px rgba(0, 0, 0, 0.85);
    }

    /* ---------- Artwork (crossfade) ---------- */
    .artwork-wrap {
      position: relative;
      width: 64px;
      height: 64px;
      flex: 0 0 auto;
      border-radius: 8px;
      overflow: hidden;
      background: rgba(255, 255, 255, 0.08);
    }

    .artwork {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      object-fit: cover;
      opacity: 0;
      transition: opacity 0.5s ease;
    }

    .artwork.visible {
      opacity: 1;
    }

    /* ---------- Text / marquee ---------- */
    .info {
      flex: 1 1 auto;
      min-width: 0;
      display: flex;
      flex-direction: column;
      gap: 6px;
    }

    .marquee-mask {
      overflow: hidden;
      white-space: nowrap;
      width: 100%;
    }

    .marquee-track {
      display: inline-block;
      white-space: nowrap;
      will-change: transform;
    }

    .marquee-track.animate {
      animation: marquee-scroll linear infinite;
    }

    @keyframes marquee-scroll {
      0% { transform: translateX(0); }
      100% { transform: translateX(var(--marquee-distance, -100px)); }
    }

    .title {
      font-size: 15px;
      font-weight: 700;
      padding-right: 40px;
    }

    .artist {
      font-size: 12px;
      font-weight: 400;
      opacity: 0.8;
      padding-right: 40px;
    }

    /* ---------- Progress bar ---------- */
    .progress-outer {
      width: 100%;
      height: 5px;
      border-radius: 3px;
      background: rgba(255, 255, 255, 0.18);
      overflow: hidden;
    }

    body.theme-dark .progress-inner {
      background: #ffffff;
    }

    body.theme-twitch-purple .progress-inner {
      background: #9147ff;
    }

    body.theme-transparent .progress-inner {
      background: #ffffff;
    }

    .progress-inner {
      height: 100%;
      width: 100%;
      border-radius: 3px;
      /* Filled via `transform: scaleX(...)` (set from JS every frame) instead of
         the `width` property: width changes trigger layout on every single
         animation frame, which is what caused the visible back-and-forth
         jitter/stutter — a GPU-composited transform never re-triggers layout. */
      transform-origin: left center;
      transform: scaleX(0);
      will-change: transform;
    }

    .time-row {
      display: flex;
      justify-content: space-between;
      font-size: 10px;
      opacity: 0.75;
      font-variant-numeric: tabular-nums;
    }
    """#

    static let js = #"""
    (() => {
      "use strict";

      const POLL_MS = 500;
      const AUTO_HIDE_DELAY_MS = 4000;
      const MARQUEE_PX_PER_SEC = 32;
      const MAX_FAILED_POLLS_BEFORE_STOPPED = 6; // ~3s of unreachable server
      // Music.app's reported `player position` has coarse/jittery precision, so two
      // consecutive polls of the same instant in playback can disagree by a couple
      // hundred ms. Anything smaller than this is treated as that jitter and
      // ignored (the displayed time never steps backward); anything larger is
      // treated as a real seek and snaps immediately.
      const SEEK_JUMP_THRESHOLD_MS = 2500;

      const params = new URLSearchParams(window.location.search);
      const theme = params.get("theme") || "dark";
      document.body.classList.add(`theme-${theme}`);

      const card = document.getElementById("card");
      const artA = document.getElementById("art-a");
      const artB = document.getElementById("art-b");
      const titleText = document.getElementById("title-text");
      const artistText = document.getElementById("artist-text");
      const titleMask = document.getElementById("title-mask");
      const artistMask = document.getElementById("artist-mask");
      const titleTrack = document.getElementById("title-track");
      const artistTrack = document.getElementById("artist-track");
      const progressBar = document.getElementById("progress-bar");
      const timeCurrentEl = document.getElementById("time-current");
      const timeTotalEl = document.getElementById("time-total");

      let activeArt = artA;
      let inactiveArt = artB;
      let currentArtworkUrl = null;

      let lastData = null;
      let lastFetchClientTime = 0;
      let failedPolls = 0;
      let hideTimer = null;
      let isVisible = false;

      // Monotonic display clock (see SEEK_JUMP_THRESHOLD_MS above) — this is what
      // actually gets painted, separate from the raw server/interpolated value.
      let displayedMs = 0;
      let lastDisplayedSeconds = -1;

      function fmtTime(ms) {
        const totalSeconds = Math.max(0, Math.floor(ms / 1000));
        const m = Math.floor(totalSeconds / 60);
        const s = totalSeconds % 60;
        return `${m}:${s.toString().padStart(2, "0")}`;
      }

      function showCard() {
        if (isVisible) return;
        isVisible = true;
        card.classList.remove("hidden");
      }

      function hideCard() {
        if (!isVisible) return;
        isVisible = false;
        card.classList.add("hidden");
      }

      function scheduleAutoHide() {
        if (hideTimer) clearTimeout(hideTimer);
        hideTimer = setTimeout(() => {
          hideCard();
        }, AUTO_HIDE_DELAY_MS);
      }

      function cancelAutoHide() {
        if (hideTimer) {
          clearTimeout(hideTimer);
          hideTimer = null;
        }
      }

      function setupMarquee(mask, track, textEl, text) {
        textEl.textContent = text;
        track.classList.remove("animate");
        track.style.transform = "translateX(0)";
        // Measure after layout settles. `track` is display:inline-block so its
        // scrollWidth reliably reflects the text's natural width (unlike a plain
        // inline <span>, whose scrollWidth is unreliable in some engines).
        requestAnimationFrame(() => {
          const overflow = track.scrollWidth - mask.clientWidth;
          if (overflow > 8) {
            const distance = -(overflow + 40); // small gap before it loops
            const duration = Math.abs(distance) / MARQUEE_PX_PER_SEC;
            track.style.setProperty("--marquee-distance", `${distance}px`);
            track.style.animationDuration = `${duration}s`;
            track.classList.add("animate");
          }
        });
      }

      function crossfadeArtwork(url) {
        if (url === currentArtworkUrl) return;
        currentArtworkUrl = url;

        if (!url) {
          activeArt.classList.remove("visible");
          inactiveArt.classList.remove("visible");
          return;
        }

        const img = inactiveArt;
        img.onload = () => {
          inactiveArt.classList.add("visible");
          activeArt.classList.remove("visible");
          const tmp = activeArt;
          activeArt = inactiveArt;
          inactiveArt = tmp;
        };
        img.onerror = () => {
          // Leave previous artwork visible on failure.
        };
        img.src = url;
      }

      function applyData(data) {
        const trackChanged = !lastData || lastData.trackId !== data.trackId;
        lastData = data;
        lastFetchClientTime = performance.now();

        if (data.trackId === "none" || (!data.isPlaying && data.durationMs === 0)) {
          scheduleAutoHide();
          return;
        }

        if (data.isPlaying) {
          cancelAutoHide();
          showCard();
        } else {
          scheduleAutoHide();
        }

        if (trackChanged) {
          titleText.textContent = data.title;
          setupMarquee(titleMask, titleTrack, titleText, data.title || "");
          setupMarquee(artistMask, artistTrack, artistText, data.artist || "");
          const absoluteUrl = data.artworkUrl ? new URL(data.artworkUrl, window.location.origin).toString() : null;
          crossfadeArtwork(absoluteUrl);
          // New track: reset the monotonic display clock instead of letting it
          // carry over (and possibly jump backward) from the previous track.
          displayedMs = data.positionMs;
          lastDisplayedSeconds = -1;
        }

        timeTotalEl.textContent = fmtTime(data.durationMs);
      }

      async function poll() {
        try {
          const res = await fetch("/nowplaying", { cache: "no-store" });
          if (!res.ok) throw new Error("bad status");
          const data = await res.json();
          failedPolls = 0;
          applyData(data);
        } catch (err) {
          failedPolls += 1;
          if (failedPolls >= MAX_FAILED_POLLS_BEFORE_STOPPED) {
            lastData = null;
            scheduleAutoHide();
          }
        } finally {
          setTimeout(poll, POLL_MS);
        }
      }

      function renderLoop() {
        if (lastData && lastData.durationMs > 0) {
          const elapsedSinceFetch = lastData.isPlaying ? (performance.now() - lastFetchClientTime) : 0;
          const rawMs = Math.min(lastData.durationMs, lastData.positionMs + elapsedSinceFetch);

          // Only move the displayed clock forward, or snap on a real seek. Small
          // backward deltas (AppleScript/poll jitter) are simply ignored, which is
          // what stops the seconds counter from flickering back and forth.
          const delta = rawMs - displayedMs;
          if (delta > 0 || Math.abs(delta) > SEEK_JUMP_THRESHOLD_MS) {
            displayedMs = rawMs;
          }

          const fraction = Math.max(0, Math.min(1, displayedMs / lastData.durationMs));
          // transform (compositor-only) instead of width (layout every frame) —
          // see the comment on .progress-inner in overlay.css.
          progressBar.style.transform = `scaleX(${fraction})`;

          // Only touch the DOM when the whole second actually changes — "atualiza
          // a cada segundo apenas".
          const seconds = Math.floor(displayedMs / 1000);
          if (seconds !== lastDisplayedSeconds) {
            lastDisplayedSeconds = seconds;
            timeCurrentEl.textContent = fmtTime(displayedMs);
          }
        }
        requestAnimationFrame(renderLoop);
      }

      poll();
      requestAnimationFrame(renderLoop);

      // ---------------------------------------------------------------------
      // Audio: plays Music.app's audio (when "Music só no streaming" is on)
      // straight from this page over a WebSocket, so OBS needs only this one
      // Browser Source for both video and audio — no second, separately
      // configured audio input source.
      // ---------------------------------------------------------------------
      const AUDIO_SAMPLE_RATE = 48000;
      const AUDIO_CHANNELS = 2;
      const AUDIO_LEAD_SEC = 0.2; // small jitter buffer before (re)starting playback
      const AUDIO_RECONNECT_MS = 2000;

      let audioCtx = null;
      let nextStartTime = 0;
      let audioReconnectTimer = null;

      function ensureAudioContext() {
        if (audioCtx) return audioCtx;
        const Ctx = window.AudioContext || window.webkitAudioContext;
        if (!Ctx) return null;
        audioCtx = new Ctx({ sampleRate: AUDIO_SAMPLE_RATE });
        return audioCtx;
      }

      function handleAudioChunk(arrayBuffer) {
        const ctx = ensureAudioContext();
        if (!ctx) return;
        if (ctx.state === "suspended") {
          ctx.resume().catch(() => {});
        }

        const samples = new Int16Array(arrayBuffer);
        const frameCount = Math.floor(samples.length / AUDIO_CHANNELS);
        if (frameCount <= 0) return;

        const audioBuffer = ctx.createBuffer(AUDIO_CHANNELS, frameCount, AUDIO_SAMPLE_RATE);
        for (let channel = 0; channel < AUDIO_CHANNELS; channel++) {
          const channelData = audioBuffer.getChannelData(channel);
          for (let i = 0; i < frameCount; i++) {
            channelData[i] = samples[i * AUDIO_CHANNELS + channel] / 32768;
          }
        }

        const source = ctx.createBufferSource();
        source.buffer = audioBuffer;
        source.connect(ctx.destination);

        const now = ctx.currentTime;
        if (nextStartTime < now + 0.02) {
          // First chunk ever, or playback fell behind (underrun) — resync with a
          // small lead instead of trying to catch up sample-by-sample.
          nextStartTime = now + AUDIO_LEAD_SEC;
        }
        source.start(nextStartTime);
        nextStartTime += audioBuffer.duration;
      }

      function connectAudioStream() {
        const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
        const ws = new WebSocket(`${proto}//${window.location.host}/audio-stream`);
        ws.binaryType = "arraybuffer";

        ws.onopen = () => {
          nextStartTime = 0;
        };
        ws.onmessage = (event) => handleAudioChunk(event.data);
        ws.onclose = scheduleAudioReconnect;
        ws.onerror = () => ws.close();
      }

      function scheduleAudioReconnect() {
        if (audioReconnectTimer) return;
        audioReconnectTimer = setTimeout(() => {
          audioReconnectTimer = null;
          connectAudioStream();
        }, AUDIO_RECONNECT_MS);
      }

      connectAudioStream();
      // Real browsers gate audio behind a user gesture; OBS's Browser Source
      // does not, but this keeps manual testing in an actual browser tab working.
      document.addEventListener("click", () => {
        if (audioCtx && audioCtx.state === "suspended") audioCtx.resume().catch(() => {});
      }, { once: true });
    })();
    """#
}
