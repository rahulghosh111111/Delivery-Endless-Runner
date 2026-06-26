/// Thin REST client for the delivery-game backend endpoints.
/// Uses your existing OTP+Token auth (Bearer header) and REST API
/// conventions. Swap the baseUrl for your Hostinger-hosted Laravel API.
///
/// Add to pubspec.yaml:
///   dependencies:
///     http: ^1.2.0

import 'dart:convert';
import 'package:http/http.dart' as http;

class StartSessionResult {
  final String sessionId;
  final DateTime startsAt;
  final DateTime endsAt;
  final int bestScore;
  final int lifetimeCoins;
  final int pendingRewards;

  StartSessionResult({
    required this.sessionId,
    required this.startsAt,
    required this.endsAt,
    required this.bestScore,
    required this.lifetimeCoins,
    required this.pendingRewards,
  });

  factory StartSessionResult.fromJson(Map<String, dynamic> j) {
    return StartSessionResult(
      sessionId: j['session_id'].toString(),
      startsAt: DateTime.parse(j['starts_at']),
      endsAt: DateTime.parse(j['ends_at']),
      bestScore: j['best_score'] ?? 0,
      lifetimeCoins: j['lifetime_coins'] ?? 0,
      pendingRewards: j['pending_rewards'] ?? 0,
    );
  }
}

class CompleteSessionResult {
  final int bestScore;
  final int rewardCoins;
  final int lifetimeCoins;

  CompleteSessionResult({
    required this.bestScore, 
    required this.rewardCoins,
    required this.lifetimeCoins,
  });

  factory CompleteSessionResult.fromJson(Map<String, dynamic> j) {
    return CompleteSessionResult(
      bestScore: j['best_score'] ?? 0,
      rewardCoins: j['reward_coins'] ?? 0,
      lifetimeCoins: j['lifetime_coins'] ?? 0,
    );
  }
}

class GameSessionApi {
  // TODO: point this at your real API base, e.g. via an env/config file.
  static const String baseUrl = 'http://localhost:8000/api';

  Map<String, String> _headers(String token) => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      };

  Future<StartSessionResult> startSession(String token, Duration duration) async {
    final res = await http.post(
      Uri.parse('$baseUrl/game/sessions'),
      headers: _headers(token),
      body: jsonEncode({'duration_seconds': duration.inSeconds}),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('Failed to start session: ${res.statusCode}');
    }
    return StartSessionResult.fromJson(jsonDecode(res.body)['data']);
  }

  Future<void> syncSession(
    String token,
    String sessionId, {
    required int score,
    required int coins,
    required double distance,
  }) async {
    try {
      await http.patch(
        Uri.parse('$baseUrl/game/sessions/$sessionId/sync'),
        headers: _headers(token),
        body: jsonEncode({
          'score': score,
          'coins': coins,
          'distance': distance,
        }),
      );
    } catch (_) {
      // Sync calls are best-effort; failures are non-fatal mid-game.
    }
  }

  Future<CompleteSessionResult> completeSession(
    String token,
    String sessionId, {
    required int score,
    required int coins,
    required double distance,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/game/sessions/$sessionId/complete'),
      headers: _headers(token),
      body: jsonEncode({
        'score': score,
        'coins': coins,
        'distance': distance,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to complete session: ${res.statusCode}');
    }
    return CompleteSessionResult.fromJson(jsonDecode(res.body)['data']);
  }

  Future<void> redeemRewards(String token) async {
    final res = await http.post(
      Uri.parse('$baseUrl/game/redeem'),
      headers: _headers(token),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to redeem rewards: ${res.statusCode}');
    }
  }
}
