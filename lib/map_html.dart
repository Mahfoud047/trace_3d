/// Page HTML chargée dans la WebView : carte 3D MapLibre GL JS avec relief.
///
/// Pour changer de fournisseur de tuiles (MapTiler, Stadia, Mapbox…),
/// modifie simplement le bloc CONFIG en haut du script.
const String mapHtml = r'''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link href="https://unpkg.com/maplibre-gl@5/dist/maplibre-gl.css" rel="stylesheet">
<style>
  html, body, #map { margin: 0; padding: 0; height: 100%; width: 100%; background: #0e1116; }
  .dot { width: 18px; height: 18px; border-radius: 50%; background: #fff;
         border: 4px solid #fc4c02; box-shadow: 0 0 0 3px rgba(252,76,2,.35); }
  .pin { width: 16px; height: 16px; border-radius: 50%; border: 3px solid #fff;
         box-shadow: 0 1px 4px rgba(0,0,0,.6); }
  .maplibregl-ctrl-attrib { font-size: 10px; }
</style>
</head>
<body>
<div id="map"></div>
<script src="https://unpkg.com/maplibre-gl@5/dist/maplibre-gl.js"></script>
<script>
// ---------- CONFIG : remplace par tes propres sources si besoin ----------
const CONFIG = {
  satTiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'],
  satAttribution: 'Imagery © Esri',
  planTiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
  planAttribution: '© OpenStreetMap contributors',
  demTiles: ['https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png'],
  demAttribution: 'Terrain © Mapzen / AWS Terrain Tiles',
  exaggeration: 1.3
};
// ------------------------------------------------------------------------

let loaded = false, pending = null;
let coords = [], cum = [], total = 0;
let startM = null, endM = null, dot = null, anim = null;

const map = new maplibregl.Map({
  container: 'map',
  style: {
    version: 8,
    sources: {
      sat:  { type: 'raster', tiles: CONFIG.satTiles,  tileSize: 256, maxzoom: 19, attribution: CONFIG.satAttribution },
      plan: { type: 'raster', tiles: CONFIG.planTiles, tileSize: 256, maxzoom: 19, attribution: CONFIG.planAttribution },
      dem:  { type: 'raster-dem', tiles: CONFIG.demTiles, tileSize: 256, maxzoom: 15, encoding: 'terrarium', attribution: CONFIG.demAttribution },
      hill: { type: 'raster-dem', tiles: CONFIG.demTiles, tileSize: 256, maxzoom: 15, encoding: 'terrarium' }
    },
    layers: [
      { id: 'plan', type: 'raster', source: 'plan', layout: { visibility: 'none' } },
      { id: 'sat',  type: 'raster', source: 'sat' },
      { id: 'hillshade', type: 'hillshade', source: 'hill',
        paint: { 'hillshade-exaggeration': 0.35, 'hillshade-shadow-color': '#000000' } }
    ]
  },
  center: [2.5, 46.5],
  zoom: 4.5,
  pitch: 55,
  maxPitch: 85,
  attributionControl: { compact: true }
});

map.on('load', () => {
  map.setTerrain({ source: 'dem', exaggeration: CONFIG.exaggeration });
  try {
    map.setSky({
      'sky-color': '#7ab8f5', 'sky-horizon-blend': 0.5,
      'horizon-color': '#dfeaf5', 'horizon-fog-blend': 0.6,
      'fog-color': '#c9d8e8', 'fog-ground-blend': 0.4,
      'atmosphere-blend': ['interpolate', ['linear'], ['zoom'], 0, 1, 10, 1, 12, 0]
    });
  } catch (e) { /* ciel non supporté : sans conséquence */ }
  loaded = true;
  if (pending) { draw(pending); pending = null; }
});

// ---------- Utilitaires géo ----------
const R = 6371008.8, rad = d => d * Math.PI / 180, deg = r => r * 180 / Math.PI;

function hav(a, b) {
  const dLat = rad(b[1] - a[1]), dLon = rad(b[0] - a[0]);
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[1])) * Math.cos(rad(b[1])) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(s)));
}

function bearing(a, b) {
  const y = Math.sin(rad(b[0] - a[0])) * Math.cos(rad(b[1]));
  const x = Math.cos(rad(a[1])) * Math.sin(rad(b[1])) -
            Math.sin(rad(a[1])) * Math.cos(rad(b[1])) * Math.cos(rad(b[0] - a[0]));
  return (deg(Math.atan2(y, x)) + 360) % 360;
}

function lerpAngle(a, b, f) {
  const d = ((b - a + 540) % 360) - 180;
  return a + d * f;
}

// Point situé à la distance d (en mètres) le long de la trace
function pointAt(d) {
  if (d <= 0) return coords[0];
  if (d >= total) return coords[coords.length - 1];
  let lo = 0, hi = cum.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (cum[mid] <= d) lo = mid; else hi = mid;
  }
  const seg = cum[hi] - cum[lo] || 1;
  const t = (d - cum[lo]) / seg;
  return [coords[lo][0] + (coords[hi][0] - coords[lo][0]) * t,
          coords[lo][1] + (coords[hi][1] - coords[lo][1]) * t];
}

function pin(color) {
  const el = document.createElement('div');
  el.className = 'pin';
  el.style.background = color;
  return el;
}

// ---------- API appelée depuis Flutter ----------
function loadTrack(c) {
  if (!loaded) { pending = c; return; }
  draw(c);
}

function draw(c) {
  stopFly(true);
  coords = c;
  cum = [0];
  for (let i = 1; i < c.length; i++) cum.push(cum[i - 1] + hav(c[i - 1], c[i]));
  total = cum[cum.length - 1];

  const geo = { type: 'Feature', geometry: { type: 'LineString', coordinates: c.map(p => [p[0], p[1]]) } };
  if (map.getSource('track')) {
    map.getSource('track').setData(geo);
  } else {
    map.addSource('track', { type: 'geojson', data: geo });
    map.addLayer({ id: 'track-casing', type: 'line', source: 'track',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': '#ffffff', 'line-width': 8, 'line-opacity': 0.9 } });
    map.addLayer({ id: 'track-line', type: 'line', source: 'track',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': '#fc4c02', 'line-width': 4.5 } });
  }

  if (startM) startM.remove();
  if (endM) endM.remove();
  startM = new maplibregl.Marker({ element: pin('#22c55e') }).setLngLat([c[0][0], c[0][1]]).addTo(map);
  endM = new maplibregl.Marker({ element: pin('#ef4444') }).setLngLat([c[c.length - 1][0], c[c.length - 1][1]]).addTo(map);

  recenter();
}

function recenter() {
  if (!coords.length) return;
  stopFly(true);
  const b = new maplibregl.LngLatBounds([coords[0][0], coords[0][1]], [coords[0][0], coords[0][1]]);
  coords.forEach(p => b.extend([p[0], p[1]]));
  map.fitBounds(b, {
    padding: { top: 80, bottom: Math.round(window.innerHeight * 0.42), left: 40, right: 40 },
    pitch: 60, bearing: -15, duration: 2200, maxZoom: 16
  });
}

function setBase(satellite) {
  map.setLayoutProperty('sat', 'visibility', satellite ? 'visible' : 'none');
  map.setLayoutProperty('plan', 'visibility', satellite ? 'none' : 'visible');
  map.setPaintProperty('hillshade', 'hillshade-exaggeration', satellite ? 0.35 : 0.6);
}

// ---------- Survol 3D ----------
function startFly() {
  if (!coords.length) return;
  stopFly(true);
  map.stop();

  // ~5 s par km, entre 25 s et 90 s
  const dur = Math.min(90000, Math.max(25000, (total / 1000) * 5000));
  const look = Math.max(150, total * 0.03);
  let t0 = null, brg = null;

  dot = new maplibregl.Marker({ element: Object.assign(document.createElement('div'), { className: 'dot' }) })
    .setLngLat([coords[0][0], coords[0][1]]).addTo(map);

  const step = (ts) => {
    if (t0 === null) t0 = ts;
    const t = (ts - t0) / dur;
    if (t >= 1) { finishFly(); return; }
    const d = t * total;
    const p = pointAt(d);
    const ahead = pointAt(Math.min(total, d + look));
    const target = bearing(p, ahead);
    brg = brg === null ? target : lerpAngle(brg, target, 0.05);
    map.jumpTo({ center: p, bearing: brg, pitch: 68, zoom: 14.8 });
    dot.setLngLat(p);
    anim = requestAnimationFrame(step);
  };
  anim = requestAnimationFrame(step);
}

function stopFly(silent) {
  if (anim) { cancelAnimationFrame(anim); anim = null; }
  if (dot) { dot.remove(); dot = null; }
  if (!silent && window.Bridge) Bridge.postMessage('flyEnd');
}

function finishFly() {
  stopFly(true);
  if (window.Bridge) Bridge.postMessage('flyEnd');
  recenter();
}
</script>
</body>
</html>
''';
