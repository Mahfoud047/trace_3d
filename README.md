# Trace 3D (Flutter)

Application mobile (Android + iOS) qui lit un fichier **GPX** ou **TCX** et affiche le parcours sur une carte **3D avec relief**, avec :

- statistiques : distance, vitesse moyenne / max, dénivelé + / −, altitude min / max, durée
- profil d'altitude
- survol 3D animé le long du tracé (type « fly-through » Strava / Komoot)
- fond satellite ou plan

## Installation

```bash
git clone https://github.com/Mahfoud047/trace_3d.git
cd trace_3d
flutter pub get
flutter run            # ou: flutter run -d <id>  (voir `flutter devices`)
```

Si une dépendance pose problème de version : `flutter pub upgrade --major-versions`.

### Android : notes de build

- `android/build.gradle.kts` force `compileSdk` 36 sur les plugins (`file_picker` est compilé en 34 alors que `flutter_plugin_android_lifecycle` exige 36). À retirer quand les plugins seront à jour.
- Xiaomi / MIUI : activer **Options pour les développeurs → Installer via USB** (et le débogage USB), sinon l'installation échoue avec `INSTALL_FAILED_USER_RESTRICTED`.

### Android : autoriser Internet en release

Dans `android/app/src/main/AndroidManifest.xml`, ajoute avant `<application>` :

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

### Tester

Le fichier `sample/demo.gpx` est une boucle de démonstration près de Grenoble. Copie-le sur le téléphone (Fichiers / Drive) puis ouvre-le depuis l'app.

## Architecture

| Fichier | Rôle |
|---|---|
| `lib/track.dart` | Lecture GPX/TCX, calcul des stats (haversine, dénivelé lissé avec seuil de 3 m, vitesse max sur 10 s) |
| `lib/map_html.dart` | Carte 3D MapLibre GL JS (relief, ombrage, ciel, tracé, survol) chargée dans une WebView |
| `lib/main.dart` | Interface Flutter : sélection de fichier, panneau de stats, profil d'altitude, boutons |

La carte tourne dans une WebView car MapLibre GL JS gère le relief 3D, l'inclinaison de la caméra et le ciel de façon bien plus complète que les plugins Flutter natifs actuels.

## Sources de données (à connaître avant de publier)

Par défaut, l'app utilise des sources gratuites **adaptées au prototypage** :

- relief : AWS Terrain Tiles (gratuit)
- satellite : Esri World Imagery
- plan : tuiles OpenStreetMap

Pour une application publiée, remplace-les (bloc `CONFIG` dans `lib/map_html.dart`) par un fournisseur avec offre gratuite et conditions d'usage adaptées : **MapTiler**, **Stadia Maps** ou **Mapbox** (clé API). Les tuiles OSM officielles et Esri ne sont pas prévues pour un usage intensif en production.

## Pistes d'amélioration

- format FIT (`fit_tool`), export GPX
- cartes hors ligne (tuiles PMTiles)
- tracé coloré selon la pente ou la vitesse
- ouverture directe d'un GPX depuis un partage / une autre app
