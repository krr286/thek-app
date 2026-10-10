import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_singbox_client/flutter_singbox_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const String API_BASE = 'http://77.239.101.146:8080';

void main() {
  runApp(const ThekApp());
}

class ThekApp extends StatelessWidget {
  const ThekApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'THEK',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F1115),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF8B5CF6),
          surface: Color(0xFF1A1D24),
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class ServerInfo {
  final String name;
  final String type; // 'socks5' | 'mtproto'
  final String host;
  final int port;
  final String user;
  final String pass;
  final String? mtprotoLink;
  final String? expiresAt;
  int loadCur;
  int loadMax;
  int? pingMs;

  ServerInfo({
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    this.user = '',
    this.pass = '',
    this.mtprotoLink,
    this.expiresAt,
    this.loadCur = 0,
    this.loadMax = 10,
    this.pingMs,
  });

  bool get isMtproto => type == 'mtproto';
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SingboxClient _client = SingboxClient();

  bool _connected = false;
  bool _connecting = false;
  bool _initDone = false;
  String _subToken = '';
  List<ServerInfo> _servers = [];
  int _selectedIdx = 0;
  String _error = '';
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _initEngine();
    _loadSubToken();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _initEngine() async {
    try {
      await _client.initialize();
      setState(() => _initDone = true);
    } catch (e) {
      setState(() => _error = 'Ошибка инициализации: $e');
    }
  }

  Future<void> _loadSubToken() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString('sub_token') ?? '';
    if (t.isNotEmpty) {
      setState(() => _subToken = t);
      await _loadServers();
      _refreshTimer?.cancel();
      _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) => _loadServers());
    }
  }

  Future<void> _loadServers() async {
    if (_subToken.isEmpty) return;
    try {
      final url = '$API_BASE/check/$_subToken';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      final list = <ServerInfo>[];

      // MTProto — сверху
      for (final m in (data['mtproto'] as List? ?? [])) {
        list.add(ServerInfo(
          name: '✈️ Telegram',
          type: 'mtproto',
          host: (m['server'] ?? '').toString(),
          port: (m['port'] as num?)?.toInt() ?? 8443,
          mtprotoLink: (m['link'] ?? '').toString(),
          expiresAt: (m['expires_at'] ?? '').toString(),
          loadCur: (m['load_cur'] as num?)?.toInt() ?? 0,
          loadMax: (m['load_max'] as num?)?.toInt() ?? 10,
        ));
      }

      // SOCKS5 — ниже
      for (final s in (data['servers'] as List? ?? [])) {
        if (s is Map) {
          list.add(ServerInfo(
            name: (s['name'] ?? 'Server').toString(),
            type: 'socks5',
            host: (s['host'] ?? '').toString(),
            port: (s['port'] as num?)?.toInt() ?? 1080,
            user: (s['user'] ?? '').toString(),
            pass: (s['pass'] ?? '').toString(),
            loadCur: (s['load_cur'] as num?)?.toInt() ?? 0,
            loadMax: (s['load_max'] as num?)?.toInt() ?? 10,
          ));
        }
      }

      setState(() {
        _servers = list;
        _error = list.isEmpty ? 'Серверы не найдены' : '';
        if (_selectedIdx >= _servers.length) _selectedIdx = 0;
      });

      _pingAll();
    } catch (e) {
      setState(() => _error = 'Ошибка загрузки: $e');
    }
  }

  Future<void> _pingAll() async {
    for (var i = 0; i < _servers.length; i++) {
      final s = _servers[i];
      final sw = Stopwatch()..start();
      try {
        final sock = await Socket.connect(s.host, s.port, timeout: const Duration(seconds: 3));
        sock.destroy();
        sw.stop();
        if (mounted) setState(() => s.pingMs = sw.elapsedMilliseconds);
      } catch (_) {
        if (mounted) setState(() => s.pingMs = -1);
      }
    }
  }

  Future<void> _openMtproto(String link) async {
    final uri = Uri.parse(link);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(Uri.parse(link.replaceFirst('tg://', 'https://t.me/')),
            mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      setState(() => _error = 'Не открыть ссылку: $e');
    }
  }

  Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sub_token', token);
    setState(() => _subToken = token);
    await _loadServers();
  }

  Future<void> _toggleConnect() async {
    if (_connecting) return;
    if (!_initDone) {
      setState(() => _error = 'Движок ещё не готов');
      return;
    }
    final socks = _servers.where((s) => s.type == 'socks5').toList();
    if (socks.isEmpty) {
      setState(() => _error = 'Нет SOCKS5 серверов');
      return;
    }
    if (_selectedIdx >= _servers.length || _servers[_selectedIdx].type != 'socks5') {
      setState(() => _error = 'Выбери SOCKS5 сервер');
      return;
    }

    setState(() {
      _connecting = true;
      _error = '';
    });

    try {
      if (_connected) {
        await _client.disconnect();
        setState(() {
          _connected = false;
          _connecting = false;
        });
        return;
      }

      final p = _servers[_selectedIdx];
      final config = _buildConfig(p);

      try {
        await _client.checkConfig(config);
      } catch (e) {
        setState(() {
          _error = 'Ошибка конфига: $e';
          _connecting = false;
        });
        return;
      }

      final granted = await _client.requestVPNPermission();
      if (!granted) {
        setState(() {
          _error = 'Нет разрешения VPN';
          _connecting = false;
        });
        return;
      }

      await _client.connect(SessionOptions(
        config: config,
        networkMode: NetworkMode.vpn,
        killSwitch: false,
        notification: const NotificationConfig(
          title: 'THEK VPN',
          showTrafficStats: true,
        ),
      ));

      setState(() {
        _connected = true;
        _connecting = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Ошибка: $e';
        _connecting = false;
      });
    }
  }

  String _buildConfig(ServerInfo p) {
    final outbound = <String, dynamic>{
      'type': 'socks',
      'tag': 'proxy',
      'server': p.host,
      'server_port': p.port,
      'version': '5',
      'network': 'udp',
      'udp_over_tcp': {'enabled': true, 'version': 2},
    };
    if (p.user.isNotEmpty) {
      outbound['username'] = p.user;
      outbound['password'] = p.pass;
    }
    final config = <String, dynamic>{
      'log': {'level': 'warn'},
      'dns': {
        'servers': [
          {'type': 'tcp', 'tag': 'dns-remote', 'server': '8.8.8.8', 'detour': 'proxy'}
        ],
        'final': 'dns-remote',
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': ['172.19.0.1/30'],
          'mtu': 1500,
          'auto_route': true,
          'strict_route': true,
          'stack': 'system',
        }
      ],
      'outbounds': [outbound, {'type': 'direct', 'tag': 'direct'}],
      'route': {
        'auto_detect_interface': true,
        'rules': [
          {'action': 'sniff'},
          {'protocol': 'dns', 'action': 'hijack-dns'},
          {'ip_is_private': true, 'outbound': 'direct'},
        ],
        'final': 'proxy',
      },
    };
    return jsonEncode(config);
  }

  void _showTokenDialog() {
    final ctrl = TextEditingController(text: _subToken);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D24),
        title: const Text('Код подписки', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'FUJ4NW',
            hintStyle: const TextStyle(color: Color(0xFF8B95A5)),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: const BorderSide(color: Color(0xFF3B82F6)),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена', style: TextStyle(color: Color(0xFF8B95A5))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3B82F6)),
            onPressed: () {
              final t = ctrl.text.trim();
              Navigator.pop(context);
              if (t.isNotEmpty) _saveToken(t);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  Widget _pingBadge(ServerInfo s) {
    if (s.pingMs == null) {
      return const Text('···', style: TextStyle(color: Color(0xFF8B95A5), fontSize: 12));
    }
    if (s.pingMs! < 0) {
      return const Text('✕', style: TextStyle(color: Color(0xFFEF4444), fontSize: 12));
    }
    final c = s.pingMs! < 100
        ? const Color(0xFF22C55E)
        : s.pingMs! < 250
            ? const Color(0xFFF59E0B)
            : const Color(0xFFEF4444);
    return Text('${s.pingMs} ms', style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600));
  }

  Widget _loadBadge(ServerInfo s) {
    final pct = s.loadMax > 0 ? s.loadCur / s.loadMax : 0.0;
    final c = pct < 0.5
        ? const Color(0xFF22C55E)
        : pct < 0.85
            ? const Color(0xFFF59E0B)
            : const Color(0xFFEF4444);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.people_alt_outlined, size: 14, color: c),
        const SizedBox(width: 4),
        Text('${s.loadCur}/${s.loadMax}', style: TextStyle(color: c, fontSize: 12)),
      ],
    );
  }

  Widget _serverCard(ServerInfo s, int idx) {
    final isSel = idx == _selectedIdx && s.type == 'socks5';
    final isMt = s.isMtproto;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1D24),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSel ? const Color(0xFF3B82F6) : Colors.white.withOpacity(0.05),
          width: isSel ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: isMt ? null : () => setState(() => _selectedIdx = idx),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: (isMt ? const Color(0xFF29B6F6) : const Color(0xFF8B5CF6)).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(isMt ? '✈️' : '🌐', style: const TextStyle(fontSize: 20)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _pingBadge(s),
                        const SizedBox(width: 10),
                        _loadBadge(s),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isMt)
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF29B6F6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => _openMtproto(s.mtprotoLink ?? ''),
                  child: const Text('Открыть', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                )
              else
                Icon(
                  isSel ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: isSel ? const Color(0xFF3B82F6) : const Color(0xFF8B95A5),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final socks = _servers.where((s) => s.type == 'socks5').toList();
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadServers,
          color: const Color(0xFF3B82F6),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Row(
                children: [
                  const Text('THEK',
                      style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Color(0xFF8B95A5)),
                    onPressed: _loadServers,
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings, color: Color(0xFF8B95A5)),
                    onPressed: _showTokenDialog,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Center(
                child: GestureDetector(
                  onTap: socks.isEmpty ? null : _toggleConnect,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: _connecting
                            ? [Colors.orange, Colors.deepOrange]
                            : _connected
                                ? [const Color(0xFF22C55E), const Color(0xFF16A34A)]
                                : [const Color(0xFF3B82F6), const Color(0xFF8B5CF6)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (_connecting
                                  ? Colors.orange
                                  : _connected
                                      ? const Color(0xFF22C55E)
                                      : const Color(0xFF3B82F6))
                              .withOpacity(0.4),
                          blurRadius: 40,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _connecting
                            ? const CircularProgressIndicator(color: Colors.white)
                            : const Icon(Icons.power_settings_new, color: Colors.white, size: 64),
                        const SizedBox(height: 8),
                        Text(
                          _connecting
                              ? 'ПОДКЛЮЧЕНИЕ...'
                              : _connected
                                  ? 'ОТКЛЮЧИТЬ'
                                  : 'ПОДКЛЮЧИТЬ',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  _connected ? '✅ Защищено' : '❌ Не защищено',
                  style: TextStyle(
                    color: _connected ? const Color(0xFF22C55E) : const Color(0xFF8B95A5),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (_error.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_error, style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12)),
                ),
              if (_servers.isEmpty && _subToken.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1D24),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text('Серверы загружаются...',
                      style: TextStyle(color: Color(0xFF8B95A5))),
                ),
              if (_subToken.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1D24),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    children: [
                      Text('📡', style: TextStyle(fontSize: 24)),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text('Нажми ⚙️ чтобы ввести код подписки',
                            style: TextStyle(color: Color(0xFF8B95A5))),
                      ),
                    ],
                  ),
                ),
              if (_servers.isNotEmpty) ...[
                const Text('📡 Серверы',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                for (int i = 0; i < _servers.length; i++) _serverCard(_servers[i], i),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
