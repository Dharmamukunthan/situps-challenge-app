import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class LeaderboardScreen extends StatefulWidget {
  final bool isDark;
  const LeaderboardScreen({super.key, this.isDark = false});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  bool _isToday = true;
  List<Map<String, dynamic>> _rankings = [];
  bool _isLoading = true;

  // Light colors
  static const Color _lightBg = Color(0xFFFDF5F0);
  static const Color _lightCard = Color(0xFFFFF0E8);
  static const Color _lightText = Color(0xFF3D2C2C);
  static const Color _lightSubtext = Color(0xFF9C8A8A);
  static const Color _accentColor = Color(0xFFE8734A);

  // Dark colors
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
    _loadRankings();
  }

  Future<void> _loadRankings() async {
    setState(() => _isLoading = true);
    try {
      // Use the correct Convex query path and args
      final queryPath = _isToday ? 'situpLogs:getLeaderboard' : 'situpLogs:getOverallLeaderboard';

      final response = await http.post(
        Uri.parse('https://graceful-mink-900.convex.site/api/query'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'path': queryPath,
          'args': {},
        }),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        // data['result'] is the actual leaderboard array
        final result = data['result'] ?? data['value'];
        setState(() {
          if (result is List) {
            _rankings = List<Map<String, dynamic>>.from(
              result.map((item) => Map<String, dynamic>.from(item)),
            );
          } else {
            _rankings = [];
          }
          _isLoading = false;
        });
      } else {
        setState(() { _isLoading = false; });
      }
    } catch (e) {
      setState(() { _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Toggle
          Container(
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: _accentColor.withAlpha(15), blurRadius: 15, offset: const Offset(0, 6)),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() { _isToday = true; _loadRankings(); }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: _isToday ? _accentColor : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Center(
                        child: Text("Today",
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _isToday ? Colors.white : _subtextColor)),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() { _isToday = false; _loadRankings(); }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: !_isToday ? _accentColor : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Center(
                        child: Text("All Time",
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: !_isToday ? Colors.white : _subtextColor)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          Text(_isToday ? "Today's Rankings" : "All Time Rankings",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _textColor)),

          const SizedBox(height: 16),

          if (_isLoading)
            Center(child: CircularProgressIndicator(color: _accentColor))
          else if (_rankings.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: _cardColor,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [BoxShadow(color: _accentColor.withAlpha(15), blurRadius: 20, offset: const Offset(0, 8))],
              ),
              child: Column(
                children: [
                  Icon(Icons.emoji_events, size: 48, color: _subtextColor),
                  const SizedBox(height: 16),
                  Text("No sessions logged yet.", style: TextStyle(fontSize: 16, color: _textColor, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text("Be the first!", style: TextStyle(fontSize: 14, color: _subtextColor)),
                ],
              ),
            )
          else
            ...List.generate(_rankings.length, (index) {
              final rank = _rankings[index];
              final medals = ['🥇', '🥈', '🥉'];
              // API returns 'userName' or 'total' for overall, 'username' or 'count' for today
              final displayName = rank['userName'] ?? rank['username'] ?? 'Unknown';
              final displayCount = rank['total'] ?? rank['count'] ?? 0;

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [BoxShadow(color: _accentColor.withAlpha(15), blurRadius: 15, offset: const Offset(0, 6))],
                ),
                child: Row(
                  children: [
                    Text(index < 3 ? medals[index] : "${index + 1}",
                        style: TextStyle(fontSize: index < 3 ? 24 : 16, fontWeight: FontWeight.bold, color: _textColor)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(displayName,
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _textColor)),
                          Text("$displayCount reps",
                              style: TextStyle(fontSize: 13, color: _subtextColor)),
                        ],
                      ),
                    ),
                    Icon(Icons.emoji_events, color: _accentColor, size: 20),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
