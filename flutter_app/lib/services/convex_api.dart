import 'dart:convert';
import 'package:http/http.dart' as http;

/// Thin HTTP client for the Convex backend.
///
/// Convex's HTTP actions return `{status:"success", value:...}` or
/// `{status:"error", errorMessage:...}`. This client unwraps `value` and
/// converts backend errors into thrown [ConvexApiException]s so the UI
/// always shows the real reason instead of a generic failure.
class ConvexApi {
  static const String baseUrl = 'https://graceful-mink-900.convex.site';

  /// Runs a public Convex query or mutation and returns the unwrapped result.
  static Future<dynamic> call(
    String type,
    String path,
    Map<String, dynamic> args,
  ) async {
    final url = Uri.parse('$baseUrl/api/$type');
    try {
      final response = await http
          .post(
            url,
            headers: const {'Content-Type': 'application/json'},
            body: json.encode({'path': path, 'args': args}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw ConvexApiException('Server error (${response.statusCode})');
      }

      final data = json.decode(response.body);
      return _unwrapResponse(data);
    } on ConvexApiException {
      rethrow;
    } catch (e) {
      throw ConvexApiException('Network error — check your connection');
    }
  }

  /// Unwraps a Convex HTTP response body the same way the web client does.
  static dynamic _unwrapResponse(Map<String, dynamic> data) {
    // Standard Convex API response shape.
    final status = data['status'];
    if (status == 'error') {
      throw ConvexApiException(_friendly(data['errorMessage']));
    }
    if (data['result'] != null) return data['result'];
    if (data['value'] != null) return data['value'];
    if (data['errorMessage'] != null && data['errorMessage'].toString().isNotEmpty) {
      throw ConvexApiException(_friendly(data['errorMessage']));
    }
    return null;
  }

  static String _friendly(String? msg) {
    if (msg == null) return 'Something went wrong';
    if (msg.contains('Username is already taken')) {
      return 'That username is taken — pick another';
    }
    if (msg.contains('can only be changed once')) {
      return 'Guest names can only be changed once. Sign in to rename freely.';
    }
    if (msg.contains('Battle not found')) return 'Room not found — check the code';
    if (msg.contains('already started')) return 'That room already started';
    if (msg.contains('own battle')) return "You can't join your own room";
    // Try to extract the backend's human message from serialized error shapes.
    final match = RegExp(r'"message":"([^"]+)"').firstMatch(msg);
    final friendly = match?.group(1);
    if (friendly != null && friendly.isNotEmpty) return friendly;
    if (msg.length > 120) return msg.substring(0, 120);
    return msg;
  }

  // ---------------- AUTH: email OTP sign-in ----------------

  /// Step 1 — send the 6-digit code to the email.
  /// A successful send does NOT return tokens — only a wrong request errors.
  static Future<void> sendEmailOtp(String email) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/api/sign_in'),
          headers: const {'Content-Type': 'application/json'},
          body: json.encode({
            'action': 'signIn',
            'args': {
              'provider': 'email-otp',
              'params': {'email': email},
            },
          }),
        )
        .timeout(const Duration(seconds: 15));

    final data = json.decode(response.body);
    if (data['status'] == 'error' || (data['errorMessage'] != null && data['errorMessage'].toString().isNotEmpty)) {
      throw ConvexApiException(_friendly(data['errorMessage']?.toString()));
    }
  }

  /// Step 2 — verify the 6-digit code. Returns the auth token + userId.
  static Future<Map<String, dynamic>> verifyEmailOtp(
      String email, String code) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/api/sign_in'),
          headers: const {'Content-Type': 'application/json'},
          body: json.encode({
            'action': 'signIn',
            'args': {
              'provider': 'email-otp',
              'params': {
                'email': email,
                'code': code,
                'flow': 'signIn',
              },
            },
          }),
        )
        .timeout(const Duration(seconds: 15));

    final data = json.decode(response.body);
    final tokens = data['tokens'];
    if (tokens == null || tokens['token'] == null) {
      throw ConvexApiException(
          'Wrong or expired code — check your email and try again');
    }
    // userId is embedded in the JWT's standard `sub` claim as "userId|sessionId"
    // (see @convex-dev/auth TOKEN_SUB_CLAIM_DIVIDER).
    String? userId;
    try {
      final token = tokens['token'] as String;
      final payload = token.split('.')[1];
      final normalized = base64Url.normalize(payload.replaceAll('-', '+'));
      final decoded = utf8.decode(base64Url.decode(normalized));
      final Map<String, dynamic> claims = json.decode(decoded);
      final sub = claims['sub'] as String?;
      if (sub != null && sub.isNotEmpty) {
        userId = sub.split('|').first;
      }
    } catch (_) {}
    if (userId == null) {
      throw ConvexApiException('Signed in but could not load your account');
    }
    return {'token': tokens['token'], 'userId': userId};
  }

class ConvexApiException implements Exception {
  final String message;
  ConvexApiException(this.message);

  @override
  String toString() => message;
}
