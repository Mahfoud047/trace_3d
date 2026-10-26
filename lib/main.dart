import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'map_html.dart';
import 'track.dart';

const _bg = Color(0xFF0E1116);
const _surface = Color(0xFF171B22);
const _accent = Color(0xFFFC4C02);

void main() => runApp(const TraceApp());

class TraceApp extends StatelessWidget {
  const TraceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trace 3D',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _accent,
          brightness: Brightness.dark,
        ),
      ),
      home: const MapPage(),
    );
  }
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  late final WebViewController _web;
  Track? _track;
  bool _pageReady = false;
  bool _flying = false;
  bool _satellite = true;
  bool _recording = false;
  int _speed = 1;
  Color _trackColor = _accent;
  double _trackWidth = 4.5;
  bool _bike = true;
  Color _markerColor = const Color(0xFFEAB308);
  final _video = BytesBuilder(copy: false);

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_bg)
      ..addJavaScriptChannel(
        'Bridge',
        onMessageReceived: (m) => _onBridge(m.message),
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _pageReady = true;
          if (_track != null) _sendTrack();
        },
      ))
      ..loadHtmlString(mapHtml, baseUrl: 'https://app.local/');
  }

  void _onBridge(String msg) {
    if (!mounted) return;
    if (msg == 'flyEnd') {
      setState(() => _flying = _recording = false);
    } else if (msg == 'encoding') {
      setState(() => _flying = false);
      _toast('Encodage de la vidéo…');
    } else if (msg.startsWith('vchunk:')) {
      _video.add(base64Decode(msg.substring(7)));
    } else if (msg.startsWith('vend:')) {
      _saveVideo(msg.substring(5));
    } else if (msg.startsWith('verr:')) {
      _video.clear();
      setState(() => _flying = _recording = false);
      _toast(msg.substring(5));
    }
  }

  Future<void> _saveVideo(String ext) async {
    final file = File(
        '${Directory.systemTemp.path}/trace3d_${DateTime.now().millisecondsSinceEpoch}.$ext');
    try {
      await file.writeAsBytes(_video.takeBytes());
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      await Gal.putVideo(file.path);
      _toast('Vidéo enregistrée dans la galerie.');
    } catch (e) {
      _toast("Erreur d'enregistrement : $e");
    } finally {
      if (file.existsSync()) file.deleteSync();
      if (mounted) setState(() => _recording = false);
    }
  }

  void _sendTrack() {
    final t = _track;
    if (t == null) return;
    _web.runJavaScript('loadTrack(${jsonEncode(t.toCoordinates())});');
  }

  Future<void> _openFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (res == null) return;
      final f = res.files.single;
      final bytes = f.bytes;
      if (bytes == null) {
        _toast('Impossible de lire ce fichier.');
        return;
      }
      final track = TrackParser.parse(
        utf8.decode(bytes, allowMalformed: true),
        fileName: f.name,
      );
      setState(() {
        _track = track;
        _flying = _recording = false;
      });
      if (_pageReady) _sendTrack();
    } on FormatException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('Erreur : $e');
    }
  }

  void _toggleFly() {
    if (_track == null) return;
    if (_flying) {
      _web.runJavaScript('stopFly(true);');
      setState(() => _flying = _recording = false);
    } else {
      _web.runJavaScript('startFly($_speed, false);');
      setState(() => _flying = true);
    }
  }

  void _recordVideo() {
    if (_track == null || _flying || _recording) return;
    _video.clear();
    _web.runJavaScript('startFly($_speed, true);');
    setState(() => _flying = _recording = true);
  }

  String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  void _applyStyle() {
    _web.runJavaScript("setTrackStyle('${_hex(_trackColor)}', $_trackWidth);");
  }

  void _setMarkerColor(Color c) {
    setState(() => _markerColor = c);
    _web.runJavaScript("setMarkerColor('${_hex(c)}');");
  }

  void _setBike(bool bike) {
    setState(() => _bike = bike);
    _web.runJavaScript("setMarker('${bike ? 'bike' : 'circle'}');");
  }

  void _recenter() {
    _web.runJavaScript('recenter();');
    if (_flying || _recording) setState(() => _flying = _recording = false);
  }

  void _toggleBase() {
    setState(() => _satellite = !_satellite);
    _web.runJavaScript('setBase($_satellite);');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: _settingsDrawer(),
      body: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: _web)),
          SafeArea(
            child: Builder(
              builder: (ctx) => Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton.filledTonal(
                  tooltip: 'Réglages',
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                  icon: const Icon(Icons.menu),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _surface.withAlpha(235),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: _track == null ? _emptyPanel() : _trackPanel(_track!),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsDrawer() {
    const colors = [
      _accent,
      Color(0xFFEF4444),
      Color(0xFFEAB308),
      Color(0xFF22C55E),
      Color(0xFF06B6D4),
      Color(0xFF3B82F6),
      Color(0xFFA855F7),
      Color(0xFFEC4899),
    ];
    Widget swatches(Color selected, void Function(Color) onPick) => Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in colors)
              GestureDetector(
                onTap: () => onPick(c),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: c,
                  child: c == selected
                      ? const Icon(Icons.check, color: Colors.white)
                      : null,
                ),
              ),
          ],
        );
    return Drawer(
      backgroundColor: _surface,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Réglages',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 20),
            const Text('Couleur du tracé', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            swatches(_trackColor, (c) {
              setState(() => _trackColor = c);
              _applyStyle();
            }),
            const SizedBox(height: 24),
            Text('Largeur du tracé : ${_fmt(_trackWidth)} px',
                style: const TextStyle(color: Colors.white70)),
            Slider(
              min: 2,
              max: 12,
              divisions: 20,
              value: _trackWidth,
              onChanged: (v) => setState(() => _trackWidth = v),
              onChangeEnd: (_) => _applyStyle(),
            ),
            const SizedBox(height: 16),
            const Text('Repère de navigation', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Cercle')),
                ButtonSegment(value: true, label: Text('Cycliste')),
              ],
              selected: {_bike},
              onSelectionChanged: (v) => _setBike(v.first),
            ),
            const SizedBox(height: 20),
            Text(_bike ? 'Couleur du cycliste' : 'Couleur du cercle',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            swatches(_markerColor, _setMarkerColor),
          ],
        ),
      ),
    );
  }

  Widget _emptyPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Trace 3D',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        const Text(
          'Ouvre un fichier GPX ou TCX pour voir ton parcours en 3D.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _openFile,
          icon: const Icon(Icons.folder_open),
          label: const Text('Ouvrir un fichier'),
        ),
      ],
    );
  }

  Widget _trackPanel(Track t) {
    final s = t.stats;
    final secondary = <String>[
      if (s.maxSpeedKmh != null) 'Vmax ${_fmt(s.maxSpeedKmh!)} km/h',
      if (s.elevationLossM != null) 'D− ${s.elevationLossM!.round()} m',
      if (s.minEleM != null && s.maxEleM != null)
        'Alt. ${s.minEleM!.round()}–${s.maxEleM!.round()} m',
      if (s.moving != null) 'En mouvement ${_fmtDur(s.moving!)}',
      if (s.moving == null && s.elapsed != null) _fmtDur(s.elapsed!),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _Tile(label: 'DISTANCE', value: _fmt(s.distanceM / 1000, 2), unit: 'km'),
            _Tile(
              label: 'VITESSE MOY.',
              value: s.avgSpeedKmh != null ? _fmt(s.avgSpeedKmh!) : '—',
              unit: 'km/h',
            ),
            _Tile(
              label: 'DÉNIVELÉ +',
              value: s.elevationGainM != null
                  ? s.elevationGainM!.round().toString()
                  : '—',
              unit: 'm',
            ),
          ],
        ),
        if (secondary.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(secondary.join('  ·  '),
              style: const TextStyle(color: Colors.white60, fontSize: 12.5)),
        ],
        if (t.hasElevation) ...[
          const SizedBox(height: 10),
          SizedBox(height: 70, child: _ElevationChart(samples: t.profile())),
        ],
        const SizedBox(height: 12),
        SegmentedButton<int>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [
            for (final v in const [1, 2, 5, 10, 15])
              ButtonSegment(value: v, label: Text('x$v')),
          ],
          selected: {_speed},
          onSelectionChanged: _flying || _recording
              ? null
              : (v) => setState(() => _speed = v.first),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _toggleFly,
                icon: Icon(_flying ? Icons.stop : Icons.play_arrow),
                label: Text(_flying ? 'Arrêter' : 'Survol 3D'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Générer une vidéo (x$_speed)',
              onPressed: _flying || _recording ? null : _recordVideo,
              icon: _recording
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.videocam),
            ),
            IconButton.filledTonal(
              tooltip: 'Recentrer',
              onPressed: _recenter,
              icon: const Icon(Icons.center_focus_strong),
            ),
            IconButton.filledTonal(
              tooltip: _satellite ? 'Passer en plan' : 'Passer en satellite',
              onPressed: _toggleBase,
              icon: Icon(_satellite ? Icons.map_outlined : Icons.satellite_alt),
            ),
            IconButton.filledTonal(
              tooltip: 'Ouvrir un autre fichier',
              onPressed: _openFile,
              icon: const Icon(Icons.folder_open),
            ),
          ],
        ),
      ],
    );
  }
}

String _fmt(double v, [int decimals = 1]) =>
    v.toStringAsFixed(decimals).replaceAll('.', ',');

String _fmtDur(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '$h h ${m.toString().padLeft(2, '0')}' : '$m min';
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, required this.unit});

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10.5, letterSpacing: 0.6, color: Colors.white54)),
          const SizedBox(height: 2),
          Text.rich(TextSpan(children: [
            TextSpan(
                text: value,
                style:
                    const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            TextSpan(
                text: ' $unit',
                style: const TextStyle(fontSize: 12, color: Colors.white60)),
          ])),
        ],
      ),
    );
  }
}

class _ElevationChart extends StatelessWidget {
  const _ElevationChart({required this.samples});

  final List<ProfileSample> samples;

  @override
  Widget build(BuildContext context) {
    if (samples.length < 2) return const SizedBox.shrink();
    final ys = samples.map((s) => s.ele);
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    final pad = ((maxY - minY) * 0.1).clamp(2.0, 1000.0);

    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        lineBarsData: [
          LineChartBarData(
            spots: [for (final s in samples) FlSpot(s.km, s.ele)],
            isCurved: true,
            curveSmoothness: 0.15,
            barWidth: 2,
            color: _accent,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: true, color: _accent.withAlpha(50)),
          ),
        ],
      ),
    );
  }
}
