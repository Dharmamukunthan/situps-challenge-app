import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';

// ---------------------------------------------------------------------------
// Config — change these to match your deployed Convex backend.
// ---------------------------------------------------------------------------
const String _backendUrl = 'https://graceful-mink-900.convex.site';
const String _emailOtpProvider = 'email-otp';

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

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  void _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _isDark = prefs.getBool('situp-dark-theme') ?? false);
  }

  void toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _isDark = !_isDark);
    await prefs.setBool('situp-dark-theme', _isDark);
  }

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
      home: AuthGate(
        isDark: _isDark,
        onToggleTheme: toggleTheme,
      ),
    );
  }
}

/// Decides between the auth screen and the dashboard based on the saved session.
class AuthGate extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;

  const AuthGate({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _checking = true;
  AuthResult? _session;

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  /// Persisted session + optional battle code scanned by a friend.
  Future<void> _loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('situp-username');
    final userId = prefs.getString('situp-user-id');
    final pendingBattleCode = prefs.getString('situp-pending-battle-code');
    final signedIn = prefs.getBool('situp-signed-in') ?? false;

    if (!mounted) return;

    // If we still have a stale guest username but no userId, drop it.
    if (username == null || userId == null || userId.isEmpty) {
      await prefs.remove('situp-pending-battle-code');
      setState(() {
        _checking = false;
      });
      return;
    }

    // If we're signed in but no username has been claimed yet, claim one now.
    String resolvedUsername = username;
    if (signedIn && (username == null || username.isEmpty)) {
      resolvedUsername = await _claimUsernameForSignedIn(userId);
    }

    setState(() {
      _checking = false;
      _session = AuthResult(
        username: resolvedUsername,
        userId: userId,
        isSignedIn: signedIn,
      );
      // Carry the battle code through so the user lands in the right room.
      if (pendingBattleCode != null && pendingBattleCode.isNotEmpty) {
        _session = AuthResult(
          username: resolvedUsername,
          userId: userId,
          isSignedIn: signedIn,
        );
      }
    });
  }

  Future<String> _claimUsernameForSignedIn(String userId) async {
    final rnd = Random();
    for (int i = 0; i < 8; i++) {
      final candidate = 'user${1000 + rnd.nextInt(9000)}';
      try {
        await ConvexApi.call(
          'mutation',
          'username:registerUsername',
          {
            'userId': userId,
            'username': candidate,
            'isSignedIn': true,
          },
        );
        return candidate;
      } catch (_) {
        continue;
      }
    }
    // Best-effort fallback — should not normally reach here.
    return 'user${1000 + rnd.nextInt(9000)}';
  }

  void _refreshSession() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('situp-username');
    final userId = prefs.getString('situp-user-id');
    final signedIn = prefs.getBool('situp-signed-in') ?? false;

    if (!mounted) return;
    if (username != null && username.isNotEmpty && userId != null && userId.isNotEmpty) {
      setState(() {
        _session = AuthResult(
          username: username,
          userId: userId,
          isSignedIn: signedIn,
        );
      });
    }
  }

  Future<void> _signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('situp-username');
    await prefs.remove('situp-user-id');
    await prefs.remove('situp-auth-token');
    await prefs.remove('situp-signed-in');
    await prefs.remove('situp-pending-battle-code');
    if (!mounted) return;
    setState(() => _session = null);
  }

  /// Persists a rename so it survives app restarts.
  Future<void> _rename(String newUsername) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('situp-username', newUsername);
    if (!mounted) return;
    setState(() => _session = AuthResult(
          username: newUsername,
          userId: _session!.userId,
          isSignedIn: _session!.isSignedIn,
        ));
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return Scaffold(
        backgroundColor:
            widget.isDark ? const Color(0xFF1A1A2E) : const Color(0xFFFDF5F0),
        body: const Center(
          child: CircularProgressIndicator(color: Color(0xFFE8734A)),
        ),
      );
    }

    final session = _session;
    if (session != null) {
      return DashboardScreen(
        key: ValueKey('dashboard-${session.username}'),
        username: session.username,
        userId: session.userId,
        isSignedIn: session.isSignedIn,
        isDark: widget.isDark,
        onToggleTheme: widget.onToggleTheme,
        onSignOut: _signOut,
        onRename: _rename,
      );
    }

    return AuthScreen(
      isDark: widget.isDark,
      onToggleTheme: widget.onToggleTheme,
      onAuth: (result) {
        setState(() => _session = result);
      },
    );
  }
}
