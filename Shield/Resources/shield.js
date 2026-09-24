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
    try {
      var x = new URL(u, location.href);
      if (x.protocol === 'blob:') x = new URL(x.pathname);   // blob:https://sitio/uuid
      return baseDomain(x.hostname) === baseDomain(location.hostname);
    } catch (e) { return false; }
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

  // ¿El toque fue sobre un control que navega por JavaScript (botón, enlace "#")?
  function jsControl(el) {
    var c = el && el.closest ? el.closest('a,button,[role=button],[onclick],input[type=button],input[type=submit]') : null;
    if (!c) return false;
    if (c.tagName !== 'A') return true;
    var href = (c.getAttribute('href') || '').trim();
    return !href || href.charAt(0) === '#' || /^javascript:/i.test(href);
  }

  // Patrón típico de enlaces: window.open('') / 'about:blank' y después
  // w.location = destino (o document.write con un meta refresh). Se devuelve
  // una ventana "diferida": cuando la web fija el destino, si el usuario tocó
  // ese enlace de verdad se abre en esta misma pestaña; si no, se bloquea.
  function deferredWindow() {
    var tap = { link: lastTap.link, js: jsControl(lastTap.target), time: Date.now() };
    var w = fakeWindow();
    var done = false;
    function go(target) {
      var u = abs(target);
      if (done || !u || /^(about|javascript):/i.test(u)) return;
      done = true;
      var intended = tap.link ? (tap.link === u || tap.js) : tap.js;
      if (intended && Date.now() - tap.time < 8000) {
        if (window === window.top) post({ openHere: u });
        else post({ popupBlocked: u });
      } else {
        post({ popupBlocked: u });
      }
    }
    var loc = { assign: go, replace: go, reload: function () {}, toString: function () { return 'about:blank'; } };
    Object.defineProperty(loc, 'href', { get: function () { return 'about:blank'; }, set: go });
    Object.defineProperty(w, 'location', { get: function () { return loc; }, set: go });
    w.document.write = w.document.writeln = function (html) {
      var m = /url\s*=\s*['"]?([^'">\s]+)/i.exec(String(html || ''));
      if (m) go(m[1]);
    };
    return w;
  }

  var nativeOpen = window.open;
  window.open = function (url) {
    var u = url ? abs(url) : '';
    if (popupAllowed(u)) {
      post({ allowPopup: u });
      return nativeOpen.apply(window, arguments);
    }
    if ((!u || u === 'about:blank') && recentTap() && lastTap.target &&
        !isOverlay((lastTap.target.closest && lastTap.target.closest('a[href]')) || lastTap.target)) {
      return deferredWindow();
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
    var r = v.getBoundingClientRect();
    sendNativePlay({ nativePlay: src, poster: v.poster ? abs(v.poster) : null, page: location.href,
           time: v.currentTime || 0, title: document.title || '', hls: /\.m3u8(\?|#|$)/i.test(src) || src === lastHLS },
           [r.left, r.top, r.width, r.height]);
  }, true);

  // La posición del vídeo sube de iframe en iframe hasta la página principal,
  // que la pasa a coordenadas del documento para colocar ahí el reproductor.
  function sendNativePlay(msg, rect) {
    if (window === window.top) {
      if (rect) msg.rect = [rect[0] + scrollX, rect[1] + scrollY, rect[2], rect[3]];
      post(msg);
      return;
    }
    try { window.parent.postMessage({ __shieldPlay: msg, rect: rect }, '*'); }
    catch (e) { post(msg); }
  }
  window.addEventListener('message', function (e) {
    if (!e.data || !e.data.__shieldPlay) return;
    var rect = e.data.rect, frame = null;
    var frames = document.querySelectorAll('iframe, frame');
    for (var i = 0; i < frames.length; i++) {
      if (frames[i].contentWindow === e.source) { frame = frames[i]; break; }
    }
    if (frame && rect) {
      var fr = frame.getBoundingClientRect();
      rect = [rect[0] + fr.left + frame.clientLeft, rect[1] + fr.top + frame.clientTop, rect[2], rect[3]];
    } else {
      rect = null;
    }
    sendNativePlay(e.data.__shieldPlay, rect);
  });

  // ---------- Vídeos sin botón de play ----------
  // Si al bloquear anuncios el reproductor de la web no llega a iniciarse, el
  // vídeo se queda como una foto. Al tocarlo, si nadie lo arranca, se muestran
  // los controles del sistema y se reproduce.
  function videoAt(x, y) {
    var list = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
    for (var i = 0; i < list.length; i++) if (list[i].tagName === 'VIDEO') return list[i];
    var vids = document.querySelectorAll('video');
    for (var j = 0; j < vids.length; j++) {
      var r = vids[j].getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return vids[j];
    }
    return null;
  }
  document.addEventListener('playing', function (e) {
    if (e.target && e.target.tagName === 'VIDEO') e.target.__shieldStarted = true;
  }, true);
  document.addEventListener('click', function (e) {
    var v = videoAt(e.clientX, e.clientY);
    if (!v || !v.paused || v.__shieldStarted) return;
    var link = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (link && !jsControl(link)) return;
    setTimeout(function () {
      if (!v.isConnected || !v.paused || v.__shieldStarted) return;
      if (!v.currentSrc && !v.getAttribute('src') && !v.querySelector('source[src]')) return;
      if (!v.controls) v.setAttribute('controls', '');
      try { var p = v.play(); if (p && p.catch) p.catch(function () {}); } catch (err) {}
    }, 500);
  }, true);

  // ---------- SDK de anuncios de vídeo (Google IMA) ----------
  // Muchos reproductores esperan a que cargue ima3.js antes de mostrar el vídeo.
  // Si el bloqueador lo impide, se sustituye por uno vacío que responde "no hay
  // anuncios" y el reproductor pasa directamente al contenido.
  function installImaStub() {
    var g = window.google = window.google || {};
    if (g.ima && g.ima.AdsLoader) return;
    var noop = function () {};
    function Emitter() { this.__l = {}; }
    Emitter.prototype.addEventListener = function (types, fn, capture, ctx) {
      types = [].concat(types);
      for (var i = 0; i < types.length; i++) {
        (this.__l[types[i]] = this.__l[types[i]] || []).push(ctx ? fn.bind(ctx) : fn);
      }
    };
    Emitter.prototype.removeEventListener = noop;
    Emitter.prototype.__emit = function (type, ev) {
      var l = (this.__l[type] || []).slice();
      for (var i = 0; i < l.length; i++) { try { l[i](ev); } catch (e) {} }
    };
    function types(names) {
      var o = {};
      names.split(' ').forEach(function (n) { o[n] = n.toLowerCase(); });
      return o;
    }
    function AdError() {}
    AdError.prototype = {
      getErrorCode: function () { return 1009; }, getVastErrorCode: function () { return 303; },
      getMessage: function () { return 'No ads'; }, getType: function () { return 'adLoadError'; },
      getInnerError: function () { return null; }, toString: function () { return 'AdError 1009: No ads'; }
    };
    AdError.ErrorCode = { VAST_EMPTY_RESPONSE: 1009, UNKNOWN_ERROR: 900 };
    AdError.Type = { AD_LOAD: 'adLoadError', AD_PLAY: 'adPlayError' };
    function AdErrorEvent(ctx) { this.ctx = ctx; this.type = 'adError'; }
    AdErrorEvent.prototype = {
      getError: function () { return new AdError(); },
      getUserRequestContext: function () { return this.ctx || {}; }
    };
    AdErrorEvent.Type = { AD_ERROR: 'adError' };
    var settings = new Proxy({ VpaidMode: { DISABLED: 0, ENABLED: 1, INSECURE: 2 },
      getLocale: function () { return 'es'; }, getNumRedirects: function () { return 4; },
      getPlayerType: function () { return ''; }, getPlayerVersion: function () { return ''; },
      getDisableCustomPlaybackForIOS10Plus: function () { return false; } },
      { get: function (t, k) { return k in t ? t[k] : noop; } });
    function AdsLoader() { Emitter.call(this); }
    AdsLoader.prototype = Object.create(Emitter.prototype);
    AdsLoader.prototype.requestAds = function (req, ctx) {
      var self = this;
      setTimeout(function () { self.__emit('adError', new AdErrorEvent(ctx)); }, 0);
    };
    AdsLoader.prototype.getSettings = function () { return settings; };
    AdsLoader.prototype.contentComplete = noop;
    AdsLoader.prototype.destroy = noop;
    AdsLoader.prototype.getVersion = function () { return '3.0'; };
    function Plain() {}
    g.ima = {
      VERSION: '3.0', settings: settings, ImaSdkSettings: function () { return settings; },
      AdDisplayContainer: function () { this.initialize = noop; this.destroy = noop; },
      AdsLoader: AdsLoader, AdsRequest: Plain, AdsRenderingSettings: Plain,
      AdError: AdError, AdErrorEvent: AdErrorEvent,
      AdsManagerLoadedEvent: { Type: { ADS_MANAGER_LOADED: 'adsManagerLoaded' } },
      AdEvent: { Type: types('AD_BREAK_READY AD_BUFFERING AD_CAN_PLAY AD_METADATA AD_PROGRESS ' +
        'ALL_ADS_COMPLETED CLICK COMPLETE CONTENT_PAUSE_REQUESTED CONTENT_RESUME_REQUESTED ' +
        'DURATION_CHANGE FIRST_QUARTILE IMPRESSION INTERACTION LINEAR_CHANGED LOADED LOG MIDPOINT ' +
        'PAUSED RESUMED SKIPPABLE_STATE_CHANGED SKIPPED STARTED THIRD_QUARTILE USER_CLOSE ' +
        'VIDEO_CLICKED VIDEO_ICON_CLICKED VOLUME_CHANGED VOLUME_MUTED') },
      ViewMode: { NORMAL: 'normal', FULLSCREEN: 'fullscreen' },
      UiElements: { AD_ATTRIBUTION: 'adAttribution', COUNTDOWN: 'countdown' },
      CompanionAdSelectionSettings: Plain, OmidAccessMode: { LIMITED: 'limited', DOMAIN: 'domain', FULL: 'full' },
      OmidVerificationVendor: {}, UniversalAdIdInfo: Plain
    };
    g.ima.CompanionAdSelectionSettings.CreativeType = { ALL: 'All', FLASH: 'Flash', IMAGE: 'Image' };
    g.ima.CompanionAdSelectionSettings.ResourceType = { ALL: 'All', HTML: 'Html', IFRAME: 'IFrame', STATIC: 'Static' };
    g.ima.CompanionAdSelectionSettings.SizeCriteria = { IGNORE: 'IgnoreSize', SELECT_EXACT_MATCH: 'SelectExactMatch', SELECT_NEAR_MATCH: 'SelectNearMatch' };
  }
  // Un <script> que falla dispara "error" sin burbujear: se captura en window
  // antes que el onerror del reproductor, se instala el sustituto y se simula "load".
  window.addEventListener('error', function (e) {
    var t = e.target;
    if (!t || t.tagName !== 'SCRIPT' || !/imasdk\.googleapis\.com\/js\/sdkloader\/ima3(_debug)?\.js/i.test(t.src || '')) return;
    installImaStub();
    e.stopImmediatePropagation();
    setTimeout(function () { t.dispatchEvent(new Event('load')); }, 0);
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
