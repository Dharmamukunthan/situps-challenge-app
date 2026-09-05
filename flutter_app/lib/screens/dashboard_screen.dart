import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:http/http.dart' as http;
import '../utils/pose_utils.dart';
import 'leaderboard_screen.dart';

class DashboardScreen extends StatefulWidget {
  final String username;
  final bool isDark;
  final VoidCallback onToggleTheme;
  final VoidCallback onSignOut;

  const DashboardScreen({
    super.key,
    required this.username,
    required this.isDark,
    required this.onToggleTheme,
    required this.onSignOut,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 0;

  // Battle state
  int _selectedDuration = 60;
  bool _isSearching = false;
  String? _battleId;
  String? _opponentName;
  bool _inBattle = false;
  int _battleTimeLeft = 0;
  int _battleMyReps = 0;
  int _battleOpponentReps = 0;
  Timer? _battleTimer;
  Timer? _pollTimer;
  String _searchStatus = "";
  bool _showJoinRoom = false;
  String _joinCode = "";

  // Camera state for battle
  CameraController? _cameraController;
  PoseDetector? _poseDetector;
  final SitupDetector _situpDetector = SitupDetector();
  bool _isCameraReady = false;
  bool _isProcessing = false;
  double _currentAngle = 180;
  String _cameraStatus = "Starting camera...";
  String _phaseLabel = "IDLE";
  int _confirmProgress = 0;

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

  @override
  void initState() {
    super.initState();
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );
  }

  @override
  void dispose() {
    _battleTimer?.cancel();
    _pollTimer?.cancel();
    _cameraController?.dispose();
    _poseDetector?.close();
    super.dispose();
  }

  // --- CAMERA FOR BATTLE ---
  Future<void> _startBattleCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _cameraStatus = "No camera found");
        return;
      }

      CameraDescription? selectedCamera;
      try {
        selectedCamera = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
        );
      } catch (_) {
        selectedCamera = cameras.first;
      }

      _cameraController = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }

      await _cameraController!.startImageStream((CameraImage image) {
        if (!_isProcessing && _inBattle) _processBattleFrame(image);
      });

      setState(() {
        _isCameraReady = true;
        _cameraStatus = "Camera ready — do situps!";
      });
    } catch (e) {
      setState(() => _cameraStatus = "Camera error: $e");
    }
  }

  Future<void> _stopBattleCamera() async {
    try {
      if (_cameraController != null && _cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
      await _cameraController?.dispose();
    } catch (_) {}
    _cameraController = null;
    setState(() => _isCameraReady = false);
  }

  Future<void> _processBattleFrame(CameraImage image) async {
    if (_isProcessing || _poseDetector == null || !_inBattle) return;
    _isProcessing = true;

    try {
      final inputImage = _convertCameraImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final poses = await _poseDetector!.processImage(inputImage);

      if (poses.isNotEmpty) {
        final pose = poses.first;
        final ls = pose.landmarks[PoseLandmarkType.leftShoulder];
        final rs = pose.landmarks[PoseLandmarkType.rightShoulder];
        final lh = pose.landmarks[PoseLandmarkType.leftHip];
        final rh = pose.landmarks[PoseLandmarkType.rightHip];
        final lk = pose.landmarks[PoseLandmarkType.leftKnee];
        final rk = pose.landmarks[PoseLandmarkType.rightKnee];

        double angle = 180;
        int keypointsFound = 0;

        if (ls != null && lh != null && lk != null) {
          angle = calculateAngle(ls, lh, lk);
          keypointsFound = 3;
        } else if (rs != null && rh != null && rk != null) {
          angle = calculateAngle(rs, rh, rk);
          keypointsFound = 3;
        }

        setState(() {
          _currentAngle = angle;
          _phaseLabel = _situpDetector.phase.name.toUpperCase();
          _confirmProgress = _situpDetector.confirmCount;
        });

        if (keypointsFound >= 3) {
          if (_situpDetector.processAngle(angle)) {
            setState(() {
              _battleMyReps = _situpDetector.repCount;
              _cameraStatus = "✅ Rep #$_battleMyReps counted!";
            });
          } else {
            if (angle > SitupDetector.lyingAngle) {
              setState(() => _cameraStatus = "↓ LYING — sit up!");
            } else if (angle < SitupDetector.sittingAngle) {
              setState(() => _cameraStatus = "↑ SITTING — lie back!");
            } else {
              setState(() => _cameraStatus = "↔ Moving...");
            }
          }
        }
      } else {
        setState(() {
          _cameraStatus = "❌ No body detected — move into view";
        });
      }
    } catch (_) {}

    _isProcessing = false;
  }

  InputImage? _convertCameraImage(CameraImage image) {
    final rotation = InputImageRotationValue.fromRawValue(
          _cameraController!.description.sensorOrientation,
        ) ??
        InputImageRotation.rotation0deg;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  // --- RANDOM MATCH ---
  void _startRandomMatch() async {
    setState(() {
      _isSearching = true;
      _searchStatus = "Searching for opponent...";
    });

    try {
      final response = await http.post(
        Uri.parse('https://graceful-mink-900.convex.site/api/mutation'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'path': 'matchmaking:findMatch',
          'args': {
            'userId': widget.username,
            'username': widget.username,
            'duration': _selectedDuration,
          }
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final result = data['result'] ?? data['value'];
        if (result != null && result is String) {
          setState(() => _battleId = result);
          _fetchBattleAndStart(result);
        } else if (result != null && result is Map && result['battleId'] != null) {
          final battleId = result['battleId'] as String;
          setState(() => _battleId = battleId);
          _fetchBattleAndStart(battleId);
        } else {
          _pollForMatch();
        }
      } else {
        setState(() => _isSearching = false);
        _showSnackBar("Failed to find match");
      }
    } catch (_) {
      setState(() => _isSearching = false);
      _showSnackBar("Network error");
    }
  }

  void _pollForMatch() {
    _pollTimer?.cancel();
    int attempts = 0;

    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      attempts++;

      if (mounted) {
        setState(() {
          _searchStatus = "Searching for opponent... ($attempts)";
        });
      }

      if (attempts > 90) {
        timer.cancel();
        if (mounted) setState(() => _isSearching = false);
        _showSnackBar("No opponent found. Try again.");
        return;
      }

      try {
        final response = await http.post(
          Uri.parse('https://graceful-mink-900.convex.site/api/query'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'path': 'matchmaking:getMyMatch',
            'args': {'userId': widget.username},
          }),
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final result = data['result'] ?? data['value'];

          if (result != null && result is Map && result['battleId'] != null) {
            timer.cancel();
            final battleId = result['battleId'] as String;
            setState(() => _battleId = battleId);
            _fetchBattleAndStart(battleId);
          }
        }
      } catch (_) {}
    });
  }

  void _pollBattleForOpponent() {
    _pollTimer?.cancel();
    int attempts = 0;

    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      attempts++;

      if (mounted) {
        setState(() {
          _searchStatus = "Waiting for opponent... ($attempts)";
        });
      }

      if (attempts > 90) {
        timer.cancel();
        if (mounted) setState(() => _isSearching = false);
        _showSnackBar("No opponent joined. Try again.");
        return;
      }

      try {
        final response = await http.post(
          Uri.parse('https://graceful-mink-900.convex.site/api/query'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'path': 'battles:getBattle',
            'args': {'battleId': _battleId!},
          }),
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final battle = data['result'] ?? data['value'];

          if (battle != null && battle is Map && battle['opponentId'] != null && battle['opponentId'] != "") {
            timer.cancel();
            _startBattle(battle['opponentId'] ?? "Friend", battle['duration'] ?? _selectedDuration);
          }
        }
      } catch (_) {}
    });
  }

  void _fetchBattleAndStart(String battleId) async {
    try {
      final response = await http.post(
        Uri.parse('https://graceful-mink-900.convex.site/api/query'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'path': 'battles:getBattle',
          'args': {'battleId': battleId},
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final battle = data['result'] ?? data['value'];

        if (battle != null && battle is Map) {
          final opponentName = battle['creatorId'] == widget.username
              ? (battle['opponentId'] ?? 'Opponent')
              : (battle['creatorId'] ?? 'Opponent');
          final duration = battle['duration'] ?? _selectedDuration;

          _startBattle(opponentName, duration);
          return;
        }
      }
    } catch (_) {}

    _startBattle("Opponent", _selectedDuration);
  }

  void _startBattle(String opponent, int duration) async {
    setState(() {
      _isSearching = false;
      _inBattle = true;
      _opponentName = opponent;
      _battleTimeLeft = duration;
      _battleMyReps = 0;
      _battleOpponentReps = 0;
      _cameraStatus = "Starting camera...";
    });

    // Start camera for counting
    _situpDetector.reset();
    await _startBattleCamera();

    _battleTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _battleTimeLeft--;
        if (_battleTimeLeft <= 0) {
          timer.cancel();
          _endBattle();
        }
      });
    });

    _startOpponentScorePolling();
  }

  void _startOpponentScorePolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!_inBattle || _battleId == null) {
        timer.cancel();
        return;
      }

      try {
        // Poll opponent score
        final response = await http.post(
          Uri.parse('https://graceful-mink-900.convex.site/api/query'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'path': 'battles:getBattle',
            'args': {'battleId': _battleId!},
          }),
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final battle = data['result'] ?? data['value'];

          if (battle != null && battle is Map && mounted) {
            setState(() {
              if (battle['creatorId'] == widget.username) {
                _battleOpponentReps = battle['opponentScore'] ?? 0;
              } else {
                _battleOpponentReps = battle['creatorScore'] ?? 0;
              }
            });
          }
        }

        // Update our score on server
        await http.post(
          Uri.parse('https://graceful-mink-900.convex.site/api/mutation'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'path': 'battles:updateScore',
            'args': {
              'battleId': _battleId!,
              'userId': widget.username,
              'score': _battleMyReps,
            },
          }),
        );
      } catch (_) {}
    });
  }

  void _endBattle() async {
    _battleTimer?.cancel();
    _pollTimer?.cancel();

    // Stop camera
    await _stopBattleCamera();

    final myScore = _battleMyReps;
    final oppScore = _battleOpponentReps;
    final won = myScore > oppScore;
    final tied = myScore == oppScore;

    String resultText;
    if (tied) {
      resultText = "It's a tie!";
    } else if (won) {
      resultText = "You won! 🎉";
    } else {
      resultText = "You lost 😔";
    }

    setState(() => _inBattle = false);

    if (_battleId != null) {
      http.post(
        Uri.parse('https://graceful-mink-900.convex.site/api/mutation'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'path': 'battles:endBattle',
          'args': {'battleId': _battleId!},
        }),
      ).catchError((_) {});
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: _card,
        title: Text(resultText, textAlign: TextAlign.center, style: TextStyle(color: _text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("You: $myScore reps",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _accent)),
            Text("$_opponentName: $oppScore reps",
                style: TextStyle(fontSize: 18, color: _subtext)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("OK", style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // --- PRIVATE ROOM ---
  void _joinPrivateRoom() async {
    if (_joinCode.isEmpty || _joinCode.length < 6) {
      _showSnackBar("Enter a 6-character code");
      return;
    }

    setState(() {
      _isSearching = true;
      _searchStatus = "Joining room $_joinCode...";
    });

    try {
      final response = await http.post(
        Uri.parse('https://graceful-mink-900.convex.site/api/mutation'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'path': 'battles:joinBattle',
          'args': {
            'battleCode': _joinCode,
            'opponentId': widget.username,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final result = data['result'] ?? data['value'];

        if (result != null) {
          final battleId = result is String ? result : (result as Map)['id'] as String?;
          if (battleId != null) {
            setState(() => _battleId = battleId);
            _fetchBattleAndStart(battleId);
            setState(() => _showJoinRoom = false);
            return;
          }
        }
      }

      setState(() {
        _isSearching = false;
        _searchStatus = "";
      });
      _showSnackBar("Failed to join room. Check the code.");
    } catch (_) {
      setState(() {
        _isSearching = false;
        _searchStatus = "";
      });
      _showSnackBar("Network error");
    }
  }

  void _showCreatePrivateRoom() async {
    setState(() {
      _isSearching = true;
      _searchStatus = "Creating room...";
    });

    try {
      final response = await http.post(
        Uri.parse('https://graceful-mink-900.convex.site/api/mutation'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'path': 'battles:createBattle',
          'args': {
            'creatorId': widget.username,
            'duration': _selectedDuration,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final result = data['result'] ?? data['value'];

        String? battleId;
        String? code;

        if (result is Map) {
          battleId = result['id'] as String?;
          code = result['code'] as String?;
        } else if (result is String) {
          battleId = result;
        }

        if (battleId != null) {
          setState(() {
            _battleId = battleId;
            _searchStatus = code != null ? "Room code: $code (share with friend)" : "Room created! Waiting for opponent...";
          });
          _pollBattleForOpponent();
        } else {
          setState(() => _isSearching = false);
          _showSnackBar("Failed to create room");
        }
      } else {
        setState(() => _isSearching = false);
        _showSnackBar("Failed to create room");
      }
    } catch (_) {
      setState(() => _isSearching = false);
      _showSnackBar("Network error");
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      _buildCounterTab(),
      _buildBattlesScreen(),
      LeaderboardScreen(isDark: widget.isDark),
    ];

    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 50, 20, 16),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(28),
                bottomRight: Radius.circular(28),
              ),
              boxShadow: [
                BoxShadow(
                  color: _accent.withAlpha(15),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _accent.withAlpha(30),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.shield, color: _accent, size: 22),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Situp Challenge",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: _text,
                      ),
                    ),
                    Text(
                      widget.username,
                      style: TextStyle(fontSize: 13, color: _subtext),
                    ),
                  ],
                ),
                const Spacer(),
                // Theme toggle
                GestureDetector(
                  onTap: widget.onToggleTheme,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _accent.withAlpha(20),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      widget.isDark ? Icons.light_mode : Icons.dark_mode,
                      color: _accent,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Sign out
                GestureDetector(
                  onTap: widget.onSignOut,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _accent.withAlpha(20),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.logout, color: _accent, size: 20),
                  ),
                ),
              ],
            ),
          ),

          // Content
          Expanded(child: screens[_currentIndex]),

          // Bottom nav
          Container(
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: _accent.withAlpha(20),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(0, Icons.camera_alt, "Count"),
                _buildNavItem(1, null, "Head-to-Head", emoji: "⚔️"),
                _buildNavItem(2, Icons.emoji_events, "Leaderboard"),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- COUNTER TAB (simplified — delegates to SitupCounterScreen concept) ---
  Widget _buildCounterTab() {
    return _CounterTab(
      isDark: widget.isDark,
      accent: _accent,
      card: _card,
      text: _text,
      subtext: _subtext,
    );
  }

  Widget _buildNavItem(int index, IconData? icon, String label, {String? emoji}) {
    final isSelected = _currentIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: isSelected
            ? BoxDecoration(
                color: _accent.withAlpha(30),
                borderRadius: BorderRadius.circular(16),
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (emoji != null)
              Text(
                emoji,
                style: TextStyle(
                  fontSize: 22,
                  color: isSelected ? _accent : _subtext,
                ),
              )
            else if (icon != null)
              Icon(
                icon,
                color: isSelected ? _accent : _subtext,
                size: 22,
              ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? _accent : _subtext,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDurationChip(int seconds, String label) {
    final isSelected = _selectedDuration == seconds;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedDuration = seconds),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: isSelected ? _accent : (widget.isDark ? const Color(0xFF2D2D44) : Colors.white),
            borderRadius: BorderRadius.circular(16),
            boxShadow: isSelected
                ? [BoxShadow(color: _accent.withAlpha(40), blurRadius: 10)]
                : [],
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: isSelected ? Colors.white : _text,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBattlesScreen() {
    if (_inBattle) return _buildActiveBattle();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Main battle card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: _accent.withAlpha(20),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              children: [
                // Title
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _accent.withAlpha(30),
                    shape: BoxShape.circle,
                  ),
                  child: const Text("⚔️", style: TextStyle(fontSize: 28)),
                ),
                const SizedBox(height: 16),
                Text(
                  "Head-to-Head",
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: _text,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Choose how you want to compete.",
                  style: TextStyle(fontSize: 14, color: _subtext),
                ),

                const SizedBox(height: 24),

                // Duration selector
                Text(
                  "Select Duration",
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _text,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _buildDurationChip(30, "30s"),
                    const SizedBox(width: 10),
                    _buildDurationChip(60, "1 min"),
                    const SizedBox(width: 10),
                    _buildDurationChip(300, "5 min"),
                  ],
                ),

                const SizedBox(height: 24),

                // Random Match button
                _buildBattleOption(
                  icon: Icons.language,
                  title: "Random Match",
                  subtitle: _isSearching ? _searchStatus : "Compete against a random online player",
                  color: _accent,
                  isSearching: _isSearching,
                  onTap: _isSearching ? null : _startRandomMatch,
                ),

                const SizedBox(height: 14),

                // Private Room button
                _buildBattleOption(
                  icon: Icons.lock,
                  title: "Private Room",
                  subtitle: "Create a room and invite friends with a code",
                  color: const Color(0xFF4CAF50),
                  onTap: () =>        _showCreatePrivateRoom(),
                ),
              ],
            ),
          ),

          // Join Room section
          if (_showJoinRoom)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: _accent.withAlpha(20),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.login, color: const Color(0xFF4CAF50), size: 20),
                      const SizedBox(width: 10),
                      Text("Join a Private Room",
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _text)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    decoration: InputDecoration(
                      hintText: "Enter room code (e.g. ABCD12)",
                      filled: true,
                      fillColor: widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                    ),
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 6,
                    onChanged: (val) => _joinCode = val.toUpperCase(),
                  ),
                  const SizedBox(height: 12),
                  if (_joinCode.length == 6)
                    ElevatedButton(
                      onPressed: _joinPrivateRoom,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: const Text("Join Room", style: TextStyle(fontWeight: FontWeight.bold)),
                    )
                  else
                    Text(
                      "Enter 6-character code",
                      style: TextStyle(fontSize: 12, color: _subtext),
                    ),
                ],
              ),
            ),

          // Hidden join mode toggle
          GestureDetector(
            onTap: () {
              setState(() {
                _showJoinRoom = !_showJoinRoom;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: _accent.withAlpha(20),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _showJoinRoom ? Icons.close : Icons.group_add,
                    color: _accent,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _showJoinRoom ? "Hide Join" : "Join a friend's room",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBattleOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    bool isSearching = false,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withAlpha(40), width: 2),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: isSearching
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color,
                      ),
                    )
                  : Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _text,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 13, color: _subtext),
                  ),
                ],
              ),
            ),
            if (!isSearching) Icon(Icons.chevron_right, color: color),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveBattle() {
    final minutes = _battleTimeLeft ~/ 60;
    final seconds = _battleTimeLeft % 60;

    return Column(
      children: [
        // Camera view (top half)
        Expanded(
          flex: 3,
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: _accent.withAlpha(20),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: _isCameraReady && _cameraController != null
                ? Stack(
                    children: [
                      CameraPreview(_cameraController!),
                      // Timer badge
                      Positioned(
                        top: 12, left: 12,
                        child: _buildBadge(
                          "${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}",
                          _battleTimeLeft <= 10 ? Colors.red : _accent,
                        ),
                      ),
                      // Reps badge
                      Positioned(
                        top: 12, right: 12,
                        child: _buildBadge("⚡ $_battleMyReps", _accent),
                      ),
                      // Camera status
                      Positioned(
                        bottom: 12, left: 12, right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: widget.isDark ? const Color(0xFF2D2D44).withAlpha(230) : Colors.white.withAlpha(220),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            _cameraStatus,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _text,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: _accent,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _cameraStatus,
                        style: TextStyle(color: _subtext, fontSize: 14),
                      ),
                    ],
                  ),
          ),
        ),

        // Scoreboard (bottom part)
        Expanded(
          flex: 2,
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: _accent.withAlpha(20),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "⚔️ BATTLE IN PROGRESS",
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: _accent,
                  ),
                ),
                const SizedBox(height: 12),
                // Scores
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(
                      children: [
                        Text(
                          "You",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: _text,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "$_battleMyReps",
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            color: _accent,
                          ),
                        ),
                        Text("reps", style: TextStyle(fontSize: 12, color: _subtext)),
                      ],
                    ),
                    Container(
                      width: 2,
                      height: 50,
                      color: _subtext.withAlpha(50),
                    ),
                    Column(
                      children: [
                        Text(
                          _opponentName ?? "Opponent",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: _text,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "$_battleOpponentReps",
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF2196F3),
                          ),
                        ),
                        Text("reps", style: TextStyle(fontSize: 12, color: _subtext)),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(220),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(15), blurRadius: 8)],
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.bold)),
    );
  }
}

// --- COUNTER TAB WIDGET (inline to keep file self-contained) ---
class _CounterTab extends StatefulWidget {
  final bool isDark;
  final Color accent;
  final Color card;
  final Color text;
  final Color subtext;

  const _CounterTab({
    required this.isDark,
    required this.accent,
    required this.card,
    required this.text,
    required this.subtext,
  });

  @override
  State<_CounterTab> createState() => _CounterTabState();
}

class _CounterTabState extends State<_CounterTab> {
  CameraController? _cameraController;
  PoseDetector? _poseDetector;
  final SitupDetector _situpDetector = SitupDetector();

  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  double _currentAngle = 180;
  int _repCount = 0;
  int _manualReps = 0;
  String _status = "Tap Start to begin";
  String _phaseLabel = "IDLE";
  int _confirmProgress = 0;
  String _debugInfo = "";

  static const Color _lightBg = Color(0xFFFDF5F0);
  static const Color _lightCard = Color(0xFFFFF0E8);
  static const Color _lightText = Color(0xFF3D2C2C);
  static const Color _lightSubtext = Color(0xFF9C8A8A);
  static const Color _accentColor = Color(0xFFE8734A);
  static const Color _darkBg = Color(0xFF1A1A2E);
  static const Color _darkCard = Color(0xFF252540);
  static const Color _darkText = Color(0xFFF5F5F5);
  static const Color _darkSubtext = Color(0xFF9CA3AF);

  Color get _bgColor => widget.isDark ? _darkBg : _lightBg;
  Color get _cardColor => widget.isDark ? _darkCard : _lightCard;
  Color get _textColor => widget.isDark ? _darkText : _lightText;
  Color get _subtextColor => widget.isDark ? _darkSubtext : _lightSubtext;

  @override
  void initState() {
    super.initState();
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _status = "No camera found");
        return;
      }

      CameraDescription? selectedCamera;
      try {
        selectedCamera = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
        );
      } catch (_) {
        selectedCamera = cameras.first;
      }

      _cameraController = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }

      await _cameraController!.startImageStream((CameraImage image) {
        if (!_isProcessing) _processFrame(image);
      });

      setState(() {
        _isCameraInitialized = true;
        _status = "Camera ready — position yourself";
      });
    } catch (e) {
      setState(() => _status = "Camera error: $e");
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    if (_isProcessing || _poseDetector == null) return;
    _isProcessing = true;

    try {
      final inputImage = _convertCameraImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final poses = await _poseDetector!.processImage(inputImage);

      if (poses.isNotEmpty) {
        final pose = poses.first;
        final ls = pose.landmarks[PoseLandmarkType.leftShoulder];
        final rs = pose.landmarks[PoseLandmarkType.rightShoulder];
        final lh = pose.landmarks[PoseLandmarkType.leftHip];
        final rh = pose.landmarks[PoseLandmarkType.rightHip];
        final lk = pose.landmarks[PoseLandmarkType.leftKnee];
        final rk = pose.landmarks[PoseLandmarkType.rightKnee];

        double angle = 180;
        String side = "none";
        int keypointsFound = 0;

        if (ls != null && lh != null && lk != null) {
          angle = calculateAngle(ls, lh, lk);
          side = "LEFT";
          keypointsFound = 3;
        } else if (rs != null && rh != null && rk != null) {
          angle = calculateAngle(rs, rh, rk);
          side = "RIGHT";
          keypointsFound = 3;
        }

        _debugInfo = "Keypoints:$keypointsFound Side:$side Angle:${angle.toStringAsFixed(0)}";

        setState(() {
          _currentAngle = angle;
          _phaseLabel = _situpDetector.phase.name.toUpperCase();
          _confirmProgress = _situpDetector.confirmCount;
        });

        if (keypointsFound >= 3) {
          if (_situpDetector.processAngle(angle)) {
            setState(() {
              _repCount = _situpDetector.repCount;
              _status = "✅ Rep #$_repCount counted!";
            });
          } else {
            if (angle > SitupDetector.lyingAngle) {
              setState(() => _status = "↓ LYING — sit up!");
            } else if (angle < SitupDetector.sittingAngle) {
              setState(() => _status = "↑ SITTING — lie back!");
            } else {
              setState(() => _status = "↔ Moving...");
            }
          }
        } else {
          setState(() => _status = "⚠️ Only $keypointsFound keypoints — adjust position");
        }
      } else {
        setState(() {
          _status = "❌ No body detected — move into view";
          _debugInfo = "No pose found";
        });
      }
    } catch (_) {}

    _isProcessing = false;
  }

  InputImage? _convertCameraImage(CameraImage image) {
    final rotation = InputImageRotationValue.fromRawValue(
          _cameraController!.description.sensorOrientation,
        ) ??
        InputImageRotation.rotation0deg;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  void _startSession() async {
    _situpDetector.reset();
    setState(() {
      _repCount = 0;
      _manualReps = 0;
      _status = "Starting camera...";
    });
    await _startCamera();
  }

  void _endSession() async {
    await _cameraController?.stopImageStream();
    await _cameraController?.dispose();
    _cameraController = null;
    final totalReps = _repCount + _manualReps;
    setState(() {
      _isCameraInitialized = false;
      _status = "Session ended — $totalReps reps";
    });
  }

  void _resetSession() {
    _situpDetector.reset();
    setState(() {
      _repCount = 0;
      _manualReps = 0;
      _currentAngle = 180;
      _status = "Reset — ready";
      _phaseLabel = "IDLE";
      _confirmProgress = 0;
      _debugInfo = "";
    });
  }

  void _addManualRep() {
    setState(() {
      _manualReps++;
      _status = "Manual +1 (total: ${_repCount + _manualReps})";
    });
  }

  void _undoRep() {
    if (_manualReps > 0) {
      setState(() {
        _manualReps--;
        _status = "Undid last rep (total: ${_repCount + _manualReps})";
      });
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _poseDetector?.close();
    super.dispose();
  }

  int get _totalReps => _repCount + _manualReps;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Stats row
          Row(
            children: [
              _buildStatCard("$_totalReps", "Total", Icons.local_fire_department, _accentColor),
              const SizedBox(width: 10),
              _buildStatCard("$_repCount", "AI", Icons.smart_toy, const Color(0xFF4CAF50)),
              const SizedBox(width: 10),
              _buildStatCard("$_manualReps", "Manual", Icons.touch_app, const Color(0xFF2196F3)),
            ],
          ),

          const SizedBox(height: 16),

          // Camera / placeholder
          Container(
            width: double.infinity,
            height: _isCameraInitialized ? 280 : 180,
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(color: _accentColor.withAlpha(20), blurRadius: 20, offset: const Offset(0, 8)),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: _isCameraInitialized && _cameraController != null
                ? Stack(
                    children: [
                      CameraPreview(_cameraController!),
                      Positioned(
                        top: 12, left: 12,
                        child: _buildBadge("${_currentAngle.toStringAsFixed(0)}°", _getAngleColor()),
                      ),
                      Positioned(
                        top: 12, right: 12,
                        child: _buildBadge("⚡ $_totalReps", _accentColor),
                      ),
                      Positioned(
                        bottom: 12, left: 12, right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: widget.isDark ? const Color(0xFF2D2D44).withAlpha(230) : Colors.white.withAlpha(220),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(_status,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: _textColor, fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      Positioned(
                        bottom: 60, right: 16,
                        child: GestureDetector(
                          onTap: _addManualRep,
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: _accentColor,
                              shape: BoxShape.circle,
                              boxShadow: [BoxShadow(color: _accentColor.withAlpha(80), blurRadius: 12, offset: const Offset(0, 4))],
                            ),
                            child: const Icon(Icons.add, color: Colors.white, size: 28),
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.videocam_off, size: 48, color: _subtextColor),
                      const SizedBox(height: 12),
                      Text("Camera is off", style: TextStyle(color: _subtextColor, fontSize: 16)),
                    ],
                  ),
          ),

          const SizedBox(height: 16),

          // Rep counter card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(color: _accentColor.withAlpha(20), blurRadius: 20, offset: const Offset(0, 8))],
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: _accentColor.withAlpha(30), shape: BoxShape.circle),
                  child: Icon(Icons.emoji_events, size: 40, color: _accentColor),
                ),
                const SizedBox(height: 16),
                Text("$_totalReps reps",
                    style: TextStyle(fontSize: 48, fontWeight: FontWeight.w900, color: _textColor)),
                const SizedBox(height: 4),
                Text(_status, style: TextStyle(fontSize: 14, color: _subtextColor)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: widget.isDark ? const Color(0xFF2D2D44) : Colors.white, borderRadius: BorderRadius.circular(20)),
                  child: Text("Goal: 100", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _subtextColor)),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Daily goal progress
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(color: _accentColor.withAlpha(20), blurRadius: 20, offset: const Offset(0, 8))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.emoji_events, size: 20, color: _accentColor),
                        const SizedBox(width: 8),
                        Text("Daily Goal", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _textColor)),
                      ],
                    ),
                    Text("$_totalReps/100", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _textColor)),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: (_totalReps / 100).clamp(0.0, 1.0),
                    backgroundColor: widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
                    valueColor: AlwaysStoppedAnimation(_totalReps >= 100 ? const Color(0xFF4CAF50) : _accentColor),
                    minHeight: 8,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // +1 button
          if (_isCameraInitialized)
            SizedBox(
              width: double.infinity, height: 60,
              child: ElevatedButton(
                onPressed: _addManualRep,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accentColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  elevation: 0,
                ),
                child: const Text("+1 Rep", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
            ),

          if (_isCameraInitialized) const SizedBox(height: 12),

          // Action buttons
          Row(
            children: [
              if (_isCameraInitialized)
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _undoRep,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
                        foregroundColor: _textColor,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: const Text("Undo"),
                    ),
                  ),
                ),
              if (_isCameraInitialized) const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isCameraInitialized ? _endSession : _startSession,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isCameraInitialized ? const Color(0xFFE8534A) : _accentColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: Text(_isCameraInitialized ? "End Session" : "Start AI Counting",
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
              if (_isCameraInitialized) const SizedBox(width: 10),
              if (_isCameraInitialized)
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _resetSession,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
                        foregroundColor: _textColor,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: const Text("Reset"),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 16),

          // Debug info
          if (_isCameraInitialized)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _cardColor,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Debug: $_debugInfo",
                      style: TextStyle(fontSize: 11, color: _subtextColor, fontFamily: 'monospace')),
                  Text("Phase: $_phaseLabel | Confirm: $_confirmProgress/${SitupDetector.confirmFrames}",
                      style: TextStyle(fontSize: 11, color: _subtextColor, fontFamily: 'monospace')),
                ],
              ),
            ),

          if (_isCameraInitialized) const SizedBox(height: 16),

          // Phone placement guide
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 18, color: _accentColor),
                    const SizedBox(width: 8),
                    Text("Phone Placement", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _textColor)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  "1. Place phone on floor or prop it up on its SIDE\n"
                  "2. Back camera should see your full body from the side\n"
                  "3. Make sure your whole body is in the frame\n"
                  "4. Lie down → sit up → lie back = 1 rep\n"
                  "5. If AI doesn't count, use the +1 button",
                  style: TextStyle(fontSize: 12, color: _subtextColor, height: 1.6),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Color _getAngleColor() {
    if (_currentAngle > SitupDetector.lyingAngle) return const Color(0xFFE8534A);
    if (_currentAngle < SitupDetector.sittingAngle) return const Color(0xFF4CAF50);
    return const Color(0xFFFFC107);
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(220),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(15), blurRadius: 8)],
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildStatCard(String value, String label, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _cardColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: color.withAlpha(15), blurRadius: 15, offset: const Offset(0, 6))],
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 6),
            Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: _textColor)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: _subtextColor)),
          ],
        ),
      ),
    );
  }
}
