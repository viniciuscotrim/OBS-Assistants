import Foundation

/// The overlay page (HTML/CSS/JS) is embedded directly as Swift string
/// constants instead of shipped as a separate SwiftPM resource bundle.
///
/// Why: `swift build`'s generated `Bundle.module` accessor looks for
/// `OBSAssistants_OBSAssistants.bundle` at the *root* of
/// `Bundle.main.bundleURL` (i.e. next to `Contents/`, not inside
/// `Contents/Resources`) when running from an app bundle — an easy thing to
/// get subtly wrong when hand-assembling the .app in build_dmg.sh for
/// ad-hoc signing. Embedding the (small, text-only) overlay assets as
/// compiled-in constants sidesteps that whole failure mode: there is
/// nothing to misplace, and the built binary is fully self-contained.
///
/// Keep these in sync with what you see in a browser when iterating — the
/// content below is plain HTML/CSS/JS, easiest edited by temporarily pasting
/// it into standalone .html/.css/.js files, then back in here.
enum OverlayAssets {
    static let html = #"""
    <!DOCTYPE html>
    <html lang="pt-BR">
    <head>
    <meta charset="UTF-8">
    <title>OBS Assistants</title>
    <link rel="stylesheet" href="overlay.css">
    </head>
    <body>
      <div id="overlay" class="theme-dark">
        <div id="content"></div>
        <div id="offline" class="offline" hidden>Impressora desconectada</div>
      </div>
      <script src="overlay.js"></script>
    </body>
    </html>
    """#

    static let css = #"""
    /* OBS Assistants — overlay page for OBS Browser Source.
       Themes are toggled via a class on #overlay, set by overlay.js from the
       ?theme= query param: dark (default), twitch, transparent. */

    * { box-sizing: border-box; }

    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background: transparent;
      font-family: -apple-system, "Segoe UI", "Inter", Roboto, sans-serif;
    }

    /* `display: block` + `width: 100%` (not the old `inline-flex`) is the
       fix for tiles stacking into a single column in OBS: an inline-flex
       box shrink-wraps to its content's width, so the .grid below never
       gets the Browser Source's actual width to lay tiles out across —
       every tile ends up alone on its own row. Block + 100% gives .grid
       real width to auto-fill columns into. */
    #overlay {
      display: block;
      width: 100%;
      box-sizing: border-box;
      padding: 14px;
    }

    .group {
      margin-bottom: 10px;
    }
    .group:last-child {
      margin-bottom: 0;
    }
    .group-label {
      font-size: calc(10px * var(--text-scale, 1));
      letter-spacing: 0.06em;
      text-transform: uppercase;
      opacity: 0.55;
      margin: 0 0 6px 2px;
    }

    .grid {
      display: grid;
      /* Box width is --box-width-scale (the "X" slider), independent of
         --text-scale — the two used to be coupled here, so making the box
         wider always made the text bigger too and vice versa. */
      grid-template-columns: repeat(auto-fill, minmax(calc(var(--tile-min-width, 150px) * var(--box-width-scale, 1)), 1fr));
      gap: 8px;
    }

    .tile {
      display: flex;
      flex-direction: column;
      gap: 2px;
      /* Vertical padding is --box-height-scale (the "Y" slider) — grows the
         box's height by adding breathing room above/below the text, rather
         than a fixed min-height that would leave dead empty space. */
      padding: calc(8px * var(--box-height-scale, 1)) calc(12px * var(--box-width-scale, 1));
      border-radius: 10px;
      min-width: 0; /* let flex/grid actually shrink the tile — a min-width
                       here would fight the auto-fit-text logic in JS,
                       which needs the tile's *real* available width. */
      overflow: hidden;
    }

    /* Both label and value are single-line. When auto-fit is on (the
       default — toggle in the app), overlay.js shrinks (CSS `scale`)
       whichever of the two doesn't fit at this size, so a long value (a
       long gcode filename, a wide composite like "42% · 87min restantes")
       stays fully readable on one line instead of getting cut off.

       No `overflow: hidden` here by default, and deliberately no
       `text-overflow: ellipsis` either — both are layout/paint-time
       effects that would clip or truncate the text *before* a later
       `scale` transform ever runs. `transform` only shrinks whatever
       already got painted, it can't "unclip" content another rule already
       cut away — so combining them silently scaled down an already-cut
       "…" instead of the full value. The parent .tile keeps its own
       `overflow: hidden` as a backstop (belt-and-suspenders in case the
       scale math is ever off by a hair), which is enough since a
       correctly-scaled label/value fits inside it by construction.

       Ellipsis-instead-of-shrink only comes back via the
       .ellipsis-fallback class overlay.js adds when auto-fit is turned
       off in the app. */
    .tile .label,
    .tile .value {
      white-space: nowrap;
      transform-origin: left center;
      max-width: 100%;
    }

    #overlay.ellipsis-fallback .tile .label,
    #overlay.ellipsis-fallback .tile .value {
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .tile .label {
      font-size: calc(11px * var(--text-scale, 1));
      letter-spacing: 0.04em;
      text-transform: uppercase;
      opacity: 0.72;
    }

    .tile .value {
      font-size: calc(20px * var(--text-scale, 1));
      font-weight: 700;
      font-variant-numeric: tabular-nums;
    }

    .offline {
      padding: 8px 12px;
      border-radius: 10px;
      font-size: 13px;
      font-weight: 600;
    }

    /* ---------- Theme: dark (default) ---------- */
    #overlay.theme-dark {
      color: #f4f4f5;
    }
    #overlay.theme-dark .tile {
      background: rgba(20, 20, 24, 0.72);
      box-shadow: 0 2px 10px rgba(0, 0, 0, 0.35);
    }
    #overlay.theme-dark .value { color: #4ade80; }
    #overlay.theme-dark .offline {
      background: rgba(127, 29, 29, 0.85);
      color: #fecaca;
    }

    /* ---------- Theme: twitch (Twitch-purple accent) ---------- */
    #overlay.theme-twitch {
      color: #efeff1;
    }
    #overlay.theme-twitch .tile {
      background: rgba(24, 12, 33, 0.82);
      border: 1px solid rgba(145, 71, 255, 0.55);
      box-shadow: 0 2px 12px rgba(100, 30, 200, 0.35);
    }
    #overlay.theme-twitch .label { color: #c9a6ff; }
    #overlay.theme-twitch .value { color: #9147ff; }
    #overlay.theme-twitch .offline {
      background: rgba(80, 20, 60, 0.85);
      color: #ffd1f0;
      border: 1px solid rgba(255, 71, 145, 0.6);
    }

    /* ---------- Theme: transparent (no chrome, text only) ---------- */
    #overlay.theme-transparent {
      color: #ffffff;
    }
    #overlay.theme-transparent .tile {
      background: transparent;
      padding: 4px 8px;
    }
    #overlay.theme-transparent .value {
      color: #ffffff;
      text-shadow: 0 1px 4px rgba(0, 0, 0, 0.9), 0 0 2px rgba(0, 0, 0, 0.9);
    }
    #overlay.theme-transparent .label {
      text-shadow: 0 1px 3px rgba(0, 0, 0, 0.9);
    }
    #overlay.theme-transparent .offline {
      background: transparent;
      color: #ff8080;
      text-shadow: 0 1px 4px rgba(0, 0, 0, 0.9);
    }
    """#

    static let js = #"""
    // OBS Assistants overlay — polls the local /status endpoint served by
    // the macOS app and renders only the fields marked "visible" in the app's
    // menu-bar UI, in the order chosen there. Query params:
    //   ?theme=dark|twitch|transparent   (default: dark)
    //   ?interval=1500                   (poll interval in ms, default 1500)
    //   ?grouped=0                       (disable category grouping — one flat grid)
    //   ?tilewidth=150                   (px — minimum tile width the grid wraps at)
    //   ?columns=4                       (force an exact column count instead of
    //                                     auto-fill-by-width; overrides tilewidth)
    //   ?boxwidth=1.0 / ?boxheight=1.0   (independent box size multipliers —
    //                                     the "Tamanho da caixa (X/Y)" sliders)
    //   ?statusurl=/studio-status        (poll a different JSON source — used by
    //                                     the "Overlay Bambu Studio" URL)

    (function () {
      const params = new URLSearchParams(window.location.search);
      // theme/textscale: the URL value, if explicitly present, always wins
      // (lets one OBS source pin a specific look). Otherwise every poll
      // uses whatever the app's menu currently has set (data.settings,
      // below) — this is what makes the "Tamanho do texto" slider and
      // theme picker actually take effect live in OBS, instead of only
      // ever reflecting whatever the URL happened to say when it was last
      // copied into the Browser Source.
      const urlTheme = params.has("theme") ? params.get("theme") : null;
      const urlTextScale = params.has("textscale") ? parseFloat(params.get("textscale")) : null;
      const urlAutoFit = params.has("autofit") ? params.get("autofit") !== "0" : null;
      const urlBoxWidthScale = params.has("boxwidth") ? parseFloat(params.get("boxwidth")) : null;
      const urlBoxHeightScale = params.has("boxheight") ? parseFloat(params.get("boxheight")) : null;
      const interval = Math.max(500, parseInt(params.get("interval") || "1500", 10));
      const grouped = params.get("grouped") !== "0";
      const tileWidth = Math.max(60, parseInt(params.get("tilewidth") || "150", 10));
      const columnsParam = params.get("columns");
      const columns = columnsParam ? Math.max(1, parseInt(columnsParam, 10)) : null;
      // Same overlay page, pointed at a different JSON source — used for
      // the separate "Overlay Bambu Studio" (slicing details) source,
      // which is served at /studio-status instead of /status but has the
      // exact same {fields, settings} shape, so nothing else here changes.
      const statusURL = params.get("statusurl") || "/status";

      const overlayEl = document.getElementById("overlay");
      const contentEl = document.getElementById("content");
      const offlineEl = document.getElementById("offline");

      document.documentElement.style.setProperty("--tile-min-width", tileWidth + "px");
      let autoFitEnabled = true;
      applyDisplaySettings({});

      let consecutiveFailures = 0;

      function applyDisplaySettings(liveSettings) {
        const theme = urlTheme || liveSettings.theme || "dark";
        const rawScale = urlTextScale !== null && !isNaN(urlTextScale)
          ? urlTextScale
          : (typeof liveSettings.textScale === "number" ? liveSettings.textScale : 1);
        const textScale = Math.min(3, Math.max(0.4, rawScale || 1));
        autoFitEnabled = urlAutoFit !== null ? urlAutoFit : (liveSettings.autoFit !== false);
        const rawBoxWidth = urlBoxWidthScale !== null && !isNaN(urlBoxWidthScale)
          ? urlBoxWidthScale
          : (typeof liveSettings.boxWidthScale === "number" ? liveSettings.boxWidthScale : 1);
        const rawBoxHeight = urlBoxHeightScale !== null && !isNaN(urlBoxHeightScale)
          ? urlBoxHeightScale
          : (typeof liveSettings.boxHeightScale === "number" ? liveSettings.boxHeightScale : 1);
        const boxWidthScale = Math.min(3, Math.max(0.4, rawBoxWidth || 1));
        const boxHeightScale = Math.min(3, Math.max(0.4, rawBoxHeight || 1));

        overlayEl.classList.remove("theme-dark", "theme-twitch", "theme-transparent");
        overlayEl.classList.add("theme-" + (["dark", "twitch", "transparent"].includes(theme) ? theme : "dark"));
        overlayEl.classList.toggle("ellipsis-fallback", !autoFitEnabled);
        document.documentElement.style.setProperty("--text-scale", String(textScale));
        document.documentElement.style.setProperty("--box-width-scale", String(boxWidthScale));
        document.documentElement.style.setProperty("--box-height-scale", String(boxHeightScale));
      }

      async function poll() {
        try {
          const res = await fetch(statusURL, { cache: "no-store" });
          if (!res.ok) throw new Error("HTTP " + res.status);
          const data = await res.json();
          consecutiveFailures = 0;
          render(data);
        } catch (err) {
          consecutiveFailures += 1;
          if (consecutiveFailures >= 3) {
            showOffline(true);
          }
        } finally {
          setTimeout(poll, interval);
        }
      }

      function render(data) {
        applyDisplaySettings(data.settings || {});

        const connected = !!data.connected;
        showOffline(!connected);

        const fields = Array.isArray(data.fields) ? data.fields : [];
        // /status already lists visible fields first, in the order chosen
        // in the app — filter() preserves that order.
        const visible = fields.filter((f) => f.visible);

        contentEl.innerHTML = "";

        if (!grouped) {
          contentEl.appendChild(buildGrid(visible));
        } else {
          // Group by category, preserving each category's first-appearance
          // order (which itself follows the user's chosen field order) —
          // not alphabetical, so it stays predictable as fields are added.
          const order = [];
          const byCategory = new Map();
          for (const field of visible) {
            const category = field.category || "Outros";
            if (!byCategory.has(category)) {
              byCategory.set(category, []);
              order.push(category);
            }
            byCategory.get(category).push(field);
          }

          for (const category of order) {
            const groupEl = document.createElement("div");
            groupEl.className = "group";

            const labelEl = document.createElement("div");
            labelEl.className = "group-label";
            labelEl.textContent = category;
            groupEl.appendChild(labelEl);

            groupEl.appendChild(buildGrid(byCategory.get(category)));
            contentEl.appendChild(groupEl);
          }
        }

        // Auto-fit (default on, toggle in the app): shrink any label/value
        // that still overflows its tile at the current base text size (a
        // long gcode filename, a wide composite like "42% · 87min
        // restantes") so it shows in full instead of getting cut off. Off:
        // just clear any leftover transform and let the CSS
        // .ellipsis-fallback class (set in applyDisplaySettings) truncate
        // with "…" instead. Called synchronously, not via
        // requestAnimationFrame: reading clientWidth/scrollWidth already
        // forces the browser to flush layout on the spot, so rAF added
        // nothing but a scheduling step that (at least in some embedded/
        // automated browser contexts, possibly including OBS's Browser
        // Source under some conditions) doesn't reliably fire — verified
        // by hand that the exact same fit logic runs fine synchronously.
        const textEls = contentEl.querySelectorAll(".label, .value");
        if (autoFitEnabled) {
          textEls.forEach(fitTextToTile);
        } else {
          textEls.forEach((el) => { el.style.transform = "none"; });
        }
      }

      function fitTextToTile(el) {
        el.style.transform = "none";
        const available = el.clientWidth;
        const natural = el.scrollWidth;
        if (available > 0 && natural > available) {
          // Deliberately no minimum floor: a floor means "shrink, but only
          // so far" — which is exactly what caused the earlier bug (a
          // floor of 0.55 was sometimes bigger than the scale actually
          // needed to fit, so the text still overflowed and got clipped by
          // `overflow: hidden`, looking just like the ellipsis it was
          // supposed to replace). The point is showing the full value, so
          // fitting always wins over staying above some minimum size.
          const scale = available / natural;
          el.style.transform = "scale(" + scale.toFixed(3) + ")";
        }
      }

      function buildGrid(fieldList) {
        const gridEl = document.createElement("div");
        gridEl.className = "grid";
        if (columns) {
          gridEl.style.gridTemplateColumns = "repeat(" + columns + ", 1fr)";
        }
        for (const field of fieldList) {
          const tile = document.createElement("div");
          tile.className = "tile";

          const label = document.createElement("div");
          label.className = "label";
          label.textContent = field.label || field.key;

          const value = document.createElement("div");
          value.className = "value";
          value.textContent = formatValue(field.value);

          tile.appendChild(label);
          tile.appendChild(value);
          gridEl.appendChild(tile);
        }
        return gridEl;
      }

      function formatValue(raw) {
        if (raw === "" || raw === null || raw === undefined) return "—";
        return String(raw);
      }

      function showOffline(isOffline) {
        offlineEl.hidden = !isOffline;
      }

      poll();
    })();
    """#
}
