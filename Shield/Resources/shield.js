// Shield: script inyectado al inicio de cada documento (todos los frames).
// Complementa las reglas de red de WKContentRuleList con lo que no se puede
// bloquear por URL: anuncios de vídeo de YouTube que vienen en la misma respuesta.
(function () {
  if (window.__shieldInjected) return;
  window.__shieldInjected = true;

  var removed = 0;
  function report() {
    try { window.webkit.messageHandlers.shield.postMessage({ hidden: removed }); } catch (e) {}
  }
  function addStyle(css) {
    var style = document.createElement('style');
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  }

  var host = location.hostname;

  function post(msg) {
    try { window.webkit.messageHandlers.shield.postMessage(msg); } catch (e) {}
  }
  function abs(u) {
    try { return new URL(String(u), location.href).href; } catch (e) { return ''; }
  }
  function baseDomain(h) {
    h = (h || '').toLowerCase().replace(/^www\./, '');
    var p = h.split('.');
    if (p.length <= 2) return h;
    var twoLevel = /^(co|com|net|org|gov|gob|edu|ac|nic|or|ne|go|mil)$/.test(p[p.length - 2]) &&
                   p[p.length - 1].length === 2;
    return p.slice(twoLevel ? -3 : -2).join('.');
  }
  function sameSite(u) {
    try { return baseDomain(new URL(u, location.href).hostname) === baseDomain(location.hostname); }
    catch (e) { return false; }
  }

  // ---------- Pop-ups, pop-unders y capas invisibles ----------
  // Truco típico: un enlace/capa transparente encima de la página que "roba"
  // el primer toque para abrir un anuncio. Lo detectamos, lo desactivamos y
  // reenviamos el toque al elemento real que hay debajo (p. ej. la imagen).
  var lastTap = { target: null, link: null, x: 0, y: 0, time: 0 };
  function onTap(e) {
    var t = e.touches && e.touches[0] ? e.touches[0] : e;
    var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    lastTap = { target: e.target, link: a ? a.href : null, x: t.clientX, y: t.clientY, time: Date.now() };
  }
  window.addEventListener('touchstart', onTap, { capture: true, passive: true });
  window.addEventListener('pointerdown', onTap, true);

  function recentTap() { return Date.now() - lastTap.time < 1500; }

  function isOverlay(el) {
    if (!el || el === document.body || el === document.documentElement || !el.getBoundingClientRect) return false;
    if (/^(IMG|VIDEO|AUDIO|PICTURE|SVG|CANVAS|IFRAME|INPUT|BUTTON|TEXTAREA|SELECT|LABEL)$/i.test(el.tagName)) return false;
    var r = el.getBoundingClientRect();
    var cs = getComputedStyle(el);
    var big = r.width * r.height >= 0.35 * innerWidth * innerHeight;
    var positioned = cs.position === 'fixed' || cs.position === 'absolute';
    var invisible = parseFloat(cs.opacity) < 0.1 || cs.visibility === 'hidden' ||
      (!el.textContent.trim() && !el.querySelector('img,video,picture,svg,canvas') &&
       cs.backgroundImage === 'none' && coversMedia(el, r));
    return (big && positioned && (el.tagName === 'A' || !el.textContent.trim())) || invisible;
  }

  // ¿Hay una imagen/vídeo justo debajo del elemento? (capa transparente encima)
  function coversMedia(el, r) {
    if (!document.elementsFromPoint || !r.width || !r.height) return false;
    var list = document.elementsFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    for (var i = 0; i < list.length; i++) {
      var b = list[i];
      if (b === el || el.contains(b)) continue;
      if (/^(IMG|VIDEO|PICTURE|CANVAS)$/i.test(b.tagName)) return true;
      return b.tagName === 'A' && !!b.querySelector('img,video');
    }
    return false;
  }

  // Desactiva la capa que recibió el toque y reenvía el clic a lo que hay debajo.
  function passThrough() {
    if (!recentTap() || !lastTap.target) return;
    var t = lastTap.target;
    var layer = (t.closest && t.closest('a[href]')) || t;
    if (!isOverlay(layer)) return;
    layer.style.setProperty('pointer-events', 'none', 'important');
    var x = lastTap.x, y = lastTap.y;
    lastTap.time = 0;
    setTimeout(function () {
      var below = document.elementFromPoint(x, y);
      if (below && below !== layer && !layer.contains(below)) below.click();
    }, 0);
  }

  function popupAllowed(url) {
    if (!url || url === 'about:blank') return false;
    if (sameSite(url)) return true;
    // enlace externo que el usuario tocó de verdad (y no es una capa invisible)
    return recentTap() && lastTap.link === url && !!lastTap.target && !!lastTap.target.closest &&
      !isOverlay(lastTap.target.closest('a[href]'));
  }
  function blockPopup(url) {
    post({ popupBlocked: url || 'about:blank' });
    passThrough();
  }
  function fakeWindow() {
    var noop = function () {};
    var w = { closed: false, opener: window, focus: noop, blur: noop, postMessage: noop,
      moveTo: noop, resizeTo: noop,
      document: { write: noop, writeln: noop, open: noop, close: noop, body: null },
      location: { href: 'about:blank', assign: noop, replace: noop } };
    w.close = function () { w.closed = true; };
    w.window = w; w.self = w;
    return w;
  }

  var nativeOpen = window.open;
  window.open = function (url) {
    var u = url ? abs(url) : '';
    if (popupAllowed(u)) {
      post({ allowPopup: u });
      return nativeOpen.apply(window, arguments);
    }
    blockPopup(u);
    return fakeWindow();   // el script cree que lo consiguió y no reintenta
  };
  window.open.toString = function () { return 'function open() { [native code] }'; };

  function blankAnchor(a) {
    return a && a.tagName === 'A' && a.href && /^_(blank|new)$|^[^_]/.test(a.target || '_self');
  }
  // Clics sintéticos sobre enlaces (a.click() / dispatchEvent) que abren anuncios
  var nativeClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (blankAnchor(this) && !popupAllowed(this.href)) { blockPopup(this.href); return; }
    if (blankAnchor(this)) post({ allowPopup: this.href });
    return nativeClick.apply(this, arguments);
  };
  var nativeDispatch = EventTarget.prototype.dispatchEvent;
  EventTarget.prototype.dispatchEvent = function (ev) {
    if (ev && ev.type === 'click' && blankAnchor(this) && !popupAllowed(this.href)) {
      blockPopup(this.href);
      return false;
    }
    return nativeDispatch.apply(this, arguments);
  };
  // Clics reales del usuario
  window.addEventListener('click', function (e) {
    var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a || /^(javascript|#)/i.test(a.getAttribute('href') || '')) return;
    if (!sameSite(a.href) && isOverlay(a)) {
      e.preventDefault();
      e.stopImmediatePropagation();
      blockPopup(a.href);
      return;
    }
    if (blankAnchor(a)) post({ allowPopup: a.href });
  }, true);

  // ---------- Capas flotantes insertadas por scripts de anuncios ----------
  // "In-page push", falsas alertas del sistema, interstitials, banners pegados...
  // Las redes cambian de dominio a diario, así que no se identifican por nombre
  // sino por comportamiento: si un script de un dominio externo desconocido
  // cuelga del <body> un elemento flotante (fixed / absolute con z-index alto),
  // se elimina. Los scripts del propio sitio y de CDNs/servicios conocidos no se tocan.
  var TRUSTED_3P = new RegExp('(^|\\.)(googleapis|gstatic|google|recaptcha|hcaptcha|cloudflare|' +
    'jsdelivr|cdnjs|unpkg|jquery|bootstrapcdn|youtube|ytimg|vimeo|twitter|twimg|x|facebook|' +
    'fbcdn|instagram|disqus|stripe|paypal|apple|icloud|microsoft|cookiebot|onetrust|cookielaw|' +
    'didomi|usercentrics|quantcast|consensu|trustarc|iubenda|osano|termly|intercom|tawk|' +
    'zendesk|crisp|freshchat|hubspot|shopify|wix|squarespace|mercadopago|mercadolibre)\\.[a-z.]+$', 'i');

  function thirdPartyCaller() {
    var lines = ((new Error()).stack || '').split('\n');
    for (var i = 0; i < lines.length; i++) {
      // WebKit: "fn@https://x/y.js:1:2"  ·  Chromium: "at fn (https://x/y.js:1:2)"
      var m = lines[i].match(/(https?:\/\/[^\s()@]+?)(?::\d+)+\)?\s*$/);
      if (!m) continue;
      var u = m[1];
      if (sameSite(u)) continue;
      var h = '';
      try { h = new URL(u).hostname; } catch (e) { continue; }
      if (TRUSTED_3P.test(h)) continue;
      return u;
    }
    return null;
  }

  function isFloating(el) {
    var cs = getComputedStyle(el);
    if (cs.display === 'none') return false;
    var z = parseInt(cs.zIndex, 10) || 0;
    return cs.position === 'fixed' || (cs.position === 'absolute' && z >= 100);
  }
  function isAdLayer(el) {
    if (isFloating(el)) return true;
    if (el.tagName === 'IFRAME') {
      var r = el.getBoundingClientRect();
      return r.width * r.height > 5000 && !sameSite(el.src || '');
    }
    var roots = [el];
    if (el.shadowRoot) roots.push(el.shadowRoot);
    for (var i = 0; i < roots.length; i++) {
      var kids = roots[i].querySelectorAll('*');
      for (var j = 0; j < kids.length && j < 60; j++) {
        if (isFloating(kids[j])) return true;
      }
    }
    return false;
  }
  function judge(el) {
    if (!el.isConnected || el.__shieldRemoved) return;
    if (!isAdLayer(el)) return;
    el.__shieldRemoved = true;
    el.remove();
    removed++;
    report();
    // Algunas capas bloquean el scroll de la página
    [document.documentElement, document.body].forEach(function (n) {
      if (n && n.style.overflow === 'hidden') n.style.overflow = '';
    });
  }
  function watchInsert(parent, node) {
    if (!node || node.nodeType !== 1 || node.__shield3p) return;
    if (parent !== document.body && parent !== document.documentElement) return;
    var src = thirdPartyCaller();
    if (!src) return;
    node.__shield3p = src;
    [0, 250, 1000, 2500, 6000, 12000].forEach(function (ms) {
      setTimeout(function () { judge(node); }, ms);
    });
  }
  function hook(proto, name, parentOf, nodesOf) {
    var orig = proto[name];
    if (!orig) return;
    proto[name] = function () {
      try {
        var nodes = nodesOf(arguments);
        var parent = parentOf(this, arguments);
        for (var i = 0; i < nodes.length; i++) watchInsert(parent, nodes[i]);
      } catch (e) {}
      return orig.apply(this, arguments);
    };
  }
  var self = function (t) { return t; };
  var parentNode = function (t) { return t.parentNode; };
  var first = function (a) { return [a[0]]; };
  var all = function (a) { return Array.prototype.slice.call(a); };
  hook(Node.prototype, 'appendChild', self, first);
  hook(Node.prototype, 'insertBefore', self, first);
  hook(Node.prototype, 'replaceChild', self, first);
  hook(Element.prototype, 'append', self, all);
  hook(Element.prototype, 'prepend', self, all);
  hook(Element.prototype, 'before', parentNode, all);
  hook(Element.prototype, 'after', parentNode, all);
  hook(Element.prototype, 'insertAdjacentElement', function (t, a) {
    return /^(beforebegin|afterend)$/i.test(a[0]) ? t.parentNode : t;
  }, function (a) { return [a[1]]; });

  // Las redes esconden sus anuncios en shadow DOM "cerrado" para que los
  // bloqueadores no los vean: si lo pide un script externo, se abre.
  var nativeAttachShadow = Element.prototype.attachShadow;
  if (nativeAttachShadow) {
    Element.prototype.attachShadow = function (init) {
      if (init && init.mode === 'closed' && thirdPartyCaller()) {
        init = { mode: 'open', delegatesFocus: !!init.delegatesFocus };
      }
      return nativeAttachShadow.call(this, init);
    };
  }

  // ---------- Detector de vídeos, audios e imágenes ----------
  var VIDEO_EXT = /\.(mp4|m4v|mov|webm|mkv|m3u8)(\?|#|$)/i;
  var AUDIO_EXT = /\.(mp3|m4a|aac|ogg|opus|wav|flac)(\?|#|$)/i;
  var IMAGE_EXT = /\.(jpe?g|png|gif|webp|avif|heic|bmp)(\?|#|$)/i;
  var seen = {};
  var lastHLS = null;   // última lista .m3u8 vista en este frame (reproductores hls.js)
  var queue = [];
  var flushTimer = null;
  function addMedia(kind, url, extra) {
    url = abs(url);
    if (!url || /^(blob|data|about|javascript):/i.test(url)) return;
    var key = kind + url;
    if (seen[key]) return;
    seen[key] = 1;
    var item = { kind: kind, url: url, page: location.href, hls: /\.m3u8(\?|#|$)/i.test(url) };
    if (extra) for (var k in extra) item[k] = extra[k];
    if (item.hls) lastHLS = url;
    queue.push(item);
    if (!flushTimer) flushTimer = setTimeout(function () {
      flushTimer = null;
      if (queue.length) post({ media: queue.splice(0, queue.length) });
    }, 400);
  }
  function kindForURL(u) {
    if (VIDEO_EXT.test(u)) return 'video';
    if (AUDIO_EXT.test(u)) return 'audio';
    if (IMAGE_EXT.test(u)) return 'image';
    return null;
  }
  try { performance.setResourceTimingBufferSize(5000); } catch (e) {}

  function scan() {
    var i, j, list;
    list = document.querySelectorAll('video, audio');
    for (i = 0; i < list.length; i++) {
      var v = list[i];
      var kind = v.tagName === 'AUDIO' ? 'audio' : 'video';
      var extra = { poster: v.poster ? abs(v.poster) : null };
      addMedia(kind, v.currentSrc, extra);
      addMedia(kind, v.getAttribute('src'), extra);
      var sources = v.querySelectorAll('source[src]');
      for (j = 0; j < sources.length; j++) addMedia(kind, sources[j].getAttribute('src'), extra);
      if (v.poster) addMedia('image', v.poster);
    }
    list = document.images;
    for (i = 0; i < list.length; i++) {
      var img = list[i];
      if (img.naturalWidth >= 120 && img.naturalHeight >= 120) {
        addMedia('image', img.currentSrc || img.src, { width: img.naturalWidth, height: img.naturalHeight });
      }
      var lazy = img.getAttribute('data-src') || img.getAttribute('data-original') || img.getAttribute('data-full');
      if (lazy) addMedia('image', lazy);
    }
    list = document.querySelectorAll('a[href]');
    for (i = 0; i < list.length; i++) {
      var k = kindForURL(list[i].href);
      if (k) addMedia(k, list[i].href);
    }
    list = document.querySelectorAll('meta[property^="og:video"], meta[property="og:image"], meta[name="twitter:player:stream"]');
    for (i = 0; i < list.length; i++) {
      var c = list[i].getAttribute('content');
      if (!c) continue;
      addMedia(/image/.test(list[i].getAttribute('property') || '') ? 'image' : (kindForURL(c) || 'video'), c);
    }
    var entries = performance.getEntriesByType ? performance.getEntriesByType('resource') : [];
    for (i = 0; i < entries.length; i++) {
      var n = entries[i].name;
      var kk = kindForURL(n);
      if (kk === 'video' || kk === 'audio') addMedia(kk, n);
    }
    // reenviar el escaneo a los iframes (reproductores incrustados)
    for (i = 0; i < window.frames.length; i++) {
      try { window.frames[i].postMessage({ __shieldScan: 1 }, '*'); } catch (e) {}
    }
  }
  window.__shieldScan = scan;

  // ---------- Reproductor nativo del iPhone ----------
  // Al pulsar play en un vídeo de la web se pausa y se abre en AVPlayer
  // (con descarga, Picture in Picture y AirPlay), sea cual sea el reproductor.
  window.__shieldSetNative = function (on) {
    window.__shieldNativePlayer = !!on;
    for (var i = 0; i < window.frames.length; i++) {
      try { window.frames[i].postMessage({ __shieldNative: !!on }, '*'); } catch (e) {}
    }
  };
  window.addEventListener('message', function (e) {
    if (e.data && typeof e.data.__shieldNative === 'boolean') window.__shieldSetNative(e.data.__shieldNative);
  });
  function playableSource(v) {
    var src = v.currentSrc || v.src || '';
    if (!src || /^blob:/i.test(src)) {
      var s = v.querySelector('source[src]');
      src = s ? abs(s.getAttribute('src')) : '';
    }
    if (!src || /^blob:/i.test(src)) src = lastHLS || '';   // hls.js / MSE
    return /^https?:/i.test(src) ? src : '';
  }
  document.addEventListener('play', function (e) {
    var v = e.target;
    if (!window.__shieldNativePlayer || !v || v.tagName !== 'VIDEO') return;
    if (!recentTap()) return;               // sólo si lo pidió el usuario (no autoplay)
    var src = playableSource(v);
    if (!src) return;                       // sin URL utilizable: se queda el de la web
    v.pause();
    lastTap.time = 0;
    post({ nativePlay: src, poster: v.poster ? abs(v.poster) : null, page: location.href,
           time: v.currentTime || 0, title: document.title || '', hls: /\.m3u8(\?|#|$)/i.test(src) || src === lastHLS });
  }, true);
  window.addEventListener('message', function (e) {
    if (e.data && e.data.__shieldScan) scan();
  });
  ['play', 'loadedmetadata', 'loadeddata'].forEach(function (type) {
    document.addEventListener(type, function () { scan(); }, true);
  });
  window.addEventListener('load', function () { scan(); });

  // Listas HLS (.m3u8) cargadas por reproductores JS sin extensión reconocible
  function checkType(url, type) {
    if (type && /mpegurl/i.test(type)) addMedia('video', url, { hls: true });
    else if (type && /^video\//i.test(type)) addMedia('video', url);
  }
  var nativeXHROpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    var xhr = this;
    try {
      xhr.addEventListener('load', function () {
        try { checkType(abs(url), xhr.getResponseHeader('content-type')); } catch (e) {}
      });
    } catch (e) {}
    return nativeXHROpen.apply(this, arguments);
  };
  if (window.fetch) {
    var nativeFetch = window.fetch;
    window.fetch = function (input) {
      var p = nativeFetch.apply(this, arguments);
      p.then(function (res) {
        try { checkType(res.url, res.headers.get('content-type')); } catch (e) {}
      }, function () {});
      return p;
    };
  }

  // ---------- YouTube ----------
  if (/(^|\.)youtube\.com$/.test(host) || /(^|\.)youtube-nocookie\.com$/.test(host)) {
    var AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];
    function strip(o) {
      if (!o || typeof o !== 'object') return o;
      for (var i = 0; i < AD_KEYS.length; i++) {
        if (AD_KEYS[i] in o) { delete o[AD_KEYS[i]]; removed++; }
      }
      if (o.playerResponse) strip(o.playerResponse);
      return o;
    }

    // Respuestas del reproductor: JSON.parse, Response.json y variable inicial.
    var origParse = JSON.parse;
    JSON.parse = function () {
      var r = origParse.apply(this, arguments);
      try { strip(r); } catch (e) {}
      return r;
    };
    var origJson = Response.prototype.json;
    Response.prototype.json = function () {
      return origJson.apply(this, arguments).then(function (r) {
        try { strip(r); } catch (e) {}
        return r;
      });
    };
    var initial;
    try {
      Object.defineProperty(window, 'ytInitialPlayerResponse', {
        configurable: true,
        get: function () { return initial; },
        set: function (v) { initial = strip(v); }
      });
    } catch (e) {}

    addStyle([
      'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-promoted-sparkles-web-renderer',
      'ytd-display-ad-renderer', 'ytd-banner-promo-renderer', 'ytd-statement-banner-renderer',
      '#player-ads', '#masthead-ad', 'ytd-merch-shelf-renderer', '.ytp-ad-overlay-container',
      'ytm-promoted-sparkles-web-renderer', 'ytm-companion-ad-renderer', 'ytm-promoted-video-renderer',
      'ad-slot-renderer', 'ytm-ad-slot-renderer', 'ytm-companion-slot', 'ytm-paid-content-overlay-renderer'
    ].join(',') + '{display:none!important}');

    // Si aun así aparece un anuncio: silenciar, saltar al final y pulsar "Omitir".
    var mutedByUs = false;
    setInterval(function () {
      var video = document.querySelector('video');
      var adShowing = document.querySelector('.ad-showing, .ad-interrupting');
      if (video && adShowing) {
        if (!video.muted) { video.muted = true; mutedByUs = true; }
        if (isFinite(video.duration) && video.currentTime < video.duration - 0.1) {
          video.currentTime = video.duration;
          removed++; report();
        }
      } else if (video && mutedByUs) {
        video.muted = false; mutedByUs = false;
      }
      var skip = document.querySelector(
        '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, ' +
        '.ytm-skip-ad-button, button[class*="skip-ad"]');
      if (skip) skip.click();
    }, 250);
  }

  // ---------- General ----------
  // Elimina iframes de anuncios que quedan vacíos tras bloquear su contenido.
  var AD_FRAME = /(doubleclick|googlesyndication|adservice|adnxs|taboola|outbrain|criteo|amazon-adsystem|pubmatic|rubiconproject)\./i;
  function sweep(root) {
    var frames = (root.querySelectorAll ? root : document).querySelectorAll('iframe[src]');
    for (var i = 0; i < frames.length; i++) {
      if (AD_FRAME.test(frames[i].src)) { frames[i].remove(); removed++; }
    }
  }
  document.addEventListener('DOMContentLoaded', function () {
    sweep(document);
    report();
    new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i++) {
        for (var j = 0; j < mutations[i].addedNodes.length; j++) {
          var n = mutations[i].addedNodes[j];
          if (n.nodeType === 1) {
            if (n.tagName === 'IFRAME' && AD_FRAME.test(n.src || '')) { n.remove(); removed++; report(); }
            else if (n.querySelectorAll) sweep(n);
          }
        }
      }
    }).observe(document.documentElement, { childList: true, subtree: true });
  });
})();
