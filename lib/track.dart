import 'dart:math' as math;

import 'package:xml/xml.dart';

/// Un point de la trace.
class TrackPoint {
  const TrackPoint(this.lat, this.lon, {this.ele, this.time});

  final double lat;
  final double lon;
  final double? ele;
  final DateTime? time;
}

/// Seuil d'hystérésis (m) pour le dénivelé : limite le bruit GPS.
const _gainThresholdM = 3.0;

double _rad(double d) => d * math.pi / 180.0;

/// Distance entre deux points GPS, en mètres.
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final s1 = math.sin(dLat / 2);
  final s2 = math.sin(dLon / 2);
  final a = s1 * s1 + math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * s2 * s2;
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}

class TrackStats {
  const TrackStats({
    required this.distanceM,
    this.elevationGainM,
    this.elevationLossM,
    this.minEleM,
    this.maxEleM,
    this.elapsed,
    this.moving,
    this.avgSpeedKmh,
    this.maxSpeedKmh,
  });

  final double distanceM;
  final double? elevationGainM;
  final double? elevationLossM;
  final double? minEleM;
  final double? maxEleM;
  final Duration? elapsed;
  final Duration? moving;
  final double? avgSpeedKmh;
  final double? maxSpeedKmh;
}

class ProfileSample {
  const ProfileSample(this.km, this.ele);
  final double km;
  final double ele;
}

class Track {
  Track._({
    required this.name,
    required this.points,
    required this.cumDistM,
    required this.smoothEle,
    required this.stats,
  });

  final String name;
  final List<TrackPoint> points;
  final List<double> cumDistM;
  final List<double>? smoothEle;
  final TrackStats stats;

  bool get hasElevation => smoothEle != null;

  factory Track.fromPoints(String name, List<TrackPoint> pts) {
    if (pts.length < 2) {
      throw const FormatException('La trace contient moins de 2 points.');
    }
    final n = pts.length;

    // Distance cumulée
    final cum = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      cum[i] = cum[i - 1] +
          haversineM(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    }

    // Altitude lissée + dénivelé avec seuil d'hystérésis (limite le bruit GPS)
    final sm = _smoothElevations(pts);
    double? gain, loss, minE, maxE;
    if (sm != null) {
      const threshold = _gainThresholdM;
      var g = 0.0;
      var l = 0.0;
      var ref = sm[0];
      for (var i = 1; i < n; i++) {
        final d = sm[i] - ref;
        if (d >= threshold) {
          g += d;
          ref = sm[i];
        } else if (d <= -threshold) {
          l -= d;
          ref = sm[i];
        }
      }
      gain = g;
      loss = l;
      minE = sm.reduce(math.min);
      maxE = sm.reduce(math.max);
    }

    // Temps et vitesses
    Duration? elapsed;
    Duration? moving;
    double? avg;
    double? vmax;
    final hasTime = pts.every((p) => p.time != null);
    if (hasTime) {
      final secs =
          pts.map((p) => p.time!.millisecondsSinceEpoch / 1000.0).toList();
      final total = secs.last - secs.first;
      if (total > 0) {
        elapsed = Duration(seconds: total.round());

        var movingSec = 0.0;
        var movingDist = 0.0;
        for (var i = 1; i < n; i++) {
          final dt = secs[i] - secs[i - 1];
          if (dt <= 0 || dt > 120) continue; // pause ou trou GPS
          final d = cum[i] - cum[i - 1];
          if (d / dt >= 0.3) {
            movingSec += dt;
            movingDist += d;
          }
        }
        if (movingSec > 0) {
          moving = Duration(seconds: movingSec.round());
          avg = movingDist / movingSec * 3.6;
        }

        // Vitesse max sur des fenêtres d'au moins 10 s (évite les pics GPS)
        var j = 0;
        double best = 0;
        for (var i = 0; i < n - 1; i++) {
          if (j <= i) j = i + 1;
          while (j < n && secs[j] - secs[i] < 10) {
            j++;
          }
          if (j >= n) break;
          final dt = secs[j] - secs[i];
          if (dt <= 0 || dt > 60) continue;
          final v = (cum[j] - cum[i]) / dt * 3.6;
          if (v > best) best = v;
        }
        if (best > 0) vmax = best;
      }
    }

    return Track._(
      name: name,
      points: pts,
      cumDistM: cum,
      smoothEle: sm,
      stats: TrackStats(
        distanceM: cum.last,
        elevationGainM: gain,
        elevationLossM: loss,
        minEleM: minE,
        maxEleM: maxE,
        elapsed: elapsed,
        moving: moving,
        avgSpeedKmh: avg,
        maxSpeedKmh: vmax,
      ),
    );
  }

  static List<double>? _smoothElevations(List<TrackPoint> pts) {
    final n = pts.length;
    final raw = pts.map((p) => p.ele).toList();
    if (raw.every((e) => e == null)) return null;

    // Comble les trous
    double? prev = raw.firstWhere((e) => e != null);
    final filled = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      if (raw[i] != null) prev = raw[i];
      filled[i] = prev!;
    }

    // Moyenne glissante sur 5 points
    const half = 2;
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final lo = math.max(0, i - half);
      final hi = math.min(n - 1, i + half);
      var sum = 0.0;
      for (var k = lo; k <= hi; k++) {
        sum += filled[k];
      }
      out[i] = sum / (hi - lo + 1);
    }
    return out;
  }

  /// Coordonnées [lon, lat, alt] envoyées à la carte (décimées si trop nombreuses).
  List<List<double>> toCoordinates({int maxPoints = 5000}) =>
      [for (final i in _indices(maxPoints)) _coord(i)];

  /// Indices des points envoyés à la carte (décimation régulière, dernier point inclus).
  List<int> _indices(int maxPoints) {
    final n = points.length;
    final step = (n / maxPoints).ceil().clamp(1, n);
    return [
      for (var i = 0; i < n; i += step) i,
      if ((n - 1) % step != 0) n - 1,
    ];
  }

  /// Séries pour l'affichage pendant la vidéo, aux mêmes indices que [toCoordinates] :
  /// distance cumulée (m), altitude (m), dénivelé positif cumulé (m) et vitesse (km/h, lissée sur ~10 s).
  Map<String, Object?> hudSeries({int maxPoints = 5000}) {
    final n = points.length;
    final idx = _indices(maxPoints);
    double r1(double v) => double.parse(v.toStringAsFixed(1));

    final gain = List<double>.filled(n, 0);
    final sm = smoothEle;
    if (sm != null) {
      var g = 0.0, ref = sm[0];
      for (var i = 1; i < n; i++) {
        final d = sm[i] - ref;
        if (d >= _gainThresholdM) {
          g += d;
          ref = sm[i];
        } else if (d <= -_gainThresholdM) {
          ref = sm[i];
        }
        gain[i] = g;
      }
    }

    List<double>? speed;
    if (points.every((p) => p.time != null)) {
      final t = [for (final p in points) p.time!.millisecondsSinceEpoch / 1000.0];
      speed = List<double>.filled(n, 0);
      var lo = 0, hi = 0;
      for (var i = 0; i < n; i++) {
        while (lo < i && t[i] - t[lo] > 5) {
          lo++;
        }
        if (hi < i) hi = i;
        while (hi < n - 1 && t[hi] - t[i] < 5) {
          hi++;
        }
        final dt = t[hi] - t[lo];
        speed[i] = dt > 0 ? (cumDistM[hi] - cumDistM[lo]) / dt * 3.6 : 0;
      }
    }

    return {
      'd': [for (final i in idx) r1(cumDistM[i])],
      'g': sm == null ? null : [for (final i in idx) r1(gain[i])],
      'e': sm == null ? null : [for (final i in idx) r1(sm[i])],
      'v': speed == null ? null : [for (final i in idx) r1(speed[i])],
      'avg': stats.avgSpeedKmh == null ? null : r1(stats.avgSpeedKmh!),
    };
  }

  List<double> _coord(int i) {
    final p = points[i];
    return [
      double.parse(p.lon.toStringAsFixed(6)),
      double.parse(p.lat.toStringAsFixed(6)),
      double.parse((smoothEle?[i] ?? 0).toStringAsFixed(1)),
    ];
  }

  /// Profil d'altitude pour le graphique.
  List<ProfileSample> profile({int maxPoints = 250}) {
    final sm = smoothEle;
    if (sm == null) return const [];
    final n = points.length;
    final step = (n / maxPoints).ceil().clamp(1, n);
    final out = <ProfileSample>[];
    for (var i = 0; i < n; i += step) {
      out.add(ProfileSample(cumDistM[i] / 1000, sm[i]));
    }
    if ((n - 1) % step != 0) {
      out.add(ProfileSample(cumDistM[n - 1] / 1000, sm[n - 1]));
    }
    return out;
  }
}

/// Lecture des formats GPX et TCX.
class TrackParser {
  static Track parse(String content, {String? fileName}) {
    final text = content.replaceFirst('﻿', '').trim();
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } catch (_) {
      throw const FormatException(
          'Fichier illisible : ce n\'est pas un GPX/TCX valide.');
    }

    final root = doc.rootElement.name.local.toLowerCase();
    final fallbackName = _baseName(fileName) ?? 'Trace';

    if (root == 'gpx') {
      final name = doc
              .findAllElements('trk')
              .firstOrNull
              ?.getElement('name')
              ?.innerText
              .trim() ??
          doc.findAllElements('name').firstOrNull?.innerText.trim() ??
          fallbackName;
      return Track.fromPoints(
          name.isEmpty ? fallbackName : name, _parseGpx(doc));
    }
    if (root == 'trainingcenterdatabase') {
      return Track.fromPoints(fallbackName, _parseTcx(doc));
    }
    throw FormatException(
        'Format non pris en charge (<$root>). Utilise un fichier GPX ou TCX.');
  }

  static String? _baseName(String? f) {
    if (f == null || f.isEmpty) return null;
    final i = f.lastIndexOf('.');
    return i > 0 ? f.substring(0, i) : f;
  }

  static List<TrackPoint> _parseGpx(XmlDocument doc) {
    var nodes = doc.findAllElements('trkpt').toList();
    if (nodes.isEmpty) nodes = doc.findAllElements('rtept').toList();

    final pts = <TrackPoint>[];
    for (final e in nodes) {
      final lat = double.tryParse(e.getAttribute('lat') ?? '');
      final lon = double.tryParse(e.getAttribute('lon') ?? '');
      if (!_valid(lat, lon)) continue;
      final ele = double.tryParse(e.getElement('ele')?.innerText.trim() ?? '');
      final time = DateTime.tryParse(e.getElement('time')?.innerText.trim() ?? '');
      pts.add(TrackPoint(lat!, lon!, ele: ele, time: time));
    }
    return pts;
  }

  static List<TrackPoint> _parseTcx(XmlDocument doc) {
    final pts = <TrackPoint>[];
    for (final e in doc.findAllElements('Trackpoint')) {
      final pos = e.getElement('Position');
      if (pos == null) continue;
      final lat =
          double.tryParse(pos.getElement('LatitudeDegrees')?.innerText.trim() ?? '');
      final lon =
          double.tryParse(pos.getElement('LongitudeDegrees')?.innerText.trim() ?? '');
      if (!_valid(lat, lon)) continue;
      final ele =
          double.tryParse(e.getElement('AltitudeMeters')?.innerText.trim() ?? '');
      final time = DateTime.tryParse(e.getElement('Time')?.innerText.trim() ?? '');
      pts.add(TrackPoint(lat!, lon!, ele: ele, time: time));
    }
    return pts;
  }

  static bool _valid(double? lat, double? lon) =>
      lat != null &&
      lon != null &&
      lat >= -90 &&
      lat <= 90 &&
      lon >= -180 &&
      lon <= 180;
}
