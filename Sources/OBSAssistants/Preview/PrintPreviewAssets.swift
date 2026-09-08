import Foundation

/// The "Preview 3D" overlay page — deliberately simple: a full-bleed render
/// of the sliced plate (whatever Bambu Studio itself already produced for
/// `Metadata/plate_1.png`), with a small caption bar. No live toolpath
/// animation — see PrintPreviewHTTPServer's doc comment and the README for
/// why (no G-code embedded in a plain "Save Project" `.3mf`). Polls
/// `/preview.png` on an interval so a new print's preview replaces the old
/// one without needing the Browser Source reloaded by hand.
enum PrintPreviewAssets {
    static let html = """
    <!DOCTYPE html>
    <html lang="pt-BR">
    <head>
    <meta charset="UTF-8">
    <title>OBS Assistants — Preview 3D</title>
    <link rel="stylesheet" href="/overlay.css">
    </head>
    <body>
      <div id="stage">
        <img id="preview" alt="Prévia do resultado esperado">
        <div id="empty">
          <div id="empty-icon">🖨️</div>
          <div id="empty-text">Nenhuma prévia disponível ainda</div>
          <div id="empty-hint">Fatie um projeto no Bambu Studio na pasta configurada</div>
        </div>
      </div>
      <div id="caption" hidden>
        <span id="caption-label">Resultado esperado</span>
      </div>
      <script src="/overlay.js"></script>
    </body>
    </html>
    """

    static let css = """
    :root {
      color-scheme: dark;
    }
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background: transparent;
      overflow: hidden;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    #stage {
      position: relative;
      width: 100%;
      height: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    #preview {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
      border-radius: 10px;
      box-shadow: 0 4px 24px rgba(0, 0, 0, 0.35);
      display: none;
    }
    #preview.loaded {
      display: block;
    }
    #empty {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 6px;
      color: rgba(255, 255, 255, 0.55);
      text-align: center;
      padding: 24px;
      background: rgba(20, 20, 24, 0.55);
      border-radius: 12px;
    }
    #empty-icon {
      font-size: 32px;
      opacity: 0.7;
    }
    #empty-text {
      font-size: 13px;
      font-weight: 600;
    }
    #empty-hint {
      font-size: 11px;
      opacity: 0.7;
    }
    #caption {
      position: absolute;
      left: 14px;
      bottom: 14px;
      display: flex;
      flex-direction: column;
      gap: 1px;
      padding: 6px 10px;
      background: rgba(20, 20, 24, 0.6);
      border-radius: 8px;
      color: rgba(255, 255, 255, 0.85);
      backdrop-filter: blur(6px);
    }
    #caption-label {
      font-size: 10px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      opacity: 0.8;
    }
    """

    /// Polls `/preview.png` every 5s (cache-busted via a query param —
    /// browsers otherwise happily cache a 200 OK image response). On
    /// success shows the image and reveals the caption; on failure (404 —
    /// no preview yet) shows the empty-state placeholder instead, same
    /// spirit as the other overlays never leaving stale data on screen.
    static let js = """
    const img = document.getElementById("preview");
    const empty = document.getElementById("empty");
    const caption = document.getElementById("caption");

    function poll() {
      const probe = new Image();
      probe.onload = () => {
        img.src = probe.src;
        img.classList.add("loaded");
        empty.style.display = "none";
        caption.hidden = false;
      };
      probe.onerror = () => {
        img.classList.remove("loaded");
        empty.style.display = "flex";
        caption.hidden = true;
      };
      probe.src = "/preview.png?t=" + Date.now();
    }

    poll();
    setInterval(poll, 5000);
    """
}
