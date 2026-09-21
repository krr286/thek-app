import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_singbox_client/flutter_singbox_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
  String _subUrl = '';
  List<Map<String, String>> _proxies = [];
  int _selectedIdx = 0;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _initEngine();
    _loadSubUrl();
  }

  Future<void> _initEngine() async {
    try {
      await _client.initialize();
      setState(() => _initDone = true);
    } catch (e) {
      setState(() => _error = 'Ошибка инициализации: $e');
    }
  }

  Future<void> _loadSubUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('sub_url') ?? '';
    if (url.isNotEmpty) {
      setState(() => _subUrl = url);
      await _loadServers(url);
    }
  }

  Future<void> _loadServers(String url) async {
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

      String decoded;
      try {
        decoded = utf8.decode(base64.decode(res.body.trim()));
      } catch (_) {
        decoded = res.body;
      }

      final links = decoded.split('\n').where((l) => l.trim().isNotEmpty).toList();
      final proxies = <Map<String, String>>[];
      for (final link in links) {
        final parsed = _parseSocks5(link.trim());
        if (parsed != null) proxies.add(parsed);
      }

      setState(() {
        _proxies = proxies;
        _error = proxies.isEmpty ? 'Прокси не найдены' : '';
      });
    } catch (e) {
      setState(() => _error = 'Ошибка загрузки: $e');
    }
  }

  Map<String, String>? _parseSocks5(String url) {
    try {
      final uri = Uri.parse(url);
      if (!url.startsWith('socks5://') && !url.startsWith('socks://')) return null;
      final host = uri.host;
      final port = uri.port.toString();
      final parts = uri.userInfo.split(':');
      final user = parts.isNotEmpty ? parts[0] : '';
      final pass = parts.length > 1 ? parts[1] : '';
      final name = uri.fragment.isNotEmpty ? Uri.decodeComponent(uri.fragment) : '$host:$port';
      return {'host': host, 'port': port, 'user': user, 'pass': pass, 'name': name};
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveSubUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sub_url', url);
    setState(() => _subUrl = url);
    await _loadServers(url);
  }

  Future<void> _toggleConnect() async {
    if (_connecting) return;
    if (!_initDone) {
      setState(() => _error = 'Движок ещё не готов. Подожди пару секунд.');
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

      if (_proxies.isEmpty) {
        setState(() {
          _error = 'Нет прокси. Введи ссылку подписки.';
          _connecting = false;
        });
        return;
      }

      final p = _proxies[_selectedIdx];
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
          _error = 'Разрешение VPN не получено';
          _connecting = false;
        });
        return;
      }

      await _client.connect(
        SessionOptions(
          config: config,
          networkMode: NetworkMode.vpn,
          killSwitch: false,
          notification: const NotificationConfig(
            title: 'THEK VPN',
            showTrafficStats: true,
          ),
        ),
      );

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

  String _buildConfig(Map<String, String> p) {
    final outbound = <String, dynamic>{
      'type': 'socks',
      'tag': 'proxy',
      'server': p['host'],
      'server_port': int.parse(p['port']!),
      'version': '5',
    };
    if ((p['user'] ?? '').isNotEmpty) {
      outbound['username'] = p['user']!;
      outbound['password'] = p['pass']!;
    }

    final config = <String, dynamic>{
      'log': {'level': 'warn'},
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': ['172.19.0.1/30'],
          'mtu': 9000,
          'auto_route': true,
          'strict_route': true,
          'stack': 'system',
          'sniff': true,
        }
      ],
      'outbounds': [outbound],
      'route': {
        'rules': <Map<String, dynamic>>[],
        'final': 'proxy',
      },
    };

    return jsonEncode(config);
  }

  void _showSubUrlDialog() {
    final ctrl = TextEditingController(text: _subUrl);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D24),
        title: const Text('Ссылка подписки', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'http://77.239.101.146:8080/sub/sub_xxx',
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
              final url = ctrl.text.trim();
              Navigator.pop(context);
              if (url.isNotEmpty) _saveSubUrl(url);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  const Text('THEK',
                      style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.settings, color: Color(0xFF8B95A5)),
                    onPressed: _showSubUrlDialog,
                  ),
                ],
              ),
              const Spacer(),
              GestureDetector(
                onTap: _toggleConnect,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 200,
                  height: 200,
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
                          : const Icon(Icons.power_settings_new, color: Colors.white, size: 72),
                      const SizedBox(height: 8),
                      Text(
                        _connecting ? 'ПОДКЛЮЧЕНИЕ...' : _connected ? 'ОТКЛЮЧИТЬ' : 'ПОДКЛЮЧИТЬ',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _connected ? '✅ Защищено' : '❌ Не защищено',
                style: TextStyle(
                  color: _connected ? const Color(0xFF22C55E) : const Color(0xFF8B95A5),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
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
              if (_proxies.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1D24),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.05)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Text('🌍', style: TextStyle(fontSize: 24)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _proxies[_selectedIdx]['name'] ?? 'Прокси',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                          Text('${_proxies.length} шт.', style: const TextStyle(color: Color(0xFF8B95A5), fontSize: 13)),
                        ],
                      ),
                      if (_proxies.length > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: DropdownButton<int>(
                            value: _selectedIdx,
                            isExpanded: true,
                            dropdownColor: const Color(0xFF1A1D24),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(_proxies.length, (i) => DropdownMenuItem(
                              value: i,
                              child: Text(_proxies[i]['name'] ?? 'Прокси ${i + 1}'),
                            )),
                            onChanged: (i) => setState(() => _selectedIdx = i!),
                          ),
                        ),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1D24),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.05)),
                  ),
                  child: const Row(
                    children: [
                      Text('📡', style: TextStyle(fontSize: 24)),
                      SizedBox(width: 12),
                      Expanded(child: Text('Нажми ⚙️ чтобы ввести ссылку подписки', style: TextStyle(color: Color(0xFF8B95A5)))),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
