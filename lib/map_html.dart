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
  .maplibregl-ctrl-attrib { font-size: 10px; }
</style>
</head>
<body>
<div id="map"></div>
<script src="https://unpkg.com/maplibre-gl@5/dist/maplibre-gl.js"></script>
<script src="https://unpkg.com/three@0.158.0/build/three.min.js"></script>
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
let anim = null, rec = null, cam = null, lastP = null, frameK = -1, bikeColor = null;
let trackColor = '#fc4c02', trackWidth = 4.5, markerKind = 'bike', markerColor = '#eab308';

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
function pointAt(d, P = { c: coords, cum, total }) {
  const c = P.c, cm = P.cum;
  if (d <= 0) return c[0];
  if (d >= P.total) return c[c.length - 1];
  let lo = 0, hi = cm.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (cm[mid] <= d) lo = mid; else hi = mid;
  }
  const seg = cm[hi] - cm[lo] || 1;
  const t = (d - cm[lo]) / seg;
  return [c[lo][0] + (c[hi][0] - c[lo][0]) * t,
          c[lo][1] + (c[hi][1] - c[lo][1]) * t];
}

// Trace ré-échantillonnée puis lissée (moyenne glissante, extrémités fixes) : le bruit GPS
// ne fait plus trembler la caméra ni le repère.
function buildCam() {
  const n = Math.max(2, Math.ceil(total / Math.max(5, total / 3000)));
  const r = Math.max(2, Math.round(40 / (total / n)));
  let pts = [];
  for (let i = 0; i <= n; i++) pts.push(pointAt(total * i / n));
  for (let pass = 0; pass < 2; pass++) {
    const src = pts;
    pts = src.map((_, i) => {
      const rr = Math.min(r, i, n - i);
      let x = 0, y = 0;
      for (let j = i - rr; j <= i + rr; j++) { x += src[j][0]; y += src[j][1]; }
      return [x / (2 * rr + 1), y / (2 * rr + 1)];
    });
  }
  const cm = [0];
  for (let i = 1; i <= n; i++) cm.push(cm[i - 1] + hav(pts[i - 1], pts[i]));
  cam = { c: pts, cum: cm, total: cm[n] };
}

// ---------- Cycliste 3D ----------
// Modèle construit avec three.js (formes lisses, style « argile »), rendu hors écran vu de derrière
// et d'un peu au-dessus, puis converti en icônes de la carte : une image par pas du cycle de pédalage.
const BIKE_FRAMES = 12;

// Cinématique inverse à deux segments : renvoie la position du genou/coude.
function ik(T, root, target, l1, l2, pole) {
  const d = target.clone().sub(root), len = Math.min(d.length(), l1 + l2 - 1e-4);
  const dir = d.normalize();
  const along = (l1 * l1 - l2 * l2 + len * len) / (2 * len);
  const h = Math.sqrt(Math.max(0, l1 * l1 - along * along));
  const perp = pole.clone().sub(dir.clone().multiplyScalar(pole.dot(dir))).normalize();
  return root.clone().addScaledVector(dir, along).addScaledVector(perp, h);
}

function bikeFrames(color) {
  const T = THREE, W = 400, H = 560;
  const renderer = new T.WebGLRenderer({ alpha: true, antialias: true, preserveDrawingBuffer: true });
  renderer.setSize(W, H, false);
  renderer.setClearColor(0x000000, 0);
  const scene = new T.Scene();
  scene.add(new T.HemisphereLight(0xffffff, 0x8a96a8, 1.1));
  const sun = new T.DirectionalLight(0xffffff, 1.7); sun.position.set(-2, 5, 3); scene.add(sun);
  const fillL = new T.DirectionalLight(0xbcd2ff, 0.55); fillL.position.set(3, 1, 2); scene.add(fillL);

  const el = 30 * Math.PI / 180, dist = 5.4, look = new T.Vector3(0, 0.78, 0.05);
  const cam = new T.PerspectiveCamera(24, W / H, 0.1, 40);
  cam.position.set(0, look.y + dist * Math.sin(el), look.z + dist * Math.cos(el));
  cam.lookAt(look);

  const mat = (c, extra) => new T.MeshStandardMaterial(Object.assign({ color: c, roughness: 0.55, metalness: 0.04 }, extra));
  const base = new T.Color(color);
  const jersey = mat(base, { side: T.DoubleSide }), frameM = mat(base.clone().multiplyScalar(0.85));
  const helmetM = mat('#f7f8fa', { roughness: 0.35 }), helmetStripe = mat(base);
  const shorts = mat('#27324f', { side: T.DoubleSide }), skin = mat('#f1b392'), shoe = mat('#f4f4f5'), glove = mat('#1b1b1f');
  const tire = mat('#202124', { roughness: 0.8 }), rimM = mat('#c4cad4', { metalness: 0.7, roughness: 0.35 });
  const dark = mat('#17181b');

  const V = (x, y, z) => new T.Vector3(x, y, z);
  const orient = (mesh, a, b) => {
    const d = b.clone().sub(a);
    mesh.position.copy(a).addScaledVector(d, 0.5);
    mesh.quaternion.setFromUnitVectors(V(0, 1, 0), d.normalize());
    return mesh;
  };
  const tube = (g, a, b, r, m) => g.add(orient(new T.Mesh(new T.CylinderGeometry(r, r, a.distanceTo(b), 10), m), a, b));
  const blob = (g, p, sx, sy, sz, m) => {
    const mesh = new T.Mesh(new T.SphereGeometry(1, 24, 18), m);
    mesh.position.copy(p); mesh.scale.set(sx, sy, sz); g.add(mesh);
  };
  // Membre effilé : cône + sphères aux deux bouts de même rayon que le cône, donc raccord sans bosse.
  const taper = (g, a, b, r1, r2, m) => {
    g.add(orient(new T.Mesh(new T.CylinderGeometry(r2, r1, a.distanceTo(b), 20, 1, true), m), a, b));
    for (const [p, r] of [[a, r1], [b, r2]]) {
      const sp = new T.Mesh(new T.SphereGeometry(r, 20, 14), m); sp.position.copy(p); g.add(sp);
    }
  };
  // Surface lissée le long d'un axe P0→P1 : keys = [t, demi-largeur, demi-épaisseur] (t de 0 à 1), interpolées en spline.
  const loft = (g, P0, P1, keys, m) => {
    const s = P1.clone().sub(P0), L = s.length(); s.normalize();
    const nrm = V(1, 0, 0).cross(s).normalize();
    const curve = new T.CatmullRomCurve3(keys.map(k => V(k[0], k[1], k[2])));
    const rings = 36, seg = 32, pos = [], idx = [];
    for (let i = 0; i < rings; i++) {
      const q = curve.getPoint(i / (rings - 1)), c = P0.clone().addScaledVector(s, q.x * L);
      const rx = Math.max(0.001, q.y), rn = Math.max(0.001, q.z);
      for (let j = 0; j < seg; j++) {
        const a = 2 * Math.PI * j / seg;
        pos.push(c.x + rx * Math.cos(a) + nrm.x * rn * Math.sin(a), c.y + nrm.y * rn * Math.sin(a), c.z + nrm.z * rn * Math.sin(a));
      }
    }
    for (let i = 0; i < rings - 1; i++) for (let j = 0; j < seg; j++) {
      const a = i * seg + j, b = i * seg + (j + 1) % seg, c = (i + 1) * seg + j, d = (i + 1) * seg + (j + 1) % seg;
      idx.push(a, c, b, b, c, d);
    }
    const geo = new T.BufferGeometry();
    geo.setAttribute('position', new T.Float32BufferAttribute(pos, 3));
    geo.setIndex(idx); geo.computeVertexNormals();
    g.add(new T.Mesh(geo, m));
  };

  const R = 0.335;
  const BB = V(0, 0.27, 0.08);
  const seatTop = V(0, 0.93, 0.27), headTop = V(0, 0.9, -0.36), headBot = V(0, 0.74, -0.4);

  // ombre au sol (dégradé radial)
  const sc = document.createElement('canvas'); sc.width = sc.height = 128;
  const sg = sc.getContext('2d').createRadialGradient(64, 64, 0, 64, 64, 64);
  sg.addColorStop(0, 'rgba(0,0,0,.4)'); sg.addColorStop(1, 'rgba(0,0,0,0)');
  sc.getContext('2d').fillStyle = sg; sc.getContext('2d').fillRect(0, 0, 128, 128);
  const shadow = new T.Mesh(new T.PlaneGeometry(0.95, 2.1),
    new T.MeshBasicMaterial({ map: new T.CanvasTexture(sc), transparent: true, depthWrite: false }));
  shadow.rotation.x = -Math.PI / 2; shadow.position.set(0, 0.003, 0.05); scene.add(shadow);

  // cadre, fourche, guidon, selle
  const st = new T.Group(); scene.add(st);
  tube(st, BB, seatTop, 0.017, frameM); tube(st, seatTop, headTop, 0.016, frameM);
  tube(st, BB, headBot, 0.021, frameM); tube(st, headTop, headBot, 0.022, frameM);
  for (const s of [-1, 1]) {
    tube(st, V(s * 0.03, 0.27, 0.08), V(s * 0.055, R, 0.5), 0.011, frameM);          // base arrière
    tube(st, V(s * 0.02, 0.88, 0.27), V(s * 0.055, R, 0.5), 0.009, frameM);          // haubans
    tube(st, V(s * 0.05, 0.73, -0.41), V(s * 0.05, R, -0.5), 0.013, frameM);        // fourche
    tube(st, V(s * 0.2, 0.95, -0.47), V(s * 0.2, 0.9, -0.56), 0.012, dark);          // cocottes
  }
  tube(st, headTop, V(0, 0.96, -0.47), 0.016, dark);
  tube(st, V(-0.2, 0.95, -0.47), V(0.2, 0.95, -0.47), 0.012, dark);
  tube(st, seatTop, V(0, 0.98, 0.29), 0.012, dark);
  blob(st, V(0, 1.0, 0.31), 0.07, 0.027, 0.15, dark);

  // buste : cuissard (bassin) et maillot (taille, côtes, épaules) en deux surfaces lissées qui se recouvrent
  const S0 = V(0, 0.98, 0.37), S1 = V(0, 1.4, -0.13);
  loft(st, S0, S1, [[0, 0.001, 0.001], [0.04, 0.125, 0.1], [0.15, 0.168, 0.14], [0.3, 0.152, 0.125],
    [0.42, 0.125, 0.105], [0.48, 0.001, 0.001]], shorts);
  loft(st, S0, S1, [[0.2, 0.001, 0.001], [0.26, 0.158, 0.13], [0.4, 0.15, 0.122], [0.58, 0.178, 0.128],
    [0.78, 0.214, 0.124], [0.92, 0.2, 0.1], [0.985, 0.085, 0.06], [1, 0.001, 0.001]], jersey);
  const sh = [V(-0.2, 1.31, -0.04), V(0.2, 1.31, -0.04)];
  // cou, tête, casque
  taper(st, V(0, 1.38, -0.1), V(0, 1.45, -0.22), 0.052, 0.047, skin);
  blob(st, V(0, 1.48, -0.27), 0.095, 0.1, 0.105, skin);
  blob(st, V(0, 1.515, -0.265), 0.118, 0.1, 0.15, helmetM);
  blob(st, V(0, 1.55, -0.255), 0.032, 0.075, 0.16, helmetStripe);                  // bande de couleur
  [-1, 1].forEach(s => blob(st, V(s * 0.098, 1.46, -0.27), 0.016, 0.026, 0.02, skin));  // oreilles
  // bras vers les cocottes : manche, avant-bras, gant
  [-1, 1].forEach((s, i) => {
    const hand = V(s * 0.2, 0.97, -0.5);
    const elbow = ik(T, sh[i], hand, 0.28, 0.27, V(s * 1.0, -0.25, 0.1));
    taper(st, sh[i], elbow, 0.062, 0.046, jersey);
    taper(st, elbow, hand, 0.04, 0.03, skin);
    blob(st, hand, 0.045, 0.04, 0.05, glove);
  });
  const hips = [V(-0.09, 0.99, 0.35), V(0.09, 0.99, 0.35)];

  const out = document.createElement('canvas'); out.width = 200; out.height = 280;
  const oc = out.getContext('2d', { willReadFrequently: true });
  const frames = [];
  for (let k = 0; k < BIKE_FRAMES; k++) {
    const th = 2 * Math.PI * k / BIKE_FRAMES;
    const dyn = new T.Group(); scene.add(dyn);

    for (const z of [0.5, -0.5]) {                       // roues : pneu, jante, rayons
      const w = new T.Group(); w.position.set(0, R, z);
      const t = new T.Mesh(new T.TorusGeometry(R - 0.024, 0.024, 12, 48), tire); t.rotation.y = Math.PI / 2; w.add(t);
      const r = new T.Mesh(new T.TorusGeometry(R - 0.052, 0.008, 8, 48), rimM); r.rotation.y = Math.PI / 2; w.add(r);
      for (let i = 0; i < 24; i++) {
        const a = i * Math.PI / 12;
        tube(w, V(0, 0, 0), V(0, Math.cos(a) * (R - 0.052), Math.sin(a) * (R - 0.052)), 0.0035, rimM);
      }
      w.rotation.x = -th * 2; dyn.add(w);
    }

    [-1, 1].forEach((s, i) => {                          // pédalier et jambes en opposition de phase
      const a = th + (i ? Math.PI : 0);
      const pedal = V(s * 0.1, BB.y + 0.17 * Math.cos(a), BB.z - 0.17 * Math.sin(a));
      tube(dyn, V(s * 0.04, BB.y, BB.z), pedal, 0.01, rimM);
      blob(dyn, pedal, 0.04, 0.01, 0.055, dark);
      const ankle = pedal.clone().add(V(0, 0.045, 0.03));
      const knee = ik(T, hips[i], ankle, 0.46, 0.44, V(s * 0.35, 0.1, -1));
      const hem = hips[i].clone().lerp(knee, 0.66);
      taper(dyn, hips[i], hem, 0.092, 0.074, shorts);   // cuisse sous le cuissard
      taper(dyn, hem, knee, 0.068, 0.06, skin);         // bas de cuisse
      taper(dyn, knee, ankle, 0.06, 0.034, skin);       // mollet
      blob(dyn, ankle.clone().add(V(0, -0.03, -0.045)), 0.055, 0.042, 0.115, shoe);
    });

    renderer.render(scene, cam);
    oc.clearRect(0, 0, 200, 280);
    oc.drawImage(renderer.domElement, 0, 0, 200, 280);
    frames.push(oc.getImageData(0, 0, 200, 280));
    scene.remove(dyn);
    dyn.traverse(o => { if (o.geometry) o.geometry.dispose(); });
  }
  renderer.dispose();
  renderer.forceContextLoss();
  return frames;
}

// ---------- Repères de départ et d'arrivée ----------
// Repère de position : goutte colorée avec un drapeau à damier noir et blanc. Sprite 56x72, pointe en (28,68).
function pinImage(color) {
  const W = 56, H = 72;
  const c = document.createElement('canvas'); c.width = W * 2; c.height = H * 2;
  const g = c.getContext('2d'); g.scale(2, 2);
  g.shadowColor = 'rgba(0,0,0,.45)'; g.shadowBlur = 4; g.shadowOffsetY = 1.5;
  g.beginPath();
  g.moveTo(28, 68);
  g.bezierCurveTo(28, 68, 8, 44, 8, 27);
  g.arc(28, 27, 20, Math.PI, 0);
  g.bezierCurveTo(48, 44, 28, 68, 28, 68);
  g.closePath();
  g.fillStyle = color; g.fill();
  g.shadowColor = 'transparent';
  g.lineWidth = 2.5; g.strokeStyle = '#ffffff'; g.stroke();
  g.beginPath(); g.arc(28, 27, 15, 0, 2 * Math.PI); g.fillStyle = '#ffffff'; g.fill();
  g.lineWidth = 2; g.strokeStyle = '#111111';
  g.beginPath(); g.moveTo(18, 15); g.lineTo(18, 38); g.stroke();       // mât
  for (let r = 0; r < 3; r++) for (let q = 0; q < 4; q++) {           // damier 4x3
    g.fillStyle = (r + q) % 2 ? '#ffffff' : '#111111';
    g.fillRect(19 + q * 4, 17 + r * 4, 4, 4);
  }
  g.lineWidth = 1; g.strokeStyle = '#111111'; g.strokeRect(19, 17, 16, 12);
  return g.getImageData(0, 0, W * 2, H * 2);
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
      paint: { 'line-color': '#ffffff', 'line-width': trackWidth + 3.5, 'line-opacity': 0.9 } });
    map.addLayer({ id: 'track-line', type: 'line', source: 'track',
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': trackColor, 'line-width': trackWidth } });
  }

  buildCam();
  if (!map.getSource('pins')) {
    map.addImage('pin-start', pinImage('#22c55e'), { pixelRatio: 2 });
    map.addImage('pin-end', pinImage('#ef4444'), { pixelRatio: 2 });
    map.addSource('pins', { type: 'geojson', data: pinsGeo(false) });
    map.addLayer({ id: 'pins', type: 'symbol', source: 'pins', layout: {
      'icon-image': ['get', 'icon'], 'icon-anchor': 'bottom', 'icon-size': 0.7,
      'icon-allow-overlap': true, 'icon-ignore-placement': true } });
  } else {
    map.getSource('pins').setData(pinsGeo(false));
  }
  recenter();
}

// Le repère attend au départ : on n'affiche alors que l'arrivée, le départ revient dès qu'il roule.
function pinsGeo(showStart) {
  const pt = (icon, p) => ({ type: 'Feature', properties: { icon },
    geometry: { type: 'Point', coordinates: [p[0], p[1]] } });
  const f = [pt('pin-end', coords[coords.length - 1])];
  if (showStart) f.push(pt('pin-start', coords[0]));
  return { type: 'FeatureCollection', features: f };
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

function setTrackStyle(color, width) {
  trackColor = color; trackWidth = width;
  if (map.getLayer('track-line')) {
    map.setPaintProperty('track-line', 'line-color', color);
    map.setPaintProperty('track-line', 'line-width', width);
    map.setPaintProperty('track-casing', 'line-width', width + 3.5);
  }
}

function setMarkerColor(color) {
  markerColor = color;
  refreshDot();
}

function setMarker(kind) {
  markerKind = kind;
  refreshDot();
}

function setBase(satellite) {
  map.setLayoutProperty('sat', 'visibility', satellite ? 'visible' : 'none');
  map.setLayoutProperty('plan', 'visibility', satellite ? 'none' : 'visible');
  map.setPaintProperty('hillshade', 'hillshade-exaggeration', satellite ? 0.35 : 0.6);
}

// ---------- Repère ----------
// Le repère est une couche du canvas (et non un Marker DOM) : il apparaît dans la vidéo
// et reste affiché au départ quand la trace est chargée.
function removeDot() {
  if (map.getLayer('dot')) map.removeLayer('dot');
  if (map.getSource('dot')) map.removeSource('dot');
}

function placeDot(p, k) {
  lastP = p;
  const f = { type: 'Feature', geometry: { type: 'Point', coordinates: [p[0], p[1]] } };
  if (map.getSource('dot')) map.getSource('dot').setData(f);
  else map.addSource('dot', { type: 'geojson', data: f });
  if (markerKind === 'bike') {
    if (bikeColor !== markerColor) {
      bikeFrames(markerColor).forEach((img, i) => {
        if (map.hasImage('bike' + i)) map.removeImage('bike' + i);
        map.addImage('bike' + i, img, { pixelRatio: 2 });
      });
      bikeColor = markerColor;
    }
    if (!map.getLayer('dot')) {
      map.addLayer({ id: 'dot', type: 'symbol', source: 'dot', layout: {
        'icon-image': 'bike' + k, 'icon-anchor': 'bottom', 'icon-size': 0.85,
        'icon-allow-overlap': true, 'icon-ignore-placement': true } });
      frameK = k;
    } else if (frameK !== k) {
      map.setLayoutProperty('dot', 'icon-image', 'bike' + k);
      frameK = k;
    }
  } else if (!map.getLayer('dot')) {
    map.addLayer({ id: 'dot', type: 'circle', source: 'dot', paint: {
      'circle-radius': 9, 'circle-color': '#ffffff',
      'circle-stroke-color': markerColor, 'circle-stroke-width': 4 } });
  }
}

// Change de style de repère : on le recrée tout de suite à sa position actuelle.
function refreshDot() {
  removeDot();
  if (lastP) placeDot(lastP, 0);
}

// ---------- Survol 3D ----------
const lerp = (a, b, k) => a + (b - a) * k;

// speed : 1, 2, 5, 10, 15 ; record : enregistre le canvas et l'envoie à Flutter
function startFly(speed, record) {
  if (!coords.length) return;
  stopFly(true);
  map.stop();
  if (record && !startRec()) { Bridge.postMessage('flyEnd'); return; }

  // ~5 s par km, entre 25 s et 90 s à x1
  const dur = Math.min(90000, Math.max(25000, (total / 1000) * 5000)) / (speed || 1);
  const look = Math.min(400, Math.max(80, total * 0.01)); // m devant le repère pour le cap
  const SMOOTH = 150, INTRO = 1600;                       // lissage du cap (m) ; fondu d'entrée (ms)
  const from = { c: map.getCenter(), z: map.getZoom(), p: map.getPitch(), b: map.getBearing() };
  let last = null, t = 0, brg = null, prevD = 0;

  map.getSource('pins').setData(pinsGeo(true));

  const step = (ts) => {
    if (last === null) last = ts;
    t += Math.min(ts - last, 40); // un à-coup de rendu ralentit le film au lieu de le faire sauter
    last = ts;
    if (t >= dur) { finishFly(); return; }
    const d = (t / dur) * cam.total;
    const p = pointAt(d, cam);
    const target = bearing(p, pointAt(Math.min(cam.total, d + look), cam));
    // lissage selon la distance parcourue : même rendu quelle que soit la vitesse ou la fréquence d'images
    brg = brg === null ? target : lerpAngle(brg, target, 1 - Math.exp(-(d - prevD) / SMOOTH));
    prevD = d;
    const k = Math.min(1, t / INTRO), e = k * k * (3 - 2 * k); // fondu depuis la vue actuelle
    map.jumpTo({
      center: [lerp(from.c.lng, p[0], e), lerp(from.c.lat, p[1], e)],
      bearing: lerpAngle(from.b, brg, e),
      pitch: lerp(from.p, 68, e),
      zoom: lerp(from.z, 14.8, e)
    });
    placeDot(p, Math.floor(t / 70) % BIKE_FRAMES); // un tour de pédale ≈ 0,84 s
    anim = requestAnimationFrame(step);
  };
  anim = requestAnimationFrame(step);
}

function stopFly(silent) {
  if (anim) { cancelAnimationFrame(anim); anim = null; }
  if (rec) { rec.discard = true; if (rec.state !== 'inactive') rec.stop(); }
  if (coords.length) {
    map.getSource('pins')?.setData(pinsGeo(false));
    placeDot(coords[0], 0);
  }
  if (!silent && window.Bridge) Bridge.postMessage('flyEnd');
}

function finishFly() {
  const r = rec;
  rec = null; // détaché pour que stopFly ne l'annule pas
  stopFly(true);
  if (r) { Bridge.postMessage('encoding'); r.stop(); }
  else if (window.Bridge) Bridge.postMessage('flyEnd');
  recenter();
}

// ---------- Enregistrement vidéo ----------
function startRec() {
  const types = ['video/mp4;codecs=avc1', 'video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'];
  const mime = window.MediaRecorder && types.find(t => MediaRecorder.isTypeSupported(t));
  if (!mime) { Bridge.postMessage('verr:Enregistrement vidéo non supporté par cette WebView.'); return false; }
  const chunks = [];
  // Copie du canvas de la carte à dimensions paires (H.264 refuse une hauteur impaire) et ≤ 1280 px.
  const src = map.getCanvas(), sc = Math.min(1, 1280 / Math.max(src.width, src.height));
  const out = document.createElement('canvas');
  out.width = Math.floor(src.width * sc / 2) * 2;
  out.height = Math.floor(src.height * sc / 2) * 2;
  const g = out.getContext('2d');
  const draw = () => g.drawImage(src, 0, 0, out.width, out.height);
  map.on('render', draw);
  const r = new MediaRecorder(out.captureStream(30), { mimeType: mime, videoBitsPerSecond: 6000000 });
  r.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
  r.onerror = () => { stopFly(true); Bridge.postMessage("verr:Échec de l'encodage vidéo."); };
  r.onstop = () => {
    map.off('render', draw);
    if (rec === r) rec = null;
    if (r.discard) return;
    if (!chunks.length) { Bridge.postMessage("verr:La vidéo est vide."); return; }
    const fr = new FileReader();
    fr.onerror = () => Bridge.postMessage('verr:Lecture de la vidéo impossible.');
    fr.onload = () => {
      const b64 = fr.result.split(',')[1], CH = 1 << 19; // multiple de 4 : chaque morceau se décode seul
      for (let i = 0; i < b64.length; i += CH) Bridge.postMessage('vchunk:' + b64.slice(i, i + CH));
      Bridge.postMessage('vend:' + (mime.includes('mp4') ? 'mp4' : 'webm'));
    };
    fr.readAsDataURL(new Blob(chunks, { type: mime }));
  };
  r.discard = false;
  rec = r;
  r.start(1000);
  return true;
}
</script>
</body>
</html>
''';
