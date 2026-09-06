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
      final status = data['status'];
      if (status != null && status == 'error') {
        throw ConvexApiException(_friendly(data['errorMessage']));
      }
      return data['result'] ?? data['value'];
    } on ConvexApiException {
      rethrow;
    } catch (e) {
      throw ConvexApiException('Network error — check your connection');
    }
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
    // Backend errors embed the message inside a serialized error object.
    final match = RegExp(r'"message":"([^"]+)"').firstMatch(msg);
    if (match != null) return match.group(1)!;
    if (msg.length > 90) return msg.substring(0, 90);
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
    if (data['tokens'] == null && data['errorMessage'] != null) {
      throw ConvexApiException(_friendly(data['errorMessage'].toString()));
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
    if (tokens == null) {
      throw ConvexApiException(
          'Wrong or expired code — check your email and try again');
    }
    // userId is embedded in the JWT — decode the payload segment.
    String? userId;
    try {
      final token = tokens['token'] as String;
      final payload = token.split('.')[1];
      final normalized = base64Url.normalize(payload.replaceAll('-', '+'));
      final decoded = utf8.decode(base64Url.decode(normalized));
      final Map<String, dynamic> claims = json.decode(decoded);
      userId = claims['identity'] as String?;
    } catch (_) {}
    if (userId == null) {
      throw ConvexApiException('Signed in but could not load your account');
    }
    return {'token': tokens['token'], 'userId': userId};
  }

  /// Look up an account profile by username (identity resolution for battles).
  static Future<Map<String, dynamic>?> getProfile(String username) async {
    final value = await call(
        'query', 'username:getProfileByUsername', {'username': username});
    if (value == null) return null;
    return Map<String, dynamic>.from(value as Map);
  }
}

class ConvexApiException implements Exception {
  final String message;
  ConvexApiException(this.message);

  @override
  String toString() => message;
}

/// Builds the QR image widget data for a private room code.
/// Kept here so screens stay focused on UI.
String roomQrPayload(String code) => 'SITUP-ROOM:$code';
