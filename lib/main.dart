import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';

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
        primaryColor: const Color(0xFF3B82F6),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF8B5CF6),
          surface: Color(0xFF1A1D24),
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
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
  bool _loading = true;
  String _userName = 'Гость';
  int _daysLeft = 0;
  String _tariff = 'Нет подписки';
  double _balance = 0;
  List<Map<String, dynamic>> _servers = [];
  String _subUrl = '';
  int _selectedServer = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token') ?? '';
    final name = prefs.getString('name') ?? 'Гость';
    setState(() {
      _userName = name;
      _loading = false;
    });
    if (token.isNotEmpty) {
      await _fetchSubscription(token);
    }
  }

  Future<void> _fetchSubscription(String token) async {
    try {
      final res = await http.get(
        Uri.parse('http://77.239.101.146:8080/miniapp/api/me?user_id=0'),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _daysLeft = data['subscription']?['days_left'] ?? 0;
          _tariff = data['subscription']?['tariff_name'] ?? 'Нет подписки';
          _balance = (data['user']?['balance'] ?? 0).toDouble();
        });
      }
    } catch (_) {}
  }

  void _toggleConnect() {
    setState(() => _connected = !_connected);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_connected ? '✅ Подключено' : '❌ Отключено'),
        duration: const Duration(seconds: 2),
        backgroundColor: _connected ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF3B82F6)),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              // Header
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
                      ),
                    ),
                    child: Center(
                      child: Text(
                        _userName[0].toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _userName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Баланс: ${_balance.toStringAsFixed(0)} ₽',
                          style: const TextStyle(
                            color: Color(0xFF8B95A5),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),

              // Big Connect Button
              GestureDetector(
                onTap: _toggleConnect,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: _connected
                          ? [const Color(0xFF22C55E), const Color(0xFF16A34A)]
                          : [const Color(0xFF3B82F6), const Color(0xFF8B5CF6)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (_connected
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
                      Icon(
                        Icons.power_settings_new,
                        color: Colors.white,
                        size: 72,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _connected ? 'ОТКЛЮЧИТЬ' : 'ПОДКЛЮЧИТЬ',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),
              Text(
                _connected ? 'Защищено' : 'Не защищено',
                style: TextStyle(
                  color: _connected
                      ? const Color(0xFF22C55E)
                      : const Color(0xFF8B95A5),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),

              // Subscription card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1D24),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Row(
                  children: [
                    const Text('📦', style: TextStyle(fontSize: 28)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _tariff,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            'Осталось $_daysLeft дней',
                            style: const TextStyle(
                              color: Color(0xFF8B95A5),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Color(0xFF8B95A5)),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Servers button
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1D24),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Row(
                  children: [
                    const Text('🌍', style: TextStyle(fontSize: 28)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Серверы',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            '${_servers.length} доступно',
                            style: const TextStyle(
                              color: Color(0xFF8B95A5),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Color(0xFF8B95A5)),
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
