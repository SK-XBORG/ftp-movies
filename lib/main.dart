import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

const videoExt = ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'ts', 'm4v'];

class Server {
  String name, url;
  Server(this.name, this.url);
  Map<String, dynamic> toJson() => {'n': name, 'u': url};
  factory Server.fromJson(Map<String, dynamic> j) => Server(j['n'], j['u']);
}

class Movie {
  final String title, url, server;
  Movie(this.title, this.url, this.server);
  Map<String, dynamic> toJson() => {'t': title, 'u': url, 's': server};
  factory Movie.fromJson(Map<String, dynamic> j) => Movie(j['t'], j['u'], j['s']);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const MaterialApp(
    title: 'FTP Movies',
    debugShowCheckedModeBanner: false,
    home: HomePage(),
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
  String query = '';
  int tab = 0;
  bool scanning = false;
  String status = '';
  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    prefs = await SharedPreferences.getInstance();
    setState(() {
      servers = (jsonDecode(prefs.getString('srv2') ?? '[]') as List)
          .map((e) => Server.fromJson(e))
          .toList();
      movies = (jsonDecode(prefs.getString('mov2') ?? '[]') as List)
          .map((e) => Movie.fromJson(e))
          .toList();
    });
  }

  Future<void> _saveServers() =>
      prefs.setString('srv2', jsonEncode(servers.map((e) => e.toJson()).toList()));

  Future<void> _scan() async {
    setState(() {
      scanning = true;
      movies = [];
    });
    final client = http.Client();
    for (final s in servers) {
      setState(() => status = '${s.name} scan hocche...');
      var u = s.url.trim();
      if (!u.startsWith('http')) u = 'http://$u';
      if (!u.endsWith('/')) u = '$u/';
      await _crawl(client, s, Uri.parse(u), 0);
    }
    client.close();
    await prefs.setString('mov2', jsonEncode(movies.map((e) => e.toJson()).toList()));
    setState(() {
      scanning = false;
      status = '';
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${s.name}: connect hoy nai')));
      }
      return;
    }
    final links = RegExp('href="([^"]+)"', caseSensitive: false)
        .allMatches(body)
        .map((m) => m.group(1)!)
        .toSet();
    for (final raw in links) {
      if (raw.startsWith('?') || raw.startsWith('#') || raw.startsWith('..')) continue;
      Uri u;
      try {
        u = dir.resolve(raw);
      } catch (_) {
        continue;
      }
      if (u.host != dir.host || !u.path.startsWith(dir.path) || u.path == dir.path) continue;
      if (u.path.endsWith('/')) {
        await _crawl(c, s, u, depth + 1);
      } else {
        final name = u.pathSegments.isEmpty ? '' : u.pathSegments.last;
        if (videoExt.contains(name.split('.').last.toLowerCase())) {
          movies.add(Movie(name.replaceAll(RegExp(r'\.[^.]+$'), ''), u.toString(), s.name));
          if (mounted) setState(() => status = '${movies.length} ta movie pawa gese');
        }
      }
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
    setState(() {
      if (old != null) {
        servers[servers.indexOf(old)] = s;
      } else {
        servers.add(s);
      }
    });
    await _saveServers();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FTP Movies'),
        actions: [
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
      floatingActionButton: tab == 1
          ? FloatingActionButton.extended(
              onPressed: _editServer, icon: const Icon(Icons.add), label: const Text('Server'))
          : null,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.movie), label: 'Library'),
                NavigationDestination(icon: Icon(Icons.dns), label: 'Servers'),
              ]),
      body: Row(children: [
        if (wide)
          NavigationRail(
              selectedIndex: tab,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationRailDestination(icon: Icon(Icons.movie), label: Text('Library')),
                NavigationRailDestination(icon: Icon(Icons.dns), label: Text('Servers')),
              ]),
        Expanded(child: tab == 0 ? _library() : _serverList()),
      ]),
    );
  }

  Widget _library() {
    final list = movies
        .where((m) => m.title.toLowerCase().contains(query.toLowerCase()))
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SearchBar(
          hintText: 'Movie search (${movies.length})',
          leading: const Icon(Icons.search),
          onChanged: (v) => setState(() => query = v),
        ),
      ),
      if (scanning) Padding(padding: const EdgeInsets.all(4), child: Text(status)),
      Expanded(
        child: list.isEmpty
            ? Center(
                child: Text(servers.isEmpty
                    ? 'Age Servers tab e server add koro'
                    : 'Refresh (scan) button chap'))
            : GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.85),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final m = list[i];
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => PlayerPage(movie: m))),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Expanded(child: Center(child: Icon(Icons.play_circle_fill, size: 56))),
                          Text(m.title, maxLines: 3, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(m.server, style: Theme.of(context).textTheme.bodySmall),
                        ]),
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

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
                    });
                    await _saveServers();
                  }),
            ),
        ]);
}

class PlayerPage extends StatefulWidget {
  final Movie movie;
  const PlayerPage({super.key, required this.movie});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player player = Player();
  late final VideoController controller = VideoController(player);

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    player.open(Media(widget.movie.url));
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(widget.movie.title, overflow: TextOverflow.ellipsis)),
        body: SafeArea(child: Center(child: Video(controller: controller))),
      );
}
