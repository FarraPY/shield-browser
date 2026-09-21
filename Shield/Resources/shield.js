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
