import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthScreen extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;
  final Function(String) onAuth;

  const AuthScreen({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
    required this.onAuth,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _controller = TextEditingController();
  bool _isLoading = false;

  // Light colors
  static const Color _lightBg = Color(0xFFFDF5F0);
  static const Color _lightCard = Color(0xFFFFF0E8);
  static const Color _lightText = Color(0xFF3D2C2C);
  static const Color _lightSubtext = Color(0xFF9C8A8A);
  static const Color _accent = Color(0xFFE8734A);

  // Dark colors
  static const Color _darkBg = Color(0xFF1A1A2E);
  static const Color _darkCard = Color(0xFF252540);
  static const Color _darkText = Color(0xFFF5F5F5);
  static const Color _darkSubtext = Color(0xFF9CA3AF);

  Color get _bg => widget.isDark ? _darkBg : _lightBg;
  Color get _card => widget.isDark ? _darkCard : _lightCard;
  Color get _text => widget.isDark ? _darkText : _lightText;
  Color get _subtext => widget.isDark ? _darkSubtext : _lightSubtext;

  void _submit() async {
    final username = _controller.text.trim();
    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('Please enter a username')),
      );
      return;
    }

    setState(() => _isLoading = true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('situp-username', username);

    widget.onAuth(username);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const SizedBox(height: 40),

              // Theme toggle
              Align(
                alignment: Alignment.topRight,
                child: GestureDetector(
                  onTap: widget.onToggleTheme,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _card,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      widget.isDark ? Icons.light_mode : Icons.dark_mode,
                      color: _accent,
                      size: 22,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Logo
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _accent.withAlpha(30),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.shield, color: _accent, size: 40),
              ),

              const SizedBox(height: 24),

              // Title
              Text(
                "Situp Challenge",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: _text,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                "Track your reps. Compete with friends.",
                style: TextStyle(fontSize: 15, color: _subtext),
              ),

              const SizedBox(height: 48),

              // Username input
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: _accent.withAlpha(20),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Enter your username",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _text,
                      ),
                    ),

                    const SizedBox(height: 4),

                    Text(
                      "This will be shown on the leaderboard",
                      style: TextStyle(fontSize: 13, color: _subtext),
                    ),

                    const SizedBox(height: 16),

                    TextField(
                      controller: _controller,
                      style: TextStyle(color: _text, fontSize: 16),
                      decoration: InputDecoration(
                        hintText: "e.g. situpmaster",
                        hintStyle: TextStyle(color: _subtext),
                        filled: true,
                        fillColor: widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: Icon(Icons.person, color: _accent),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),

                    const SizedBox(height: 16),

                    // Submit button
                    GestureDetector(
                      onTap: _isLoading ? null : _submit,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _accent,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: _accent.withAlpha(60),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Center(
                          child: _isLoading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  "Get Started",
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Divider
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 1,
                      color: _subtext.withAlpha(30),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      "or",
                      style: TextStyle(fontSize: 13, color: _subtext),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      height: 1,
                      color: _subtext.withAlpha(30),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Sign in with email option
              GestureDetector(
                onTap: _signInWithEmail,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _accent.withAlpha(40),
                      width: 2,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.login,
                        color: _accent,
                        size: 22,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Sign in",
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: _text,
                              ),
                            ),
                            Text(
                              "Sign in to claim your username",
                              style: TextStyle(fontSize: 12, color: _subtext),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward,
                        color: _accent,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  void _signInWithEmail() async {
    setState(() => _isLoading = true);
    // Navigate to email sign-in flow
    // For now, this is a placeholder that will be connected to Convex Auth
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Email sign-in coming soon'),
        duration: Duration(seconds: 2),
      ),
    );
    setState(() => _isLoading = false);
  }
}
