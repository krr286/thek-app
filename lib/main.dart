import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Инициализация плагина
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterSingBox().init();
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
  bool _connected = false;
  bool _connecting = false;
  String _subUrl = '';
  String _error = '';
  List<String> _servers = [];
  int _selectedIdx = 0;

  @override
  void initState() {
    super.initState();
    _loadSubUrl();
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
      final content = res.body;
      final lines = content.split('\n').where((l) => l.contains('server:')).toList();
      setState(() {
        _servers = lines.map((l) {
          final name = l.split('name:').last.trim().replaceAll('"', '');
          return name.isEmpty ? 'Сервер ${lines.indexOf(l) + 1}' : name;
        }).toList();
        _error = '';
      });
    } catch (e) {
      setState(() => _error = 'Ошибка загрузки: $e');
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
    setState(() {
      _connecting = true;
      _error = '';
    });

    try {
      if (_connected) {
        await FlutterSingBox().stopVpn();
        setState(() {
          _connected = false;
          _connecting = false;
        });
        return;
      }

      if (_servers.isEmpty) {
        setState(() {
          _error = 'Нет серверов. Введи ссылку подписки.';
          _connecting = false;
        });
        return;
      }

      final config = _buildSingBoxConfig(_servers[_selectedIdx]);
      
      // Правильный API: сохраняем конфиг, потом стартуем
      await FlutterSingBox().saveConfig(config);
      await FlutterSingBox().startVpn();

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

  String _buildSingBoxConfig(String serverName) {
    // В реальном приложении здесь будет парсинг Clash YAML.
    // Пока плагин делает это сам, мы просто передаём ему ссылку на подписку.
    // Но для примера соберём простой JSON.
    return '''
    {
      "log": {"level": "info"},
      "inbounds": [
        {
          "type": "tun",
          "interface_name": "tun0",
          "inet4_address": "172.19.0.1/30",
          "auto_route": true,
          "strict_route": true
        }
      ],
      "outbounds": [
        {
          "type": "selector",
          "tag": "proxy",
          "outbounds": ["$serverName"]
        },
        {
          "type": "socks",
          "tag": "$serverName",
          "server": "PLACEHOLDER",
          "server_port": 1080
        }
      ],
      "route": {
        "rules": [],
        "final": "proxy"
      }
    }
    ''';
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
            hintText: 'http://77.239.101.146:8080/clash/sub_xxx',
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

              if (_servers.isNotEmpty)
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
                              _servers[_selectedIdx],
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                          Text('${_servers.length} шт.', style: const TextStyle(color: Color(0xFF8B95A5), fontSize: 13)),
                        ],
                      ),
                      if (_servers.length > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: DropdownButton<int>(
                            value: _selectedIdx,
                            isExpanded: true,
                            dropdownColor: const Color(0xFF1A1D24),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(_servers.length, (i) => DropdownMenuItem(
                              value: i,
                              child: Text(_servers[i]),
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
