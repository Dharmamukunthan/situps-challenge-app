import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:math';
import '../services/convex_api.dart';

class AuthResult {
  final String username;
  final String userId;
  final bool isSignedIn;
  AuthResult({
    required this.username,
    required this.userId,
    required this.isSignedIn,
  });
}

class AuthScreen extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;
  final Function(AuthResult) onAuth;

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

  // Email sign-in state
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  String _email = '';
  bool _awaitingCode = false;
  bool _emailLoading = false;
  String? _emailError;

  // Username state
  final _usernameController = TextEditingController();
  Timer? _debounce;
  String? _usernameMessage;
  bool _usernameAvailable = false;
  bool _usernameLoading = false;

  @override
  void initState() {
    super.initState();
    _suggestUsername();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  /// Suggests a free guest name like user1025 (keeps suggesting until one is free).
  Future<void> _suggestUsername() async {
    final rnd = Random();
    for (int i = 0; i < 5; i++) {
      final candidate = 'user${1000 + rnd.nextInt(9000)}';
      try {
        final value = await ConvexApi.call(
            'query', 'username:checkUsername', {'username': candidate});
        if (value is Map && value['valid'] == true) {
          if (!mounted) return;
          _usernameController.text = candidate;
          setState(() {
            _usernameAvailable = true;
            _usernameMessage = null;
          });
          return;
        }
      } catch (_) {
        // Backend unreachable — still prefill so the user can type manually
        if (!mounted) return;
        _usernameController.text = candidate;
        return;
      }
    }
  }

  void _onUsernameChanged(String value) {
    _debounce?.cancel();
    final name = value.trim().toLowerCase();
    if (name.length < 2) {
      setState(() {
        _usernameMessage = null;
        _usernameAvailable = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      setState(() => _usernameLoading = true);
      try {
        final value = await ConvexApi.call(
            'query', 'username:checkUsername', {'username': name});
        if (!mounted) return;
        if (value is Map) {
          setState(() {
            _usernameAvailable = value['valid'] == true;
            _usernameMessage = value['valid'] == true
                ? '✓ Available'
                : (value['error']?.toString() ?? 'Not available');
            _usernameLoading = false;
          });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _usernameMessage = 'Could not check right now';
          _usernameLoading = false;
          _usernameAvailable = false;
        });
      }
    });
  }

  /// Guest path: find-or-create the account, save it locally, enter the app.
  Future<void> _continueAsGuest() async {
    final name = _usernameController.text.trim().toLowerCase();
    if (name.length < 2) {
      setState(() => _usernameMessage = 'Enter at least 2 characters');
      return;
    }
    if (!_usernameAvailable) {
      setState(() => _usernameMessage = 'That username is not available');
      return;
    }

    setState(() => _usernameLoading = true);
    try {
      // Idempotent: returns existing account when the name already belongs to us
      final value = await ConvexApi.call('mutation', 'username:registerUser', {
        'username': name,
      });
      if (!mounted) return;
      final userId = value['userId'] as String;
      final username = value['username'] as String;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('situp-username', username);
      await prefs.setString('situp-user-id', userId);
      await prefs.setBool('situp-signed-in', false);

      widget.onAuth(AuthResult(
        username: username,
        userId: userId,
        isSignedIn: false,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _usernameLoading = false;
        _usernameMessage = e.toString().replaceFirst('ConvexApiException: ', '');
      });
    }
  }

  // --- Email OTP flow ---

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _emailError = 'Enter a valid email address');
      return;
    }
    setState(() {
      _emailLoading = true;
      _emailError = null;
    });
    try {
      await ConvexApi.sendEmailOtp(email);
      if (!mounted) return;
      setState(() {
        _email = email;
        _awaitingCode = true;
        _emailLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _emailError = e.toString().replaceFirst('ConvexApiException: ', '');
        _emailLoading = false;
      });
    }
  }

  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _emailError = 'Enter the 6-digit code from your email');
      return;
    }
    setState(() {
      _emailLoading = true;
      _emailError = null;
    });
    try {
      final result = await ConvexApi.verifyEmailOtp(_email, code);
      if (!mounted) return;
      final token = result['token'] as String;
      final userId = result['userId'] as String;

      // Resolve the account's username (signed-in users may not have claimed one yet)
      final prefs = await SharedPreferences.getInstance();
      String? username = await _fetchUsernameForUser(userId);

      if (username == null || username.isEmpty) {
        // First email sign-in: suggest a free guest-style name they can change anytime
        username = await _suggestAndClaimForSignedIn(userId, token);
      }

      await prefs.setString('situp-username', username);
      await prefs.setString('situp-user-id', userId);
      await prefs.setString('situp-auth-token', token);
      await prefs.setBool('situp-signed-in', true);

      widget.onAuth(AuthResult(
        username: username,
        userId: userId,
        isSignedIn: true,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _emailError = e.toString().replaceFirst('ConvexApiException: ', '');
        _emailLoading = false;
      });
    }
  }

  Future<String?> _fetchUsernameForUser(String userId) async {
    try {
      final value =
          await ConvexApi.call('query', 'username:getUsername', {
        'userId': userId,
      });
      return value as String?;
    } catch (_) {
      return null;
    }
  }

  /// For first-time email sign-ins, auto-claim a free user#### name
  /// (they can rename unlimited times later from the dashboard).
  Future<String> _suggestAndClaimForSignedIn(
      String userId, String token) async {
    final rnd = Random();
    for (int i = 0; i < 5; i++) {
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
        continue; // name taken, try another
      }
    }
    throw ConvexApiException('Could not create a username — try again');
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
              const SizedBox(height: 28),

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

              const SizedBox(height: 16),

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

              const SizedBox(height: 36),

              // ====== SIGN IN CARD (top) ======
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _accent.withAlpha(50), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: _accent.withAlpha(20),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: !_awaitingCode
                    ? _buildEmailStep()
                    : _buildCodeStep(),
              ),

              const SizedBox(height: 20),

              // Divider
              Row(
                children: [
                  Expanded(child: Container(height: 1, color: _subtext.withAlpha(30))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text("or",
                        style: TextStyle(fontSize: 13, color: _subtext)),
                  ),
                  Expanded(child: Container(height: 1, color: _subtext.withAlpha(30))),
                ],
              ),

              const SizedBox(height: 20),

              // ====== USERNAME CARD (guests) ======
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
                      "Play with a username",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "No email needed. Guests can rename once — sign in to rename anytime.",
                      style: TextStyle(fontSize: 13, color: _subtext),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _usernameController,
                      style: TextStyle(color: _text, fontSize: 16),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
                      ],
                      decoration: InputDecoration(
                        hintText: "e.g. situpmaster",
                        hintStyle: TextStyle(color: _subtext),
                        filled: true,
                        fillColor:
                            widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: Icon(Icons.person, color: _accent),
                        suffixIcon: _usernameLoading
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : _usernameMessage != null
                                ? Icon(
                                    _usernameAvailable ? Icons.check_circle : Icons.cancel,
                                    color: _usernameAvailable
                                        ? const Color(0xFF4CAF50)
                                        : const Color(0xFFE8534A),
                                    size: 22,
                                  )
                                : null,
                      ),
                      onChanged: _onUsernameChanged,
                    ),
                    if (_usernameMessage != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _usernameMessage!,
                        style: TextStyle(
                          fontSize: 13,
                          color: _usernameAvailable
                              ? const Color(0xFF4CAF50)
                              : const Color(0xFFE8534A),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _buildButton(
                      label: "Get Started",
                      onTap: _usernameLoading ? null : _continueAsGuest,
                      loading: _usernameLoading,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  // Email step: enter email → receive code
  Widget _buildEmailStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.login, color: _accent, size: 22),
            const SizedBox(width: 10),
            Text(
              "Sign in with email",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: _text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          "We'll email you a 6-digit code to verify it's you.",
          style: TextStyle(fontSize: 13, color: _subtext),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          style: TextStyle(color: _text, fontSize: 16),
          decoration: InputDecoration(
            hintText: "you@example.com",
            hintStyle: TextStyle(color: _subtext),
            filled: true,
            fillColor: widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            prefixIcon: Icon(Icons.mail, color: _accent),
          ),
          onSubmitted: (_) => _sendCode(),
        ),
        if (_emailError != null) ...[
          const SizedBox(height: 8),
          Text(
            _emailError!,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFFE8534A),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: 16),
        _buildButton(
          label: "Send Code",
          onTap: _emailLoading ? null : _sendCode,
          loading: _emailLoading,
        ),
      ],
    );
  }

  // Code step: enter 6-digit code → verified
  Widget _buildCodeStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.mark_email_read, color: _accent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Code sent to $_email",
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: _text,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          "Check your inbox (and spam folder) for the 6-digit code.",
          style: TextStyle(fontSize: 13, color: _subtext),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _text,
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: 8,
          ),
          decoration: InputDecoration(
            hintText: "••••••",
            hintStyle: TextStyle(color: _subtext, letterSpacing: 8),
            counterText: "",
            filled: true,
            fillColor: widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (_) => _verifyCode(),
        ),
        if (_emailError != null) ...[
          const SizedBox(height: 8),
          Text(
            _emailError!,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFFE8534A),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: 16),
        _buildButton(
          label: "Verify & Sign In",
          onTap: _emailLoading ? null : _verifyCode,
          loading: _emailLoading,
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton(
            onPressed: () {
              setState(() {
                _awaitingCode = false;
                _codeController.clear();
                _emailError = null;
              });
            },
            child: Text("Use a different email",
                style: TextStyle(fontSize: 13, color: _subtext)),
          ),
        ),
      ],
    );
  }

  Widget _buildButton({
    required String label,
    required VoidCallback? onTap,
    required bool loading,
  }) {
    return GestureDetector(
      onTap: onTap,
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
          child: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}
