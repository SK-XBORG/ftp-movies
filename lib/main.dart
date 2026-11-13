import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

const videoExt = ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'ts', 'm4v'];

class Server {
  String name, host, user, pass, path;
  int port;
  Server(this.name, this.host, this.port, this.user, this.pass, this.path);
  Map<String, dynamic> toJson() =>
      {'n': name, 'h': host, 'p': port, 'u': user, 'w': pass, 'd': path};
  factory Server.fromJson(Map<String, dynamic> j) =>
      Server(j['n'], j['h'], j['p'], j['u'], j['w'], j['d']);
}

class Movie {
  final String title, url, server;
  final int size;
  Movie(this.title, this.url, this.server, this.size);
  Map<String, dynamic> toJson() => {'t': title, 'u': url, 's': server, 'z': size};
  factory Movie.fromJson(Map<String, dynamic> j) =>
      Movie(j['t'], j['u'], j['s'], j['z']);
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
      servers = (jsonDecode(prefs.getString('servers') ?? '[]') as List)
          .map((e) => Server.fromJson(e))
          .toList();
      movies = (jsonDecode(prefs.getString('movies') ?? '[]') as List)
          .map((e) => Movie.fromJson(e))
          .toList();
    });
  }

  Future<void> _saveServers() =>
      prefs.setString('servers', jsonEncode(servers.map((e) => e.toJson()).toList()));

  Future<void> _scan() async {
    setState(() {
      scanning = true;
      movies = [];
    });
    for (final s in servers) {
      setState(() => status = '${s.name} scan hocche...');
      final ftp = FTPConnect(s.host, port: s.port, user: s.user, pass: s.pass, timeout: 15);
      try {
        await ftp.connect();
        await _crawl(ftp, s, s.path.isEmpty ? '/' : s.path, 0);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('${s.name}: connect hoy nai')));
        }
      } finally {
        try {
          await ftp.disconnect();
        } catch (_) {}
      }
    }
    await prefs.setString('movies', jsonEncode(movies.map((e) => e.toJson()).toList()));
    setState(() => scanning = false);
  }

  Future<void> _crawl(FTPConnect ftp, Server s, String dir, int depth) async {
    if (depth > 3) return;
    if (!await ftp.changeDirectory(dir)) return;
    final items = await ftp.listDirectoryContent();
    for (final e in items) {
      final name = e.name ?? '';
      if (name.isEmpty || name == '.' || name == '..') continue;
      final full = dir.endsWith('/') ? '$dir$name' : '$dir/$name';
      if (e.type == FTPEntryType.DIR) {
        await _crawl(ftp, s, full, depth + 1);
      } else if (videoExt.contains(name.split('.').last.toLowerCase())) {
        final url = Uri(
                scheme: 'ftp',
                userInfo: s.user.isEmpty ? null : '${s.user}:${s.pass}',
                host: s.host,
                port: s.port,
                path: full)
            .toString();
        movies.add(Movie(name.replaceAll(RegExp(r'\.[^.]+$'), ''), url, s.name, e.size ?? 0));
        if (mounted) setState(() => status = '${movies.length} ta movie pawa gese');
      }
    }
    if (depth > 0) await ftp.changeDirectory('/');
  }

  Future<void> _editServer([Server? old]) async {
    final c = [
      old?.name ?? '',
      old?.host ?? '',
      '${old?.port ?? 21}',
      old?.user ?? 'anonymous',
      old?.pass ?? '',
      old?.path ?? '/'
    ].map((e) => TextEditingController(text: e)).toList();
    const labels = ['Name', 'Host / IP', 'Port', 'Username', 'Password', 'Movie folder'];
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(old == null ? 'Server add' : 'Server edit'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 6; i++)
              TextField(
                controller: c[i],
                obscureText: i == 4,
                keyboardType: i == 2 ? TextInputType.number : TextInputType.text,
                decoration: InputDecoration(labelText: labels[i]),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || c[1].text.trim().isEmpty) return;
    final s = Server(c[0].text.trim().isEmpty ? c[1].text.trim() : c[0].text.trim(),
        c[1].text.trim(), int.tryParse(c[2].text) ?? 21, c[3].text.trim(), c[4].text, c[5].text.trim());
    setState(() {
      if (old != null) servers[servers.indexOf(old)] = s;
      else servers.add(s);
    });
    await _saveServers();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;
    final body = tab == 0 ? _library() : _serverList();
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
        Expanded(child: body),
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
                    ? 'Age Servers tab e FTP server add koro'
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
                          Text(m.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text('${m.server} • ${(m.size / 1073741824).toStringAsFixed(1)} GB',
                              style: Theme.of(context).textTheme.bodySmall),
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
      : ListView(
          children: [
            for (final s in servers)
              ListTile(
                leading: const Icon(Icons.dns),
                title: Text(s.name),
                subtitle: Text('${s.host}:${s.port}  ${s.path}'),
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
          ],
        );
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
