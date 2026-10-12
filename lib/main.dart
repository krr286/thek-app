import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:outline_mobileproxy/outline_mobileproxy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const String API_BASE = 'http://77.239.101.146:8080';

void main() {
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const ThekApp());
}

class ThekApp extends StatelessWidget {
  const ThekApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TheK — Client',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF7C5CFF),
          secondary: Color(0xFF3B82F6),
          surface: Color(0xFF161B2E),
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
  bool _connected = false;
  bool _connecting = false;
  String _subToken = '';
  List<ServerInfo> _servers = [];
  int _selectedIdx = 0;
  String _error = '';
  Timer? _refreshTimer;
  MobileProxy? _mobileProxy;
  int _localPort = 0;

  @override
  void initState() {
    super.initState();
    _loadSubToken();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _mobileProxy?.stop();
    super.dispose();
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
      final res = await http.get(Uri.parse('$API_BASE/check/$_subToken'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = <ServerInfo>[];

      for (final m in (data['mtproto'] as List? ?? [])) {
        list.add(ServerInfo(
          name: 'Telegram',
          type: 'mtproto',
          host: (m['server'] ?? '').toString(),
          port: (m['port'] as num?)?.toInt() ?? 8443,
          mtprotoLink: (m['link'] ?? '').toString(),
          expiresAt: (m['expires_at'] ?? '').toString(),
          loadCur: (m['load_cur'] as num?)?.toInt() ?? 0,
          loadMax: (m['load_max'] as num?)?.toInt() ?? 500,
        ));
      }
      for (final s in (data['servers'] as List? ?? [])) {
        if (s is Map) {
          list.add(ServerInfo(
            name: (s['display_name'] ?? s['name'] ?? 'Server').toString(),
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
      if (mounted) {
        setState(() {
          _servers = list;
          _error = list.isEmpty ? 'Серверы не найдены' : '';
          if (_selectedIdx >= _servers.length) _selectedIdx = 0;
        });
      }
      _pingAll();
    } catch (e) {
      if (mounted) setState(() => _error = 'Ошибка загрузки: $e');
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
    if (link.isEmpty) return;
    final uri = Uri.parse(link);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(Uri.parse(link.replaceFirst('tg://', 'https://t.me/')),
            mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Не открыть Telegram: $e');
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
    final socks = _servers.where((s) => s.type == 'socks5').toList();
    if (socks.isEmpty) {
      setState(() => _error = 'Нет SOCKS5 серверов');
      return;
    }
    if (_selectedIdx >= _servers.length || _servers[_selectedIdx].type != 'socks5') {
      setState(() => _error = 'Выбери SOCKS5 сервер');
      return;
    }

    setState(() { _connecting = true; _error = ''; });
    try {
      if (_connected) {
        await _mobileProxy?.stop();
        _mobileProxy = null;
        _localPort = 0;
        setState(() { _connected = false; _connecting = false; });
        return;
      }

      final p = _servers[_selectedIdx];
      // Запускаем локальный прокси
      final proxy = MobileProxy(
        upstream: 'socks5://${p.user}:${p.pass}@${p.host}:${p.port}',
      );
      final port = await proxy.start();
      _mobileProxy = proxy;
      _localPort = port;

      setState(() { _connected = true; _connecting = false; });
    } catch (e) {
      setState(() { _error = 'Ошибка: $e'; _connecting = false; });
    }
  }

  void _showLocalPortDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Подключение приложений', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Локальный прокси запущен на порту:', style: TextStyle(color: Color(0xFFA0A8BF))),
            const SizedBox(height: 8),
            Text('127.0.0.1:$_localPort', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            const Text('В настройках Wi-Fi на телефоне укажи ручной HTTP-прокси:', style: TextStyle(color: Color(0xFFA0A8BF))),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F1422),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('Сервер: 127.0.0.1\nПорт: см. выше', style: TextStyle(color: Colors.white, fontFamily: 'monospace')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: '127.0.0.1:$_localPort'));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
            },
            child: const Text('Копировать', style: TextStyle(color: Color(0xFF7C5CFF))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: Color(0xFFA0A8BF))),
          ),
        ],
      ),
    );
  }

  void _showTokenDialog() {
    final ctrl = TextEditingController(text: _subToken);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Код подписки', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white, letterSpacing: 2),
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            hintText: 'FUJ4NW',
            hintStyle: const TextStyle(color: Color(0xFF6B7290)),
            filled: true,
            fillColor: const Color(0xFF0F1422),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена', style: TextStyle(color: Color(0xFFA0A8BF))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C5CFF),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              final t = ctrl.text.trim().toUpperCase();
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
    if (s.pingMs == null) return const Text('···', style: TextStyle(color: Color(0xFF6B7290), fontSize: 12));
    if (s.pingMs! < 0) return const Text('нет связи', style: TextStyle(color: Color(0xFFEF4444), fontSize: 12));
    final c = s.pingMs! < 150 ? const Color(0xFF22C55E)
        : s.pingMs! < 400 ? const Color(0xFFF59E0B)
        : const Color(0xFFEF4444);
    return Text('${s.pingMs} мс', style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600));
  }

  Widget _loadBadge(ServerInfo s) {
    final pct = s.loadMax > 0 ? s.loadCur / s.loadMax : 0.0;
    final c = pct < 0.5 ? const Color(0xFF22C55E)
        : pct < 0.85 ? const Color(0xFFF59E0B)
        : const Color(0xFFEF4444);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 8, color: c),
      const SizedBox(width: 5),
      Text('${s.loadCur}/${s.loadMax}', style: TextStyle(color: c, fontSize: 12)),
    ]);
  }

  Widget _serverCard(ServerInfo s, int idx) {
    final isMt = s.isMtproto;
    final isSel = idx == _selectedIdx && !isMt;
    return GestureDetector(
      onTap: isMt ? () => _openMtproto(s.mtprotoLink ?? '') : () => setState(() => _selectedIdx = idx),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: isSel
              ? const LinearGradient(
                  colors: [Color(0x307C5CFF), Color(0x203B82F6)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight)
              : null,
          color: isSel ? null : const Color(0xFF161B2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSel ? const Color(0xFF7C5CFF) : Colors.white.withOpacity(0.06),
            width: isSel ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: (isMt ? const Color(0xFF22D3EE) : const Color(0xFF7C5CFF)).withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(child: Text(isMt ? '✈️' : '🌐', style: const TextStyle(fontSize: 20))),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 5),
              Row(children: [
                _pingBadge(s),
                const SizedBox(width: 12),
                _loadBadge(s),
              ]),
            ],
          )),
          if (isMt)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF22D3EE), Color(0xFF3B82F6)]),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text('Открыть', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            )
          else
            Icon(isSel ? Icons.check_circle : Icons.radio_button_unchecked,
                color: isSel ? const Color(0xFF7C5CFF) : const Color(0xFF6B7290), size: 24),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0A0E1A), Color(0xFF0E1424), Color(0xFF1A2244)],
          ),
        ),
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: _loadServers,
            color: const Color(0xFF7C5CFF),
            backgroundColor: const Color(0xFF161B2E),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Row(children: [
                  const Text('THEK',
                      style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900,
                          fontStyle: FontStyle.italic, letterSpacing: 1)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Color(0xFFA0A8BF)),
                    onPressed: _loadServers,
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings, color: Color(0xFFA0A8BF)),
                    onPressed: _showTokenDialog,
                  ),
                ]),
                const SizedBox(height: 30),
                Center(
                  child: GestureDetector(
                    onTap: _toggleConnect,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 200, height: 200,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: _connecting
                            ? [Colors.orange.shade400, Colors.deepOrange]
                            : _connected
                                ? [const Color(0xFF22C55E), const Color(0xFF16A34A)]
                                : [const Color(0xFF1A1F33), const Color(0xFF0F1422)]),
                        border: Border.all(
                          color: _connected ? const Color(0xFF22C55E) : const Color(0xFF7C5CFF),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: (_connected ? const Color(0xFF22C55E) : const Color(0xFF7C5CFF)).withOpacity(0.4),
                            blurRadius: 40, spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        _connecting
                            ? const CircularProgressIndicator(color: Colors.white)
                            : const Icon(Icons.power_settings_new, color: Colors.white, size: 68),
                        const SizedBox(height: 8),
                        Text(
                          _connecting ? 'ПОДКЛЮЧЕНИЕ...' : _connected ? 'ОТКЛЮЧИТЬ' : 'ПОДКЛЮЧИТЬ',
                          style: const TextStyle(color: Colors.white, fontSize: 12,
                              fontWeight: FontWeight.bold, letterSpacing: 1),
                        ),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Center(
                  child: Text(
                    _connected ? '✅ Защищено' : '❌ Не защищено',
                    style: TextStyle(
                      color: _connected ? const Color(0xFF22C55E) : const Color(0xFFA0A8BF),
                      fontSize: 15, fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_connected && _localPort > 0)
                  Center(
                    child: TextButton(
                      onPressed: _showLocalPortDialog,
                      child: Text('Порт: $_localPort', style: const TextStyle(color: Color(0xFF7C5CFF), fontSize: 12)),
                    ),
                  ),
                const SizedBox(height: 30),
                if (_error.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_error, style: const TextStyle(color: Color(0xFFEF4444), fontSize: 13)),
                  ),
                Row(children: [
                  Container(width: 20, height: 2, color: const Color(0xFF7C5CFF)),
                  const SizedBox(width: 10),
                  const Text('СЕРВЕРА', style: TextStyle(color: Color(0xFFA0A8BF), fontSize: 11,
                      letterSpacing: 2, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 12),
                if (_servers.isEmpty && _subToken.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161B2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.06)),
                    ),
                    child: const Column(children: [
                      Icon(Icons.download, color: Color(0xFF7C5CFF), size: 36),
                      SizedBox(height: 12),
                      Text('Введи код подписки', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                      SizedBox(height: 6),
                      Text('Нажми ⚙️ сверху и вставь код из бота', style: TextStyle(color: Color(0xFFA0A8BF), fontSize: 13), textAlign: TextAlign.center),
                    ]),
                  ),
                for (int i = 0; i < _servers.length; i++) _serverCard(_servers[i], i),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
