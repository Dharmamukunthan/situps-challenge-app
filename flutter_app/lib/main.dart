import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SitupChallengeApp());
}

class SitupChallengeApp extends StatefulWidget {
  const SitupChallengeApp({super.key});

  @override
  State<SitupChallengeApp> createState() => _SitupChallengeAppState();
}

class _SitupChallengeAppState extends State<SitupChallengeApp> {
  bool _isDark = false;

  // Light theme colors
  static const Color _lightBg = Color(0xFFFDF5F0);
  static const Color _lightCard = Color(0xFFFFF0E8);
  static const Color _lightText = Color(0xFF3D2C2C);
  static const Color _lightSubtext = Color(0xFF9C8A8A);

  // Dark theme colors
  static const Color _darkBg = Color(0xFF1A1A2E);
  static const Color _darkCard = Color(0xFF252540);
  static const Color _darkText = Color(0xFFF5F5F5);
  static const Color _darkSubtext = Color(0xFF9CA3AF);

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  void _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _isDark = prefs.getBool('situp-dark-theme') ?? false);
  }

  void toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _isDark = !_isDark);
    await prefs.setBool('situp-dark-theme', _isDark);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Situp Challenge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE8734A),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: _lightBg,
        cardColor: _lightCard,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: _lightText),
          bodyMedium: TextStyle(color: _lightText),
          bodySmall: TextStyle(color: _lightSubtext),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE8734A),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: _darkBg,
        cardColor: _darkCard,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: _darkText),
          bodyMedium: TextStyle(color: _darkText),
          bodySmall: TextStyle(color: _darkSubtext),
        ),
      ),
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      home: AuthWrapper(
        isDark: _isDark,
        onToggleTheme: toggleTheme,
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;

  const AuthWrapper({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _checking = true;
  bool _isLoggedIn = false;
  String _username = '';
  String _userId = '';
  bool _isSignedIn = false;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  void _checkAuth() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('situp-username');
    final userId = prefs.getString('situp-user-id') ?? '';
    final signedIn = prefs.getBool('situp-signed-in') ?? false;
    setState(() {
      _isLoggedIn = username != null && username.isNotEmpty && userId.isNotEmpty;
      _username = username ?? '';
      _userId = userId;
      _isSignedIn = signedIn;
      _checking = false;
    });
  }

  void _handleAuth(AuthResult result) {
    setState(() {
      _isLoggedIn = true;
      _username = result.username;
      _userId = result.userId;
      _isSignedIn = result.isSignedIn;
    });
  }

  Future<void> _handleSignOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('situp-username');
    await prefs.remove('situp-user-id');
    await prefs.remove('situp-signed-in');
    await prefs.remove('situp-auth-token');
    if (!mounted) return;
    setState(() {
      _isLoggedIn = false;
      _username = '';
      _userId = '';
      _isSignedIn = false;
    });
  }

  Future<void> _handleRename(String newUsername) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('situp-username', newUsername);
    if (!mounted) return;
    setState(() => _username = newUsername);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return Scaffold(
        backgroundColor: widget.isDark ? const Color(0xFF1A1A2E) : const Color(0xFFFDF5F0),
        body: const Center(
          child: CircularProgressIndicator(color: Color(0xFFE8734A)),
        ),
      );
    }
    if (_isLoggedIn) {
      return DashboardScreen(
        username: _username,
        userId: _userId,
        isSignedIn: _isSignedIn,
        isDark: widget.isDark,
        onToggleTheme: widget.onToggleTheme,
        onSignOut: _handleSignOut,
        onRename: _handleRename,
      );
    }
    return AuthScreen(
      isDark: widget.isDark,
      onToggleTheme: widget.onToggleTheme,
      onAuth: _handleAuth,
    );
  }
}
