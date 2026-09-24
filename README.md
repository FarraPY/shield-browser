# Shield — navegador para iPhone sin anuncios (tipo Brave)

Navegador para iOS 27 con bloqueo de anuncios y rastreadores integrado,
compilado **en la nube** (no hace falta Mac) e instalado desde **Windows**.

## Qué hace

| Función | Cómo |
|---|---|
| Bloqueo de anuncios y rastreadores a nivel de red | `WKContentRuleList` (el mismo motor que Safari y Firefox iOS) con ~180.000 reglas de EasyList, EasyPrivacy, EasyList Español, Peter Lowe, HaGeZi Pro y HaGeZi Pop-Up Ads (dominios rotativos de redes de pop-ups) + `tools/custom_filters.txt` |
| Anuncios flotantes (in-page push, falsas alertas, interstitials) | Detección por comportamiento: si un script de un dominio externo desconocido cuelga del `<body>` una capa flotante, se elimina; el shadow DOM "cerrado" de las redes se fuerza a abierto |
| Ocultación de huecos/banners | Reglas cosméticas `css-display-none` (~6.800 grupos de selectores) |
| Anuncios de YouTube | Script inyectado que elimina `adPlacements` de las respuestas del reproductor y salta/silencia cualquier anuncio residual |
| Pop-ups y pop-unders | `window.open` y enlaces `_blank` sólo se abren si tocaste un enlace visible, y en la **misma pestaña** (se vuelve con el gesto atrás). El resto se bloquea en silencio: contador y "Abrir" en el panel del escudo. Los enlaces que abren una ventana en blanco (`about:blank`) y luego le ponen la dirección se abren igualmente si los tocaste tú |
| Capas trampa invisibles | Enlaces/capas transparentes sobre imágenes que "roban" el primer toque: se desactivan y el toque pasa a la imagen de debajo |
| Descargar cualquier vídeo o imagen | Botón ⬇︎ de la barra: detecta `<video>`, `<img>`, iframes de reproductores, listas HLS `.m3u8` (con AES-128) y peticiones de red de vídeo. Guarda en Fotos y en Archivos → Shield |
| Reproductor del iPhone | Al pulsar play en cualquier web, el vídeo se reproduce en AVPlayer **en el mismo sitio de la página** (sigue al desplazarte; con Referer/cookies de la página): botón Descargar, Picture in Picture, AirPlay y pantalla completa. Se cierra con ✕ o deslizando desde el borde izquierdo. Desactivable en Ajustes o por página |
| Vídeos "congelados" | Si el reproductor de la web no arranca porque se bloqueó su SDK de anuncios (Google IMA), se sustituye por uno vacío que dice "no hay anuncios"; y si al tocar un vídeo nadie lo inicia, se muestran los controles del sistema y se reproduce |
| Descargas de archivos | Enlaces con `Content-Disposition: attachment` (también desde iframes, p. ej. MediaFire), `<a download>` y archivos generados en la página (`blob:`/`data:`, p. ej. MEGA). Aviso "Descargando… · Ver" |
| Barra de direcciones | Al tocarla se selecciona toda la dirección (escribir la reemplaza) y tiene botón ✕. Sugiere búsquedas anteriores y páginas del historial. Deslizarla a los lados cambia de pestaña |
| Historial | Menú ⋯ → Historial: agrupado por día, con buscador y borrado (las pestañas privadas no se guardan) |
| Pinch-to-zoom | Funciona en todas las webs, aunque la página lo intente impedir |
| Pestañas | Cuadrícula con miniaturas, normales/privadas por separado; mantener pulsado un enlace → "Abrir en pestaña nueva". Deslizar desde el borde izquierdo en una página sin historial atrás cierra la pestaña con aviso "Deshacer" |
| Escudos por sitio | Botón del escudo → desactivar en un sitio concreto (como el león de Brave) |
| HTTPS | `upgradeKnownHostsToHTTPS` |
| Pestañas y pestañas privadas | Las privadas usan almacenamiento no persistente |
| Motor de búsqueda | DuckDuckGo (por defecto), Brave Search, Google, Startpage |
| Listas actualizadas | GitHub Actions recompila cada lunes con las listas más recientes |

## Investigación: por qué esta arquitectura

1. **En iOS todos los navegadores usan WebKit.** Brave, Chrome y Firefox para iPhone usan
   `WKWebView` (en la UE se permiten otros motores, pero requiere autorización especial de
   Apple). Por eso el bloqueo se hace con la API nativa `WKContentRuleList`: WebKit descarta
   las peticiones antes de que salgan del iPhone, sin coste de rendimiento.
2. **Límite de reglas:** WebKit admite hasta 150.000 reglas por lista. `tools/convert_filters.py`
   convierte las listas (sintaxis Adblock Plus) al JSON de WebKit y las divide en trozos de 40.000.
   Si WebKit rechazara alguna regla, la app la localiza por bisección y compila el resto.
3. **Compilar sin Mac:** una app iOS necesita Xcode, que sólo funciona en macOS. GitHub Actions
   ofrece la imagen `xcode-27` (macOS 27 + Xcode 27 + SDK `iphoneos27.0`). El proyecto Xcode se
   genera con XcodeGen a partir de `project.yml`.
4. **Instalar sin Mac:** [Sideloadly](https://sideloadly.io) (Windows) firma la IPA con tu Apple ID
   gratuito y la instala por cable. Confirmado compatible con iOS 27.
   Con Apple ID gratuito la app caduca a los **7 días** (Sideloadly puede refrescarla
   automáticamente); con la cuenta de desarrollador de Apple (99 $/año) dura 1 año y puedes usar TestFlight.

Límite honesto: ningún bloqueador de iOS basado en WebKit bloquea el 100 % de los anuncios.
Los anuncios "nativos" servidos desde el mismo dominio que el contenido, o los de YouTube si
cambia su formato, pueden requerir actualizar reglas/scripts.

## Probarlo en tu iPhone (Windows)

### 1. Preparar el iPhone (una sola vez)
- Actualizado a iOS 27.
- **Ajustes → Privacidad y seguridad → Modo de desarrollador → Activar** (se reinicia).
  Si no aparece la opción, aparecerá después de instalar la app la primera vez.

### 2. Preparar el PC (una sola vez)
- Instala **iTunes** (versión web de apple.com, no la de Microsoft Store) o la app
  **Dispositivos Apple** de Microsoft Store, para que Windows reconozca el iPhone.
- Descarga e instala **Sideloadly** desde https://sideloadly.io.

### 3. Obtener la IPA
Cada `git push` a `main` compila la app en GitHub Actions y publica `Shield.ipa` en la
pestaña **Releases** del repositorio (también queda como *artifact* del workflow).

### 4. Instalar
1. Conecta el iPhone por USB y pulsa **Confiar** en el iPhone.
2. Abre Sideloadly, arrastra `Shield.ipa`, escribe tu Apple ID y pulsa **Start**.
   (Tu contraseña la introduces tú en Sideloadly; se usa sólo para firmar con Apple.)
3. En el iPhone: **Ajustes → General → VPN y gestión de dispositivos →** tu Apple ID → **Confiar**.
4. Abre **Shield**. La primera vez compila los filtros (unos segundos); luego queda en caché.

## Desarrollo

```
tools/convert_filters.py   # listas EasyList → JSON de WebKit
project.yml                # definición del proyecto (XcodeGen)
Shield/
  ShieldApp.swift          # punto de entrada
  ContentBlocker.swift     # compila y cachea las WKContentRuleList
  BrowserTab.swift         # WKWebView + escudos por sitio + navegación
  TabManager.swift         # pestañas normales / privadas
  Settings.swift           # ajustes, motores de búsqueda, parser de la barra
  Views/                   # SwiftUI
  Resources/shield.js      # script anti-anuncios (YouTube, iframes)
.github/workflows/build.yml
```

Probar el conversor en local: `python tools/convert_filters.py` (requiere `pip install soupsieve beautifulsoup4`).

Si algún día tienes un Mac: `brew install xcodegen && xcodegen generate && open Shield.xcodeproj`
y ejecútalo directamente en el iPhone desde Xcode.
