import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';

const videoExt = ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'ts', 'm4v'];
const resRank = {'4K': 0, '1080p': 1, '720p': 2, '480p': 3, '360p': 4, '': 5};
final _resRe = RegExp(r'(2160p|4k|1080p|720p|480p|360p)', caseSensitive: false);
final _yearRe = RegExp(r'^(.*?)[\s._\(\[-]*((?:19|20)\d{2})');
final _junkRe = RegExp(r'sample|trailer|promo', caseSensitive: false);

class Server {
  String name, url;
  Server(this.name, this.url);
  Map<String, dynamic> toJson() => {'n': name, 'u': url};
  factory Server.fromJson(Map<String, dynamic> j) => Server(j['n'], j['u']);
}

class Movie {
  final String name, url, server;
  Movie(this.name, this.url, this.server);
  Map<String, dynamic> toJson() => {'t': name, 'u': url, 's': server};
  factory Movie.fromJson(Map<String, dynamic> j) => Movie(j['t'], j['u'], j['s']);
  String get _plain =>
      name.replaceAll(RegExp(r'\.[^.]+$'), '').replaceAll(RegExp(r'[._]'), ' ').trim();
  late final String clean = _clean();
  late final String lc = clean.toLowerCase();
  String _clean() {
    final m = _yearRe.firstMatch(_plain);
    return m == null ? _plain : '${m[1]!.trim()} (${m[2]})';
  }

  late final String key = _key();
  String _key() {
    final m = _yearRe.firstMatch(_plain);
    return m == null ? '' : '${m[1]!.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}${m[2]}';
  }

  late final String res = _res();
  String _res() {
    final m = _resRe.firstMatch(Uri.decodeFull(url));
    if (m == null) return '';
    final r = m[1]!.toLowerCase();
    return (r == '4k' || r == '2160p') ? '4K' : r;
  }
}

class Hist {
  final Movie m;
  int pos, dur, t;
  Hist(this.m, this.pos, this.dur, this.t);
  double get progress => dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0;
  bool get resumable => pos > 10000 && dur > 0 && pos < dur * 0.95;
  Map<String, dynamic> toJson() => {'m': m.toJson(), 'p': pos, 'd': dur, 't': t};
}

/// Watch later + watch history (saved on device).
class Store extends ChangeNotifier {
  static final i = Store._();
  Store._();
  late SharedPreferences prefs;
  List<Movie> later = [];
  List<Hist> hist = [];

  void init(SharedPreferences p) {
    prefs = p;
    later = (jsonDecode(p.getString('later') ?? '[]') as List).map((e) => Movie.fromJson(e)).toList();
    hist = (jsonDecode(p.getString('hist') ?? '[]') as List)
        .map((e) => Hist(Movie.fromJson(e['m']), e['p'], e['d'], e['t']))
        .toList();
    _idx();
    notifyListeners();
  }

  void _save({bool notify = true}) {
    _idx();
    prefs.setString('later', jsonEncode(later.map((e) => e.toJson()).toList()));
    prefs.setString('hist', jsonEncode(hist.map((e) => e.toJson()).toList()));
    if (notify) notifyListeners();
  }

  void flush() => notifyListeners();

  Set<String> _lu = {};
  Map<String, Hist> _hi = {};
  void _idx() {
    _lu = later.map((e) => e.url).toSet();
    _hi = {for (final h in hist) h.m.url: h};
  }

  bool isLater(Movie m) => _lu.contains(m.url);
  void toggleLater(Movie m) {
    isLater(m) ? later.removeWhere((x) => x.url == m.url) : later.insert(0, m);
    _save();
  }

  Hist? find(String url) => _hi[url];

  void record(Movie m, int pos, int dur, {bool notify = false}) {
    var h = find(m.url);
    if (h == null) {
      h = Hist(m, pos, dur, 0);
      hist.insert(0, h);
      if (hist.length > 100) hist.removeLast();
    }
    h.pos = pos;
    h.dur = dur;
    h.t = DateTime.now().millisecondsSinceEpoch;
    hist.remove(h);
    hist.insert(0, h);
    _save(notify: notify);
  }

  void removeHist(Hist h) {
    hist.remove(h);
    _save();
  }

  void clearHist() {
    hist.clear();
    _save();
  }
}

class DownloadItem {
  final String title, url, path;
  int received = 0, total = 0;
  bool done = false, failed = false;
  http.Client? client;
  DownloadItem(this.title, this.url, this.path);
  Map<String, dynamic> toJson() => {'t': title, 'u': url, 'p': path};
}

class Downloads extends ChangeNotifier {
  static final i = Downloads._();
  Downloads._();
  final items = <DownloadItem>[];
  late SharedPreferences prefs;

  void init(SharedPreferences p) {
    prefs = p;
    items.clear();
    for (final e in jsonDecode(p.getString('dl') ?? '[]') as List) {
      if (File(e['p']).existsSync()) items.add(DownloadItem(e['t'], e['u'], e['p'])..done = true);
    }
    notifyListeners();
  }

  void _save() => prefs.setString(
      'dl', jsonEncode(items.where((d) => d.done).map((d) => d.toJson()).toList()));

  Future<void> start(Movie m) async {
    if (items.any((d) => d.url == m.url)) return;
    final base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/Movies');
    await dir.create(recursive: true);
    final d = DownloadItem(m.clean + (m.res.isEmpty ? '' : ' • ${m.res}'), m.url, '${dir.path}/${m.name}');
    items.insert(0, d);
    notifyListeners();
    final c = http.Client();
    d.client = c;
    try {
      final r = await c.send(http.Request('GET', Uri.parse(m.url)));
      d.total = r.contentLength ?? 0;
      final sink = File(d.path).openWrite();
      var last = DateTime.now();
      await for (final chunk in r.stream) {
        sink.add(chunk);
        d.received += chunk.length;
        if (DateTime.now().difference(last).inMilliseconds > 500) {
          last = DateTime.now();
          notifyListeners();
        }
      }
      await sink.close();
      d.done = true;
      _save();
    } catch (_) {
      d.failed = true;
      try {
        File(d.path).deleteSync();
      } catch (_) {}
    }
    c.close();
    notifyListeners();
  }

  void remove(DownloadItem d) {
    d.client?.close();
    try {
      File(d.path).deleteSync();
    } catch (_) {}
    items.remove(d);
    _save();
    notifyListeners();
  }
}

String _ago(int t) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(t));
  if (d.inMinutes < 1) return 'ekhon';
  if (d.inHours < 1) return '${d.inMinutes} min age';
  if (d.inDays < 1) return '${d.inHours} ghonta age';
  return '${d.inDays} din age';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(MaterialApp(
    title: 'FTP Movies',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorSchemeSeed: Colors.redAccent),
    home: const HomePage(),
  ));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Server> servers = [];
  List<Movie> movies = [];
  final _seen = <String>{};
  String query = '', resFilter = '', status = '';
  int tab = 0;
  bool scanning = false;
  List<Movie> view = [];
  Set<String> present = {};
  DateTime _last = DateTime(2000);
  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    Store.i.addListener(_r);
    _load();
  }

  void _r() => mounted ? setState(() {}) : null;

  @override
  void dispose() {
    Store.i.removeListener(_r);
    super.dispose();
  }

  Future<void> _load() async {
    prefs = await SharedPreferences.getInstance();
    Downloads.i.init(prefs);
    Store.i.init(prefs);
    setState(() {
      servers = (jsonDecode(prefs.getString('srv2') ?? '[]') as List).map((e) => Server.fromJson(e)).toList();
      movies = (jsonDecode(prefs.getString('mov3') ?? '[]') as List).map((e) => Movie.fromJson(e)).toList();
      _refilter();
    });
  }

  void _refilter() {
    final q = query.toLowerCase();
    view = movies.where((m) => (q.isEmpty || m.lc.contains(q)) && (resFilter.isEmpty || m.res == resFilter)).toList()
      ..sort((a, b) => a.lc.compareTo(b.lc));
    present = movies.map((m) => m.res).toSet();
  }

  void _tick() {
    final n = DateTime.now();
    if (!mounted || n.difference(_last).inMilliseconds < 1500) return;
    _last = n;
    setState(() {
      status = '${movies.length} ta movie pawa gese';
      _refilter();
    });
  }

  Future<void> _saveServers() =>
      prefs.setString('srv2', jsonEncode(servers.map((e) => e.toJson()).toList()));

  Future<void> _scan() async {
    setState(() {
      scanning = true;
      movies = [];
      _seen.clear();
    });
    await Future.wait(servers.map((s) async {
      final client = http.Client();
      var u = s.url.trim();
      if (!u.startsWith('http')) u = 'http://$u';
      if (!u.endsWith('/')) u = '$u/';
      await _crawl(client, s, Uri.parse(u), 0);
      client.close();
    }));
    await prefs.setString('mov3', jsonEncode(movies.map((e) => e.toJson()).toList()));
    setState(() {
      scanning = false;
      status = '';
      _refilter();
    });
  }

  Future<void> _crawl(http.Client c, Server s, Uri dir, int depth) async {
    if (depth > 3) return;
    String body;
    try {
      final r = await c.get(dir).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return;
      body = utf8.decode(r.bodyBytes, allowMalformed: true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${s.name}: connect hoy nai')));
      }
      return;
    }
    final links =
        RegExp('href="([^"]+)"', caseSensitive: false).allMatches(body).map((m) => m.group(1)!).toSet();
    final subs = <Uri>[];
    for (final raw in links) {
      if (raw.startsWith('?') || raw.startsWith('#') || raw.startsWith('..')) continue;
      Uri u;
      try {
        u = dir.resolve(raw);
      } catch (_) {
        continue;
      }
      // Ads / external links dropped: only same host + inside this folder.
      if (u.host != dir.host || !u.path.startsWith(dir.path) || u.path == dir.path) continue;
      if (u.path.endsWith('/')) {
        subs.add(u);
      } else {
        final name = u.pathSegments.isEmpty ? '' : u.pathSegments.last;
        if (videoExt.contains(name.split('.').last.toLowerCase()) &&
            !_junkRe.hasMatch(name) &&
            _seen.add(u.toString())) {
          movies.add(Movie(name, u.toString(), s.name));
          _tick();
        }
      }
    }
    for (var i = 0; i < subs.length; i += 6) {
      await Future.wait(subs.skip(i).take(6).map((u) => _crawl(c, s, u, depth + 1)));
    }
  }

  Future<void> _editServer([Server? old]) async {
    final n = TextEditingController(text: old?.name ?? '');
    final u = TextEditingController(text: old?.url ?? 'http://');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(old == null ? 'Server add' : 'Server edit'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: n, decoration: const InputDecoration(labelText: 'Name')),
          TextField(
              controller: u,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Movie folder URL')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || u.text.trim().length < 8) return;
    final s = Server(n.text.trim().isEmpty ? u.text.trim() : n.text.trim(), u.text.trim());
    setState(() => old != null ? servers[servers.indexOf(old)] = s : servers.add(s));
    await _saveServers();
  }

  void _play(Movie m) => Navigator.push(
      context, MaterialPageRoute(builder: (_) => PlayerPage(movie: m, all: movies)));

  void _download(Movie m) {
    var v = m.key.isEmpty ? <Movie>[] : movies.where((x) => x.key == m.key).toList();
    if (v.isEmpty) v = [m];
    v.sort((a, b) => resRank[a.res]!.compareTo(resRank[b.res]!));
    void go(Movie x) {
      Downloads.i.start(x);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download shuru hoyeche')));
    }

    if (v.length < 2) return go(v.first);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Download quality', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final x in v)
            ListTile(
              leading: const Icon(Icons.high_quality),
              title: Text(x.res.isEmpty ? 'Unknown quality' : x.res),
              subtitle: Text('${x.server} • ${x.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.pop(context);
                go(x);
              },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;
    const dests = [
      (Icons.movie_outlined, Icons.movie, 'Library'),
      (Icons.bookmark_border, Icons.bookmark, 'Later'),
      (Icons.history, Icons.history, 'History'),
      (Icons.download_outlined, Icons.download, 'Downloads'),
      (Icons.dns_outlined, Icons.dns, 'Servers'),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('FTP Movies', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (tab == 2 && Store.i.hist.isNotEmpty)
            IconButton(tooltip: 'Clear history', icon: const Icon(Icons.delete_sweep), onPressed: Store.i.clearHist),
          if (scanning)
            const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          else
            IconButton(
                tooltip: 'Scan all servers',
                icon: const Icon(Icons.refresh),
                onPressed: servers.isEmpty ? null : _scan),
        ],
      ),
      floatingActionButton: tab == 4
          ? FloatingActionButton.extended(
              onPressed: _editServer, icon: const Icon(Icons.add), label: const Text('Server'))
          : null,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: [
                for (final d in dests)
                  NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3)
              ]),
      body: Row(children: [
        if (wide)
          NavigationRail(
              selectedIndex: tab,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: [
                for (final d in dests)
                  NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3))
              ]),
        Expanded(child: [_library(), _later(), _history(), _downloads(), _serverList()][tab]),
      ]),
    );
  }

  static const _grid = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 200, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.7);

  Widget _library() {
    const order = ['4K', '1080p', '720p', '480p', '360p'];
    final cont = Store.i.hist.where((h) => h.resumable).take(10).toList();
    final list = view;
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: SearchBar(
            hintText: 'Movie search (${movies.length})',
            leading: const Icon(Icons.search),
            onChanged: (v) => setState(() {
              query = v;
              _refilter();
            }),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final r in ['', ...order.where(present.contains)])
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                child: ChoiceChip(
                    label: Text(r.isEmpty ? 'All' : r),
                    selected: resFilter == r,
                    onSelected: (_) => setState(() {
                      resFilter = r;
                      _refilter();
                    })),
              ),
          ]),
        ),
      ),
      if (scanning) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(8), child: Text(status))),
      if (cont.isNotEmpty && query.isEmpty) ...[
        const SliverToBoxAdapter(
            child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Continue watching', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)))),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 200,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (final h in cont)
                Padding(padding: const EdgeInsets.only(right: 12), child: SizedBox(width: 140, child: _card(h.m))),
            ]),
          ),
        ),
      ],
      if (list.isEmpty)
        SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text(servers.isEmpty ? 'Age Servers tab e server add koro' : 'Refresh (scan) button chap')))
      else
        SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverGrid.builder(gridDelegate: _grid, itemCount: list.length, itemBuilder: (_, i) => RepaintBoundary(child: _card(list[i]))),
        ),
    ]);
  }

  Widget _card(Movie m) {
    final c = HSLColor.fromAHSL(1, (m.clean.hashCode % 360).abs().toDouble(), .5, .28).toColor();
    final h = Store.i.find(m.url);
    final later = Store.i.isLater(m);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _play(m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                      gradient: LinearGradient(
                          colors: [c, Colors.black87], begin: Alignment.topLeft, end: Alignment.bottomRight)),
                  child: Center(
                      child: Text(m.clean.isEmpty ? '?' : m.clean[0].toUpperCase(),
                          style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w800, color: Colors.white54))),
                ),
              ),
              if (m.res.isNotEmpty)
                Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(6)),
                      child: Text(m.res, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    )),
              Positioned(
                  top: 0,
                  right: 0,
                  child: IconButton(
                    tooltip: 'Watch later',
                    icon: Icon(later ? Icons.bookmark : Icons.bookmark_border, color: later ? Colors.amber : Colors.white70),
                    onPressed: () => Store.i.toggleLater(m),
                  )),
                            Positioned(
                  right: 4,
                  bottom: 6,
                  child: IconButton.filledTonal(
                      iconSize: 18,
                      tooltip: 'Download',
                      icon: const Icon(Icons.download_rounded),
                      onPressed: () => _download(m))),
              if (h != null && h.progress > 0.01)
                Positioned(left: 0, right: 0, bottom: 0, child: LinearProgressIndicator(value: h.progress, minHeight: 3)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.clean, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(m.server, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _later() => Store.i.later.isEmpty
      ? const Center(child: Text('Watch later khali. Movie card e 🔖 chap.'))
      : GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: _grid,
          itemCount: Store.i.later.length,
          itemBuilder: (_, i) => _card(Store.i.later[i]));

  Widget _history() => Store.i.hist.isEmpty
      ? const Center(child: Text('Kono watch history nai'))
      : ListView(children: [
          for (final h in Store.i.hist)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.play_arrow)),
              title: Text(h.m.clean, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_ago(h.t)} • ${(h.progress * 100).round()}% dekha hoyeche'),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: h.progress),
              ]),
              onTap: () => _play(h.m),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => Store.i.removeHist(h)),
            ),
        ]);

  Widget _downloads() => ListenableBuilder(
        listenable: Downloads.i,
        builder: (_, __) {
          final items = Downloads.i.items;
          if (items.isEmpty) return const Center(child: Text('Kono download nai'));
          return ListView(children: [
            for (final d in items)
              ListTile(
                leading: Icon(d.failed ? Icons.error_outline : d.done ? Icons.play_circle : Icons.downloading),
                title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: d.done
                    ? const Text('Downloaded (offline dekha jabe)')
                    : d.failed
                        ? const Text('Fail hoyeche')
                        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const SizedBox(height: 6),
                            LinearProgressIndicator(value: d.total > 0 ? d.received / d.total : null),
                            Text('${(d.received / 1048576).toStringAsFixed(0)} MB'
                                '${d.total > 0 ? ' / ${(d.total / 1048576).toStringAsFixed(0)} MB' : ''}'),
                          ]),
                onTap: d.done ? () => _play(Movie(d.title, d.path, 'Downloaded')) : null,
                trailing: IconButton(
                    icon: Icon(d.done ? Icons.delete_outline : Icons.close), onPressed: () => Downloads.i.remove(d)),
              ),
          ]);
        },
      );

  Widget _serverList() => servers.isEmpty
      ? const Center(child: Text('Kono server nai. + chap.'))
      : ListView(children: [
          for (final s in servers)
            ListTile(
              leading: const Icon(Icons.dns),
              title: Text(s.name),
              subtitle: Text(s.url),
              onTap: () => _editServer(s),
              trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    setState(() {
                      servers.remove(s);
                      movies.removeWhere((m) => m.server == s.name);
                      _refilter();
                    });
                    await _saveServers();
                  }),
            ),
        ]);
}

class PlayerPage extends StatefulWidget {
  final Movie movie;
  final List<Movie> all;
  const PlayerPage({super.key, required this.movie, required this.all});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player player = Player(configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024));
  late final VideoController controller = VideoController(player);
  double volume = 100, bright = 0.5;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    final np = player.platform;
    if (np is NativePlayer) {
      np.setProperty('cache', 'yes');
      np.setProperty('demuxer-readahead-secs', '90');
    }
    ScreenBrightness().current.then((v) => bright = v).catchError((_) => 0.5);
    _start();
  }

  final hint = ValueNotifier<String?>(null);
  Timer? _hintT;

  void _skip(int sec) {
    var p = player.state.position + Duration(seconds: sec);
    final d = player.state.duration;
    if (p < Duration.zero) p = Duration.zero;
    if (d > Duration.zero && p > d) p = d;
    player.seek(p);
    hint.value = sec < 0 ? '-${-sec}s' : '+${sec}s';
    _hintT?.cancel();
    _hintT = Timer(const Duration(milliseconds: 600), () => hint.value = null);
  }

  Future<void> _start() async {
    final h = Store.i.find(widget.movie.url);
    await player.open(Media(widget.movie.url));
    if (h != null && h.resumable) {
      await player.stream.duration.firstWhere((d) => d > Duration.zero);
      await player.seek(Duration(milliseconds: h.pos));
    }
    _save();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _save());
  }

  void _save() {
    final d = player.state.duration.inMilliseconds;
    if (d > 0) Store.i.record(widget.movie, player.state.position.inMilliseconds, d);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _hintT?.cancel();
    _save();
    Store.i.flush();
    try {
      ScreenBrightness().resetScreenBrightness();
    } catch (_) {}
    player.dispose();
    super.dispose();
  }

  String _lbl(dynamic t, int i) {
    final p = <String>[];
    if (t.title != null) p.add(t.title);
    if (t.language != null) p.add(t.language);
    return p.isEmpty ? 'Track ${i + 1}' : p.join(' • ');
  }

  Future<void> _switch(Movie m) async {
    final pos = player.state.position;
    Navigator.pop(context);
    await player.open(Media(m.url));
    await Future.delayed(const Duration(seconds: 1));
    player.seek(pos);
  }

  void _settings() {
    final versions = widget.movie.key.isEmpty
        ? <Movie>[]
        : widget.all.where((m) => m.key == widget.movie.key && m.url != widget.movie.url).toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StatefulBuilder(builder: (ctx, set) {
        final tr = player.state.tracks;
        final audio = tr.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
        final subs = tr.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
        Widget head(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold)));
        Widget slider(IconData ic, double v, double min, double max, void Function(double) f) => Row(children: [
              Padding(padding: const EdgeInsets.only(left: 16), child: Icon(ic)),
              Expanded(child: Slider(value: v.clamp(min, max), min: min, max: max, onChanged: (x) => set(() => f(x)))),
            ]);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              head('Brightness'),
              slider(Icons.brightness_6, bright, 0.02, 1, (v) {
                bright = v;
                ScreenBrightness().setScreenBrightness(v);
              }),
              head('Sound'),
              slider(Icons.volume_up, volume, 0, 100, (v) {
                volume = v;
                player.setVolume(v);
              }),
              if (audio.length > 1) ...[
                head('Language / Audio'),
                for (var i = 0; i < audio.length; i++)
                  ListTile(
                    dense: true,
                    title: Text(_lbl(audio[i], i)),
                    trailing: player.state.track.audio.id == audio[i].id ? const Icon(Icons.check) : null,
                    onTap: () {
                      player.setAudioTrack(audio[i]);
                      set(() {});
                    },
                  ),
              ],
              head('Subtitle'),
              ListTile(
                dense: true,
                title: const Text('Off'),
                trailing: player.state.track.subtitle.id == 'no' ? const Icon(Icons.check) : null,
                onTap: () {
                  player.setSubtitleTrack(SubtitleTrack.no());
                  set(() {});
                },
              ),
              for (var i = 0; i < subs.length; i++)
                ListTile(
                  dense: true,
                  title: Text(_lbl(subs[i], i)),
                  trailing: player.state.track.subtitle.id == subs[i].id ? const Icon(Icons.check) : null,
                  onTap: () {
                    player.setSubtitleTrack(subs[i]);
                    set(() {});
                  },
                ),
              head('Speed'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(spacing: 8, children: [
                  for (final s in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                    ChoiceChip(
                        label: Text('${s}x'),
                        selected: player.state.rate == s,
                        onSelected: (_) {
                          player.setRate(s);
                          set(() {});
                        }),
                ]),
              ),
              if (versions.isNotEmpty) ...[
                head('Quality / Resolution'),
                for (final m in versions)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.high_quality),
                    title: Text(m.res.isEmpty ? m.name : '${m.res}  •  ${m.server}'),
                    subtitle: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => _switch(m),
                  ),
              ],
              const SizedBox(height: 24),
            ]),
          ),
        );
      }),
    );
  }

  // Double-tap left/right side = -5s / +5s (top & bottom bars stay untouched).
  Widget _zones() => Positioned.fill(
        child: Padding(
          padding: const EdgeInsets.only(top: 90, bottom: 130),
          child: Row(children: [
            Expanded(
                flex: 3,
                child: GestureDetector(behavior: HitTestBehavior.translucent, onDoubleTap: () => _skip(-5))),
            const Spacer(flex: 4),
            Expanded(
                flex: 3,
                child: GestureDetector(behavior: HitTestBehavior.translucent, onDoubleTap: () => _skip(5))),
          ]),
        ),
      );

  Widget _hintView() => Positioned.fill(
        child: IgnorePointer(
          child: ValueListenableBuilder<String?>(
            valueListenable: hint,
            builder: (_, v, __) => v == null
                ? const SizedBox()
                : Align(
                    alignment: Alignment(v.startsWith('-') ? -0.6 : 0.6, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(30)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(v.startsWith('-') ? Icons.fast_rewind : Icons.fast_forward, color: Colors.white),
                        const SizedBox(width: 6),
                        const Text('5 sec', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final title = Expanded(
        child: Text(widget.movie.clean,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)));
    final tune = MaterialCustomButton(icon: const Icon(Icons.tune), onPressed: _settings);
    final back = MaterialCustomButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context));
    final rew = MaterialCustomButton(icon: const Icon(Icons.replay_5), iconSize: 40, onPressed: () => _skip(-5));
    final fwd = MaterialCustomButton(icon: const Icon(Icons.forward_5), iconSize: 40, onPressed: () => _skip(5));
    MaterialVideoControlsThemeData theme(List<Widget> topBar) => MaterialVideoControlsThemeData(
          topButtonBar: topBar,
          topButtonBarMargin: EdgeInsets.fromLTRB(12, top + 12, 12, 0),
          primaryButtonBar: [
            const Spacer(flex: 2),
            rew,
            const Spacer(),
            MaterialPlayOrPauseButton(iconSize: 56),
            const Spacer(),
            fwd,
            const Spacer(flex: 2),
          ],
          bottomButtonBar: [MaterialPositionIndicator(), const Spacer(), MaterialFullscreenButton()],
          bottomButtonBarMargin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          seekBarMargin: const EdgeInsets.fromLTRB(20, 0, 20, 34),
          seekBarContainerHeight: 48,
          seekBarThumbSize: 18,
          brightnessGesture: true,
          volumeGesture: true,
          seekGesture: true,
        );
    // Swipe up/down: left side = brightness, right side = volume. Swipe sideways = seek.
    return Scaffold(
      backgroundColor: Colors.black,
      body: MaterialVideoControlsTheme(
        normal: theme([back, title, tune]),
        fullscreen: theme([title, tune]),
        child: Video(
          controller: controller,
          controls: (s) => Stack(children: [MaterialVideoControls(s), _zones(), _hintView()]),
        ),
      ),
    );
  }
}

