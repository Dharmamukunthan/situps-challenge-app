import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../utils/pose_utils.dart';
import '../services/convex_api.dart';
import 'leaderboard_screen.dart';

enum BattlePhase { lobby, privateLobby, searching, waiting, countdown, active }

class DashboardScreen extends StatefulWidget {
  final String username;
  final String userId;
  final bool isSignedIn;
  final bool isDark;
  final VoidCallback onToggleTheme;
  final VoidCallback onSignOut;
  final Function(String) onRename;

  const DashboardScreen({
    super.key,
    required this.username,
    required this.userId,
    required this.isSignedIn,
    required this.isDark,
    required this.onToggleTheme,
    required this.onSignOut,
    required this.onRename,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 0;

  // ---- Battle state ----
  BattlePhase _battlePhase = BattlePhase.lobby;
  int _selectedDuration = 60;
  int _battleDuration = 60; // server-confirmed duration for the active battle
  String? _battleId;
  String? _battleCode;
  String _opponentName = "Opponent";
  int _battleTimeLeft = 0;
  int _battleMyReps = 0;
  int _battleOpponentReps = 0;
  int _countdown = 3;
  int _searchSeconds = 0;
  Timer? _battleTimer;
  Timer? _pollTimer;
  Timer? _syncTimer;
  Timer? _countdownTimer;
  Timer? _searchClockTimer;
  bool _isStartingBattle = false;
  final _joinCodeController = TextEditingController();

  // ---- Camera state for battle ----
  CameraController? _cameraController;
  PoseDetector? _poseDetector;
  final SitupDetector _situpDetector = SitupDetector();
  bool _isCameraReady = false;
  bool _isProcessing = false;
  double _currentAngle = 180;
  String _cameraStatus = "Starting camera...";

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
    _syncTimer?.cancel();
    _countdownTimer?.cancel();
    _searchClockTimer?.cancel();
    _joinCodeController.dispose();
    _cameraController?.dispose();
    _poseDetector?.close();
    super.dispose();
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // =====================================================================
  // RENAME (guests: one time only — signed-in: unlimited)
  // =====================================================================
  void _showRenameDialog() {
    final controller = TextEditingController(text: widget.username);
    String? error;
    bool saving = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: _card,
          title: Text("Change username",
              style: TextStyle(color: _text, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.isSignedIn
                    ? "Signed in — rename as many times as you like."
                    : "Guests can rename ONCE. Sign in to rename anytime.",
                style: TextStyle(fontSize: 13, color: _subtext),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                maxLength: 16,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
                ],
                style: TextStyle(color: _text),
                decoration: InputDecoration(
                  hintText: "e.g. situpmaster",
                  counterText: "",
                  filled: true,
                  fillColor: widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!,
                    style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFE8534A),
                        fontWeight: FontWeight.w600)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text("Cancel", style: TextStyle(color: _subtext)),
            ),
            TextButton(
              onPressed: saving
                  ? null
                  : () async {
                      final name = controller.text.trim().toLowerCase();
                      if (name.length < 2) {
                        setDialogState(() => error = "Enter at least 2 characters");
                        return;
                      }
                      setDialogState(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        await ConvexApi.call(
                            'mutation', 'username:registerUsername', {
                          'userId': widget.userId,
                          'username': name,
                          'isSignedIn': widget.isSignedIn,
                        });
                        if (!mounted) return;
                        Navigator.pop(ctx);
                        widget.onRename(name);
                        _showSnackBar("Username updated to $name");
                      } catch (e) {
                        setDialogState(() {
                          saving = false;
                          error = e
                              .toString()
                              .replaceFirst('ConvexApiException: ', '');
                        });
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text("Save",
                      style: TextStyle(
                          color: _accent, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================================
  // CAMERA (shared by random match + private room battles)
  // =====================================================================
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
        if (!_isProcessing && mounted && _battlePhase == BattlePhase.active) {
          _processBattleFrame(image);
        }
      });

      if (!mounted) return;
      setState(() {
        _isCameraReady = true;
        _cameraStatus = "Camera ready — do situps!";
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraStatus = "Camera error: check permission");
    }
  }

  Future<void> _stopBattleCamera() async {
    try {
      if (_cameraController != null &&
          _cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
      await _cameraController?.dispose();
    } catch (_) {}
    _cameraController = null;
    if (mounted) setState(() => _isCameraReady = false);
  }

  Future<void> _processBattleFrame(CameraImage image) async {
    if (_isProcessing || _poseDetector == null) return;
    _isProcessing = true;

    try {
      final inputImage = _convertCameraImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final poses = await _poseDetector!.processImage(inputImage);

      if (poses.isNotEmpty && mounted) {
        final pose = poses.first;
        final ls = pose.landmarks[PoseLandmarkType.leftShoulder];
        final rs = pose.landmarks[PoseLandmarkType.rightShoulder];
        final lh = pose.landmarks[PoseLandmarkType.leftHip];
        final rh = pose.landmarks[PoseLandmarkType.rightHip];
        final lk = pose.landmarks[PoseLandmarkType.leftKnee];
        final rk = pose.landmarks[PoseLandmarkType.rightKnee];

        double angle = 180;
        bool valid = false;

        if (ls != null && lh != null && lk != null) {
          angle = calculateAngle(ls, lh, lk);
          valid = true;
        } else if (rs != null && rh != null && rk != null) {
          angle = calculateAngle(rs, rh, rk);
          valid = true;
        }

        setState(() => _currentAngle = angle);

        if (valid) {
          if (_situpDetector.processAngle(angle)) {
            setState(() {
              _battleMyReps = _situpDetector.repCount;
              _cameraStatus = "✅ Rep #$_battleMyReps counted!";
            });
          } else if (angle > SitupDetector.lyingAngle) {
            setState(() => _cameraStatus = "↓ LYING — sit up!");
          } else if (angle < SitupDetector.sittingAngle) {
            setState(() => _cameraStatus = "↑ SITTING — lie back!");
          } else {
            setState(() => _cameraStatus = "↔ Moving...");
          }
        }
      } else if (mounted) {
        setState(() => _cameraStatus = "❌ No body detected — move into view");
      }
    } catch (_) {}

    _isProcessing = false;
  }

  InputImage? _convertCameraImage(CameraImage image) {
    final controller = _cameraController;
    if (controller == null) return null;

    final rotation = InputImageRotationValue.fromRawValue(
          controller.description.sensorOrientation,
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

  // =====================================================================
  // RANDOM MATCH — unlimited search until an opponent joins
  // =====================================================================
  Future<void> _startRandomMatch() async {
    _cancelAllTimers();
    setState(() {
      _battlePhase = BattlePhase.searching;
      _searchSeconds = 0;
      _battleMyReps = 0;
      _battleOpponentReps = 0;
      _opponentName = "Opponent";
      _battleId = null;
    });

    // Elapsed-time ticker for the searching screen
    _searchClockTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (mounted) setState(() => _searchSeconds++);
    });

    try {
      final result = await ConvexApi.call('mutation', 'matchmaking:findMatch', {
        'userId': widget.userId,
        'username': widget.username,
        'duration': _selectedDuration,
      });

      if (result != null && result is String) {
        // Instantly paired with a waiting opponent
        _searchClockTimer?.cancel();
        await _onRandomMatchFound(result);
        return;
      }

      // Nobody waiting yet — keep polling until someone joins (no time limit)
      _pollForMatch();
    } catch (e) {
      _cancelAllTimers();
      if (mounted) setState(() => _battlePhase = BattlePhase.lobby);
      _showSnackBar(e.toString().replaceFirst('ConvexApiException: ', ''));
    }
  }

  void _pollForMatch() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      try {
        final result = await ConvexApi.call(
            'query', 'matchmaking:getMyMatch', {'userId': widget.userId});

        if (result != null && result is Map && result['battleId'] != null) {
          timer.cancel();
          _searchClockTimer?.cancel();
          await _onRandomMatchFound(result['battleId'] as String);
        }
      } catch (_) {
        // transient network error — keep searching
      }
    });
  }

  Future<void> _onRandomMatchFound(String battleId) async {
    // Pull the SERVER-side duration + opponent name so both players get a fair,
    // identical start no matter when each joined the queue.
    int duration = _selectedDuration;
    String opponentName = "Opponent";
    try {
      final match = await ConvexApi.call(
          'query', 'matchmaking:getMyMatch', {'userId': widget.userId});
      if (match is Map) {
        if (match['duration'] != null) duration = match['duration'] as int;
        if (match['opponentName'] != null) {
          opponentName = match['opponentName'] as String;
        }
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _battleId = battleId;
      _opponentName = opponentName;
    });
    _beginCountdown(duration);
  }

  Future<void> _cancelSearch() async {
    _cancelAllTimers();
    try {
      await ConvexApi.call(
          'mutation', 'matchmaking:cancelMatch', {'userId': widget.userId});
    } catch (_) {}
    if (mounted) setState(() => _battlePhase = BattlePhase.lobby);
  }

  // =====================================================================
  // PRIVATE ROOM — create with code + QR, wait unlimited for a friend
  // =====================================================================
  Future<void> _createPrivateRoom() async {
    _cancelAllTimers();
    setState(() {
      _battlePhase = BattlePhase.waiting;
      _searchSeconds = 0;
      _battleMyReps = 0;
      _battleOpponentReps = 0;
      _opponentName = "Opponent";
      _battleCode = null;
      _battleId = null;
    });

    _searchClockTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (mounted) setState(() => _searchSeconds++);
    });

    try {
      final result = await ConvexApi.call('mutation', 'battles:createBattle', {
        'creatorId': widget.userId,
        'duration': _selectedDuration,
      });

      if (result is Map && result['id'] != null) {
        if (!mounted) return;
        setState(() {
          _battleId = result['id'] as String;
          _battleCode = (result['code'] as String?) ?? "";
        });
        _pollBattleForOpponent();
      } else {
        _cancelAllTimers();
        if (mounted) setState(() => _battlePhase = BattlePhase.privateLobby);
        _showSnackBar("Could not create the room — try again");
      }
    } catch (e) {
      _cancelAllTimers();
      if (mounted) setState(() => _battlePhase = BattlePhase.privateLobby);
      _showSnackBar(e.toString().replaceFirst('ConvexApiException: ', ''));
    }
  }

  void _pollBattleForOpponent() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted || _battleId == null) {
        timer.cancel();
        return;
      }
      try {
        final battle = await ConvexApi.call('query', 'battles:getBattleDetailed',
            {'battleId': _battleId});

        if (battle is Map &&
            battle['opponentId'] != null &&
            (battle['opponentId'] as String).isNotEmpty) {
          timer.cancel();
          _searchClockTimer?.cancel();
          final duration = battle['duration'] as int? ?? _selectedDuration;
          final opponentName = battle['opponentName'] as String? ?? "Friend";
          if (mounted) {
            setState(() {
              _opponentName = opponentName;
              _battleCode = battle['battleCode'] as String?;
            });
          }
          _beginCountdown(duration);
        }
      } catch (_) {
        // transient — keep waiting
      }
    });
  }

  Future<void> _joinPrivateRoom() async {
    final code = _joinCodeController.text.trim().toUpperCase();
    if (code.length < 4) {
      _showSnackBar("Enter the room code your friend shared");
      return;
    }

    setState(() => _isStartingBattle = true);
    try {
      final battleId = await ConvexApi.call('mutation', 'battles:joinBattle', {
        'battleCode': code,
        'opponentId': widget.userId,
      });

      if (battleId is String) {
        int duration = _selectedDuration;
        String opponentName = "Friend";
        try {
          final battle = await ConvexApi.call('query', 'battles:getBattleDetailed',
              {'battleId': battleId});
          if (battle is Map) {
            duration = battle['duration'] as int? ?? duration;
            opponentName = battle['creatorName'] as String? ?? opponentName;
          }
        } catch (_) {}

        if (!mounted) return;
        setState(() {
          _battleId = battleId;
          _opponentName = opponentName;
          _joinCodeController.clear();
        });
        _beginCountdown(duration);
      } else {
        if (mounted) setState(() => _isStartingBattle = false);
        _showSnackBar("Room not found — check the code");
      }
    } catch (e) {
      if (mounted) setState(() => _isStartingBattle = false);
      _showSnackBar(e.toString().replaceFirst('ConvexApiException: ', ''));
    }
  }

  // =====================================================================
  // COUNTDOWN (3-2-1) → ACTIVE BATTLE
  // =====================================================================
  void _beginCountdown(int duration) {
    if (!mounted) return;
    setState(() {
      _battlePhase = BattlePhase.countdown;
      _countdown = 3;
      _battleDuration = duration;
      _battleTimeLeft = duration;
      _battleMyReps = 0;
      _battleOpponentReps = 0;
      _situpDetector.reset();
      _cameraStatus = "Starting camera...";
    });

    // Warm the camera up during the countdown so it's live at "GO"
    _startBattleCamera();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdown <= 1) {
        timer.cancel();
        _startBattle();
      } else {
        setState(() => _countdown--);
      }
    });
  }

  void _startBattle() {
    if (!mounted) return;
    setState(() {
      _battlePhase = BattlePhase.active;
      _isStartingBattle = false;
    });

    // 1-second display ticker
    _battleTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_battleTimeLeft <= 1) {
        timer.cancel();
        _endBattle();
      } else {
        setState(() => _battleTimeLeft--);
      }
    });

    // Server sync every 3 seconds: opponent score + true remaining time
    _syncTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      await _syncBattleState();
    });
  }

  Future<void> _syncBattleState() async {
    if (!mounted || _battleId == null || _battlePhase != BattlePhase.active) {
      return;
    }
    try {
      final battle = await ConvexApi.call('query', 'battles:getBattleDetailed',
          {'battleId': _battleId});

      if (battle is Map && mounted) {
        final isCreator = battle['creatorId'] == widget.userId;
        final oppScore = isCreator
            ? (battle['opponentScore'] as int? ?? 0)
            : (battle['creatorScore'] as int? ?? 0);

        // Recompute remaining time from the SERVER clock so both players
        // always see the same countdown, even if they started seconds apart.
        final startedAt = battle['startedAt'] as int?;
        final duration = battle['duration'] as int? ?? _selectedDuration;
        int? serverRemaining;
        if (startedAt != null) {
          final elapsed =
              (DateTime.now().millisecondsSinceEpoch - startedAt) / 1000;
          serverRemaining = (duration - elapsed).ceil();
          if (serverRemaining < 0) serverRemaining = 0;
        }

        setState(() {
          _battleOpponentReps = oppScore;
          if (serverRemaining != null &&
              serverRemaining < _battleTimeLeft &&
              serverRemaining > 0) {
            _battleTimeLeft = serverRemaining;
          }
        });

        if (serverRemaining != null && serverRemaining <= 0) {
          _battleTimer?.cancel();
          _syncTimer?.cancel();
          _endBattle();
          return;
        }
      }

      // Push my score
      await ConvexApi.call('mutation', 'battles:updateScore', {
        'battleId': _battleId,
        'userId': widget.userId,
        'score': _battleMyReps,
      });
    } catch (_) {}
  }

  Future<void> _endBattle() async {
    _cancelAllTimers();
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

    if (_battleId != null) {
      // Flush my final score FIRST — endBattle locks the battle, and the
      // opponent's last sync must not be rejected at the buzzer.
      try {
        await ConvexApi.call('mutation', 'battles:updateScore', {
          'battleId': _battleId,
          'userId': widget.userId,
          'score': myScore,
        });
      } catch (_) {}
      try {
        await ConvexApi.call(
            'mutation', 'battles:endBattle', {'battleId': _battleId});
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() => _battlePhase = BattlePhase.lobby);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: _card,
        title: Text(resultText,
            textAlign: TextAlign.center,
            style: TextStyle(color: _text, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("You: $myScore reps",
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: _accent)),
            Text("$_opponentName: $oppScore reps",
                style: TextStyle(fontSize: 18, color: _subtext)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("OK",
                style: TextStyle(color: _accent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _cancelAllTimers() {
    _battleTimer?.cancel();
    _pollTimer?.cancel();
    _syncTimer?.cancel();
    _countdownTimer?.cancel();
    _searchClockTimer?.cancel();
  }

  Future<void> _leaveBattleSetup() async {
    _cancelAllTimers();
    if (_battlePhase == BattlePhase.searching) {
      try {
        await ConvexApi.call(
            'mutation', 'matchmaking:cancelMatch', {'userId': widget.userId});
      } catch (_) {}
    }
    if (mounted) setState(() => _battlePhase = BattlePhase.lobby);
  }

  // =====================================================================
  // BUILD
  // =====================================================================
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
          _buildHeader(),
          Expanded(child: screens[_currentIndex]),
          _buildBottomNav(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
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
          Expanded(
            child: Column(
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
                GestureDetector(
                  onTap: _showRenameDialog,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.username,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: _subtext),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.edit, size: 13, color: _subtext),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
    );
  }

  Widget _buildBottomNav() {
    return Container(
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
    );
  }

  Widget _buildNavItem(int index, IconData? icon, String label,
      {String? emoji}) {
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

  Widget _buildDurationChip(int seconds, String label, {bool enabled = true}) {
    final isSelected = _selectedDuration == seconds;
    return Expanded(
      child: GestureDetector(
        onTap:
            enabled ? () => setState(() => _selectedDuration = seconds) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: isSelected
                ? _accent
                : (widget.isDark ? const Color(0xFF2D2D44) : Colors.white),
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
                color: isSelected
                    ? Colors.white
                    : (enabled ? _text : _subtext),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDurationRow({bool enabled = true}) {
    return Row(
      children: [
        _buildDurationChip(30, "30s", enabled: enabled),
        const SizedBox(width: 10),
        _buildDurationChip(60, "1 min", enabled: enabled),
        const SizedBox(width: 10),
        _buildDurationChip(300, "5 min", enabled: enabled),
      ],
    );
  }

  // ---------------- BATTLES TAB ----------------
  Widget _buildBattlesScreen() {
    switch (_battlePhase) {
      case BattlePhase.countdown:
        return _buildCountdownView();
      case BattlePhase.active:
        return _buildActiveBattle();
      case BattlePhase.searching:
        return _buildSearchingView();
      case BattlePhase.waiting:
        return _buildWaitingView();
      case BattlePhase.privateLobby:
        return _buildPrivateLobby();
      case BattlePhase.lobby:
        return _buildLobby();
    }
  }

  Widget _buildLobby() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
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
                Text(
                  "Select Duration",
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _text,
                  ),
                ),
                const SizedBox(height: 12),
                _buildDurationRow(),
                const SizedBox(height: 24),
                _buildBattleOption(
                  icon: Icons.language,
                  title: "Random Match",
                  subtitle: "Compete against a random online player",
                  color: _accent,
                  onTap: _startRandomMatch,
                ),
                const SizedBox(height: 14),
                _buildBattleOption(
                  icon: Icons.lock,
                  title: "Private Room",
                  subtitle: "Create a room and invite friends with a code",
                  color: const Color(0xFF4CAF50),
                  onTap: () =>
                      setState(() => _battlePhase = BattlePhase.privateLobby),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivateLobby() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4CAF50).withAlpha(30),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.lock,
                          color: const Color(0xFF4CAF50), size: 22),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Private Room",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: _text,
                          ),
                        ),
                        Text(
                          "Create a room or join with a code.",
                          style: TextStyle(fontSize: 13, color: _subtext),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  "Select Duration",
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _text),
                ),
                const SizedBox(height: 12),
                _buildDurationRow(),
                const SizedBox(height: 20),
                // Create Room button
                GestureDetector(
                  onTap: _createPrivateRoom,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _accent,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: _accent.withAlpha(60),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        "⚔️  Create Room",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Join with code
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: widget.isDark
                        ? const Color(0xFF2D2D44)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Join with Code",
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _text)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _joinCodeController,
                              maxLength: 6,
                              textCapitalization: TextCapitalization.characters,
                              style: TextStyle(
                                color: _text,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 4,
                              ),
                              decoration: InputDecoration(
                                hintText: "CODE",
                                hintStyle: TextStyle(
                                    color: _subtext, letterSpacing: 4),
                                counterText: "",
                                filled: true,
                                fillColor: widget.isDark
                                    ? const Color(0xFF252540)
                                    : const Color(0xFFFDF5F0),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onSubmitted: (_) => _joinPrivateRoom(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          GestureDetector(
                            onTap:
                                _isStartingBattle ? null : _joinPrivateRoom,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 22, vertical: 14),
                              decoration: BoxDecoration(
                                color: _isStartingBattle
                                    ? _subtext.withAlpha(60)
                                    : const Color(0xFF4CAF50),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: _isStartingBattle
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white))
                                  : const Text("Join",
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Center(
                  child: GestureDetector(
                    onTap: () => setState(
                        () => _battlePhase = BattlePhase.lobby),
                    child: Text("← Back",
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: _text)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchingView() {
    final mins = (_searchSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (_searchSeconds % 60).toString().padLeft(2, '0');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(28),
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
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      color: _accent,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    "Finding opponent…",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: _text,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Searching for a ${_durationLabel(_selectedDuration)} match",
                    style: TextStyle(fontSize: 14, color: _subtext),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Searching for $mins:$secs — you'll be matched the moment someone joins",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: _subtext),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    "Playing as ${widget.username}",
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _text),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _cancelSearch,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text("Cancel",
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _text)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWaitingView() {
    final code = _battleCode ?? "······";
    final mins = (_searchSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (_searchSeconds % 60).toString().padLeft(2, '0');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
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
                  Text(
                    "Waiting for opponent… ($mins:$secs)",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: _text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "Share this code — the battle starts the moment your friend joins.",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: _subtext),
                  ),
                  const SizedBox(height: 20),
                  // Room code
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color:
                          widget.isDark ? const Color(0xFF2D2D44) : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        Text("Room Code",
                            style:
                                TextStyle(fontSize: 12, color: _subtext)),
                        const SizedBox(height: 6),
                        Text(
                          code,
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 8,
                            color: _text,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Copy button
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: code));
                      _showSnackBar("Code copied — send it to your friend!");
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _accent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(
                        child: Text("Copy Code",
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // QR code
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: QrImageView(
                      data: 'SITUP-ROOM:$code',
                      size: 160,
                      gapless: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text("Your friend scans this to get the code",
                      style: TextStyle(fontSize: 12, color: _subtext)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _leaveBattleSetup,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text("Cancel Room",
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _text)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCountdownView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            "$_countdown",
            style: TextStyle(
              fontSize: 96,
              fontWeight: FontWeight.w900,
              color: _accent,
            ),
          ),
          const SizedBox(height: 8),
          Text("Get ready!",
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: _text)),
          const SizedBox(height: 6),
          Text(
            "${_durationLabel(_battleDuration)} battle vs $_opponentName",
            style: TextStyle(fontSize: 14, color: _subtext),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveBattle() {
    final minutes = (_battleTimeLeft ~/ 60).toString().padLeft(2, '0');
    final seconds = (_battleTimeLeft % 60).toString().padLeft(2, '0');

    return Column(
      children: [
        // Camera view (top)
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
                      Positioned(
                        top: 12,
                        left: 12,
                        child: _buildBadge(
                          "$minutes:$seconds",
                          _battleTimeLeft <= 10 ? Colors.red : _accent,
                        ),
                      ),
                      Positioned(
                        top: 12,
                        right: 12,
                        child: _buildBadge("⚡ $_battleMyReps", _accent),
                      ),
                      Positioned(
                        bottom: 12,
                        left: 12,
                        right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: widget.isDark
                                ? const Color(0xFF2D2D44).withAlpha(230)
                                : Colors.white.withAlpha(220),
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

        // Scoreboard (bottom)
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
                        Text("reps",
                            style:
                                TextStyle(fontSize: 12, color: _subtext)),
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
                          _opponentName,
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
                        Text("reps",
                            style:
                                TextStyle(fontSize: 12, color: _subtext)),
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

  Widget _buildBattleOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
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
              child: Icon(icon, color: color, size: 22),
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
            Icon(Icons.chevron_right, color: color),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(220),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(15), blurRadius: 8)
        ],
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 14, fontWeight: FontWeight.bold)),
    );
  }

  String _durationLabel(int seconds) {
    if (seconds >= 60) return "${seconds ~/ 60} min";
    return "${seconds}s";
  }

  // ---------------- COUNTER TAB (unchanged) ----------------
  Widget _buildCounterTab() {
    return _CounterTab(
      isDark: widget.isDark,
      accent: _accent,
      card: _card,
      text: _text,
      subtext: _subtext,
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

        _debugInfo =
            "Keypoints:$keypointsFound Side:$side Angle:${angle.toStringAsFixed(0)}";

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
          setState(
              () => _status = "⚠️ Only $keypointsFound keypoints — adjust position");
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
    final controller = _cameraController;
    if (controller == null) return null;

    final rotation = InputImageRotationValue.fromRawValue(
          controller.description.sensorOrientation,
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
              _buildStatCard("$_totalReps", "Total",
                  Icons.local_fire_department, _accentColor),
              const SizedBox(width: 10),
              _buildStatCard(
                  "$_repCount", "AI", Icons.smart_toy, const Color(0xFF4CAF50)),
              const SizedBox(width: 10),
              _buildStatCard(
                  "$_manualReps", "Manual", Icons.touch_app, const Color(0xFF2196F3)),
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
                BoxShadow(
                    color: _accentColor.withAlpha(20),
                    blurRadius: 20,
                    offset: const Offset(0, 8)),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: _isCameraInitialized && _cameraController != null
                ? Stack(
                    children: [
                      CameraPreview(_cameraController!),
                      Positioned(
                        top: 12,
                        left: 12,
                        child: _buildBadge(
                            "${_currentAngle.toStringAsFixed(0)}°",
                            _getAngleColor()),
                      ),
                      Positioned(
                        top: 12,
                        right: 12,
                        child: _buildBadge("⚡ $_totalReps", _accentColor),
                      ),
                      Positioned(
                        bottom: 12,
                        left: 12,
                        right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: widget.isDark
                                ? const Color(0xFF2D2D44).withAlpha(230)
                                : Colors.white.withAlpha(220),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(_status,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: _textColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                      Positioned(
                        bottom: 60,
                        right: 16,
                        child: GestureDetector(
                          onTap: _addManualRep,
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: _accentColor,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                    color: _accentColor.withAlpha(80),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4))
                              ],
                            ),
                            child: const Icon(Icons.add,
                                color: Colors.white, size: 28),
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.videocam_off,
                          size: 48, color: _subtextColor),
                      const SizedBox(height: 12),
                      Text("Camera is off",
                          style: TextStyle(
                              color: _subtextColor, fontSize: 16)),
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
              boxShadow: [
                BoxShadow(
                    color: _accentColor.withAlpha(20),
                    blurRadius: 20,
                    offset: const Offset(0, 8))
              ],
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: _accentColor.withAlpha(30),
                      shape: BoxShape.circle),
                  child:
                      Icon(Icons.emoji_events, size: 40, color: _accentColor),
                ),
                const SizedBox(height: 16),
                Text("$_totalReps reps",
                    style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w900,
                        color: _textColor)),
                const SizedBox(height: 4),
                Text(_status,
                    style:
                        TextStyle(fontSize: 14, color: _subtextColor)),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                      color: widget.isDark
                          ? const Color(0xFF2D2D44)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(20)),
                  child: Text("Goal: 100",
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _subtextColor)),
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
              boxShadow: [
                BoxShadow(
                    color: _accentColor.withAlpha(20),
                    blurRadius: 20,
                    offset: const Offset(0, 8))
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.emoji_events,
                            size: 20, color: _accentColor),
                        const SizedBox(width: 8),
                        Text("Daily Goal",
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: _textColor)),
                      ],
                    ),
                    Text("$_totalReps/100",
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _textColor)),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: (_totalReps / 100).clamp(0.0, 1.0),
                    backgroundColor: widget.isDark
                        ? const Color(0xFF2D2D44)
                        : Colors.white,
                    valueColor: AlwaysStoppedAnimation(_totalReps >= 100
                        ? const Color(0xFF4CAF50)
                        : _accentColor),
                    minHeight: 8,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // +1 button (training counter only — never shown in battles)
          if (_isCameraInitialized)
            SizedBox(
              width: double.infinity,
              height: 60,
              child: ElevatedButton(
                onPressed: _addManualRep,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accentColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18)),
                  elevation: 0,
                ),
                child: const Text("+1 Rep",
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
                        backgroundColor: widget.isDark
                            ? const Color(0xFF2D2D44)
                            : Colors.white,
                        foregroundColor: _textColor,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
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
                    onPressed:
                        _isCameraInitialized ? _endSession : _startSession,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isCameraInitialized
                          ? const Color(0xFFE8534A)
                          : _accentColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: Text(
                        _isCameraInitialized ? "End Session" : "Start AI Counting",
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
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
                        backgroundColor: widget.isDark
                            ? const Color(0xFF2D2D44)
                            : Colors.white,
                        foregroundColor: _textColor,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
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
                      style: TextStyle(
                          fontSize: 11,
                          color: _subtextColor,
                          fontFamily: 'monospace')),
                  Text(
                      "Phase: $_phaseLabel | Confirm: $_confirmProgress/${SitupDetector.confirmFrames}",
                      style: TextStyle(
                          fontSize: 11,
                          color: _subtextColor,
                          fontFamily: 'monospace')),
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
                    Text("Phone Placement",
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: _textColor)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  "1. Place phone on floor or prop it up on its SIDE\n"
                  "2. Back camera should see your full body from the side\n"
                  "3. Make sure your whole body is in the frame\n"
                  "4. Lie down → sit up → lie back = 1 rep\n"
                  "5. If AI doesn't count, use the +1 button",
                  style: TextStyle(
                      fontSize: 12, color: _subtextColor, height: 1.6),
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
    if (_currentAngle < SitupDetector.sittingAngle) {
      return const Color(0xFF4CAF50);
    }
    return const Color(0xFFFFC107);
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(220),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(15), blurRadius: 8)
        ],
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 14, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildStatCard(String value, String label, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _cardColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: color.withAlpha(15),
                blurRadius: 15,
                offset: const Offset(0, 6))
          ],
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 6),
            Text(value,
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: _textColor)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 11, color: _subtextColor)),
          ],
        ),
      ),
    );
  }
}
