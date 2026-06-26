/// DeliveryEndlessRunnerGame
///
/// A minimalist, monochrome, Chrome-Dino-inspired endless runner where a
/// delivery rider scoots over looping hills for a 30-minute "mission".
///
/// Drop this widget into any route in your existing Flutter app, e.g.:
///
///   Navigator.push(context, MaterialPageRoute(
///     builder: (_) => DeliveryEndlessRunnerGame(authToken: token),
///   ));
///
/// No external game engine required — rendering is plain Flutter
/// CustomPainter + a Ticker, which keeps the widget small, dependency-free,
/// and easy for any Flutter dev on your team to maintain.

import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'game_models.dart';
import 'terrain_engine.dart';
import '../services/game_session_api.dart';

class _Cloud {
  double x;
  double y;
  double speedFactor;
  int type;
  _Cloud(this.x, this.y, this.speedFactor, this.type);
}

class DeliveryEndlessRunnerGame extends StatefulWidget {
  final String authToken; // Bearer token from your OTP+Token auth
  final Duration missionDuration;

  const DeliveryEndlessRunnerGame({
    super.key,
    required this.authToken,
    this.missionDuration = const Duration(minutes: 30),
  });

  @override
  State<DeliveryEndlessRunnerGame> createState() =>
      _DeliveryEndlessRunnerGameState();
}

class _DeliveryEndlessRunnerGameState extends State<DeliveryEndlessRunnerGame>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  final TerrainEngine _terrain = TerrainEngine();
  late List<TerrainSegment> _segments;
  late List<_Cloud> _clouds;
  ui.Image? _scooterImage;
  ui.Image? _cloudImage;

  final GameSessionApi _api = GameSessionApi();
  String? _sessionId;
  DateTime? _serverMissionStart;
  DateTime? _serverMissionEnd;

  // Tunables
  static const double baseSpeed = 180; // px/sec at 1.0x
  static const double maxSpeedMultiplier = 2.3;
  static const double playerScreenX = 90; // fixed screen position of rider

  double _distance = 0; // total world-x traveled
  double _currentSpeed = 0; // current px/s (eased toward target)
  bool _isHolding = false;
  double _score = 0;
  int _coins = 0;
  int _bestScore = 0;
  GamePhase _phase = GamePhase.intro;

  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    _segments = _terrain.buildInitialQueue();
    _initClouds();
    _loadAssets();
    _ticker = createTicker(_onTick)..start();
    _startSession();
  }

  Future<void> _loadAssets() async {
    try {
      final scooterData = await rootBundle.load('assets/scooter.png');
      final scooterCodec = await ui.instantiateImageCodec(scooterData.buffer.asUint8List());
      final scooterFrame = await scooterCodec.getNextFrame();

      final cloudData = await rootBundle.load('assets/cloud.png');
      final cloudCodec = await ui.instantiateImageCodec(cloudData.buffer.asUint8List());
      final cloudFrame = await cloudCodec.getNextFrame();

      setState(() {
        _scooterImage = scooterFrame.image;
        _cloudImage = cloudFrame.image;
      });
    } catch (_) {}
  }

  void _initClouds() {
    final rng = Random();
    _clouds = List.generate(8, (i) => _Cloud(
      rng.nextDouble() * 3000, 
      rng.nextDouble() * 120 + 20, 
      0.1 + rng.nextDouble() * 0.2, // scroll speed factor relative to player
      rng.nextInt(3),
    ));
  }

  void _togglePause() {
    setState(() {
      if (_phase == GamePhase.playing) {
        _phase = GamePhase.paused;
      } else if (_phase == GamePhase.paused) {
        _phase = GamePhase.playing;
      }
    });
  }

  Future<void> _startSession() async {
    try {
      final res = await _api.startSession(widget.authToken, widget.missionDuration);
      _sessionId = res.sessionId;
      _serverMissionStart = res.startsAt;
      _serverMissionEnd = res.endsAt;
      _bestScore = res.bestScore;
    } catch (_) {
      // Fallback: run mission on local clock if the API is unreachable so
      // the game is still playable offline; server will reject reward
      // crediting on sync if it doesn't recognize the session.
      _serverMissionStart = DateTime.now();
      _serverMissionEnd = DateTime.now().add(widget.missionDuration);
    }
    setState(() => _phase = GamePhase.playing);

    // Periodic server sync for live score/coin validation (anti-cheat) and
    // session resilience if the app is killed mid-mission.
    _syncTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_sessionId != null && _phase == GamePhase.playing) {
        _api.syncSession(
          widget.authToken,
          _sessionId!,
          score: _score.floor(),
          coins: _coins,
          distance: _distance,
        );
      }
    });
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0 || dt > 0.25) return; // ignore first frame / big jumps

    if (_phase != GamePhase.playing || _serverMissionStart == null) {
      // still update lastTick to prevent large dt when resuming
      return;
    }

    // --- Real-time mission timer (server-anchored, not frame-counted) ---
    final remaining = _serverMissionEnd!.difference(DateTime.now());
    if (remaining.isNegative || remaining == Duration.zero) {
      _completeMission();
      return;
    }

    // --- Difficulty progression: ease-in speed curve over total mission ---
    final missionElapsed =
        DateTime.now().difference(_serverMissionStart!).inMilliseconds / 1000;
    final totalSeconds = widget.missionDuration.inSeconds.toDouble();
    final t = (missionElapsed / totalSeconds).clamp(0.0, 1.0);
    final speedMultiplier = 1.0 + (maxSpeedMultiplier - 1.0) * (t * t); // ease-in

    // --- Acceleration / deceleration toward target speed ---
    final targetSpeed = _isHolding ? baseSpeed * speedMultiplier : 0.0;
    final accel = _isHolding ? 420.0 : 600.0; // px/s^2
    if (_currentSpeed < targetSpeed) {
      _currentSpeed = min(targetSpeed, _currentSpeed + accel * dt);
    } else {
      _currentSpeed = max(targetSpeed, _currentSpeed - accel * dt);
    }

    _distance += _currentSpeed * dt;
    _score += _currentSpeed * dt * 0.05; // distance-based scoring

    _checkCoinCollisions();
    _recycleSegmentsIfNeeded();

    setState(() {});
  }

  void _checkCoinCollisions() {
    final playerWorldX = _distance + playerScreenX;
    for (final seg in _segments) {
      for (final coin in seg.coins) {
        if (coin.collected) continue;
        final coinWorldX = seg.worldStartX + coin.localX;
        if ((coinWorldX - playerWorldX).abs() < 22) {
          coin.collected = true;
          _coins++;
          _score += 25;
        }
      }
    }
  }

  void _recycleSegmentsIfNeeded() {
    // When the front segment has fully scrolled behind the player, recycle
    // it to the back of the queue with a freshly randomized coin layout.
    final front = _segments.first;
    if (_distance > front.worldStartX + front.width) {
      _segments.removeAt(0);
      final last = _segments.last;
      final newStartX = last.worldStartX + last.width;
      _segments.add(_terrain.recycle(front, newStartX));
    }
  }

  Future<void> _completeMission() async {
    setState(() => _phase = GamePhase.completed);
    _syncTimer?.cancel();
    if (_sessionId != null) {
      try {
        final res = await _api.completeSession(
          widget.authToken,
          _sessionId!,
          score: _score.floor(),
          coins: _coins,
          distance: _distance,
        );
        _bestScore = res.bestScore;
      } catch (_) {
        // Network failure on completion: keep local result, retry silently
        // could be queued here if you want offline-first behaviour.
      }
    }
    setState(() {});
  }

  void _restart() {
    setState(() {
      _segments = _terrain.buildInitialQueue();
      _distance = 0;
      _currentSpeed = 0;
      _score = 0;
      _coins = 0;
      _phase = GamePhase.intro;
    });
    _startSession();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _syncTimer?.cancel();
    super.dispose();
  }

  Duration get _timeRemaining {
    if (_serverMissionEnd == null) return widget.missionDuration;
    final r = _serverMissionEnd!.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }

  String _fmtTime(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: GestureDetector(
        onTapDown: (_) => _isHolding = true,
        onTapUp: (_) => _isHolding = false,
        onTapCancel: () => _isHolding = false,
        child: Stack(
          children: [
            CustomPaint(
              size: Size.infinite,
              painter: _RunnerPainter(
                segments: _segments,
                clouds: _clouds,
                scooterImage: _scooterImage,
                cloudImage: _cloudImage,
                distance: _distance,
                playerScreenX: playerScreenX,
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              right: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _hudText('SCORE: ${_score.floor().toString().padLeft(5, '0')}'),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _hudText('BEST: ${_bestScore.toString().padLeft(5, '0')}'),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: _togglePause,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 2),
                            borderRadius: BorderRadius.circular(4)
                          ),
                          child: _hudText(_phase == GamePhase.paused ? '►' : 'II'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_phase == GamePhase.completed) _completionOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _hudText(String text) => Text(
        text,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 18,
          letterSpacing: 1.5,
          fontWeight: FontWeight.bold,
          color: Colors.black,
        ),
      );

  Widget _completionOverlay() {
    return Container(
      color: Colors.white.withOpacity(0.95),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('DELIVERY COMPLETE!',
                style: TextStyle(fontFamily: 'monospace', fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('SCORE: ${_score.floor().toString().padLeft(5, '0')}   COINS: $_coins',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(onPressed: _restart, child: const Text('PLAY AGAIN')),
                const SizedBox(width: 16),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('HOME'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Monochrome painter: ground curve, dotted shading under the road, coins,
/// and a simple scooter-rider silhouette tilted to the local slope.
class _RunnerPainter extends CustomPainter {
  final List<TerrainSegment> segments;
  final List<_Cloud> clouds;
  final ui.Image? scooterImage;
  final ui.Image? cloudImage;
  final double distance;
  final double playerScreenX;

  _RunnerPainter({
    required this.segments,
    required this.clouds,
    this.scooterImage,
    this.cloudImage,
    required this.distance,
    required this.playerScreenX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final groundY = size.height * 0.65;
    final linePaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()..color = Colors.black.withOpacity(0.7);
    final coinPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // --- Clouds ---
    final cloudPaint = Paint()..color = Colors.black.withOpacity(0.08); // faint fill
    final cloudStroke = Paint()..color = Colors.black.withOpacity(0.6)..style = PaintingStyle.stroke..strokeWidth = 2;
    for (final c in clouds) {
      final cx = (c.x - distance * c.speedFactor) % (size.width + 300) - 150;
      _drawCloud(canvas, cx, c.y, c.type, cloudPaint, cloudStroke);
    }

    // --- Ground texture (dots and dashes) ---
    final dashPaint = Paint()..color = Colors.black..style = PaintingStyle.fill;
    final double startWorldX = (distance / 16).floor() * 16.0;
    final double endWorldX = ((distance + size.width) / 16).ceil() * 16.0;
    
    for (double wx = startWorldX; wx <= endWorldX; wx += 16) {
      final double sx = wx - distance;
      final double h = _heightAt(wx) ?? 0;
      final double y = groundY + h;
      
      final rng = Random(wx.toInt());
      final int count = rng.nextInt(5) + 3; // 3 to 7 particles per column
      for (int i = 0; i < count; i++) {
        double depth = 10.0 + rng.nextDouble() * 140.0; // up to 140px deep
        // Density falls off with depth
        if (rng.nextDouble() < (depth / 180.0)) continue; 
        
        // 40% chance for a dot(2px), 60% chance for a dash (4-12px)
        double width = rng.nextDouble() > 0.6 ? 2.0 : (4.0 + rng.nextDouble() * 8.0);
        // Slightly jitter the x position so it's less grid-like
        double offsetX = rng.nextDouble() * 8.0 - 4.0;
        
        canvas.drawRect(Rect.fromLTWH(sx + offsetX, y + depth, width, 2), dashPaint);
      }
    }

    // --- Ground line ---
    final path = Path();
    bool started = false;
    for (double sx = 0; sx <= size.width; sx += 4) {
      final worldX = distance + sx;
      final h = _heightAt(worldX) ?? 0;
      final y = groundY + h;
      if (!started) {
        path.moveTo(sx, y);
        started = true;
      } else {
        path.lineTo(sx, y);
      }
    }
    canvas.drawPath(path, linePaint);

    // --- Coins ---
    for (final seg in segments) {
      for (final coin in seg.coins) {
        if (coin.collected) continue;
        final worldX = seg.worldStartX + coin.localX;
        final sx = worldX - distance;
        if (sx < -20 || sx > size.width + 20) continue;
        final cy = groundY + coin.y;
        canvas.drawCircle(Offset(sx, cy), 9, coinPaint);
        canvas.drawLine(Offset(sx, cy - 4), Offset(sx, cy + 4), coinPaint); // vertical line
      }
    }

    // --- Player ---
    final playerWorldX = distance + playerScreenX;
    final h = _heightAt(playerWorldX) ?? 0;
    final slope = _slopeAt(playerWorldX);
    final playerY = groundY + h;

    canvas.save();
    canvas.translate(playerScreenX, playerY);
    canvas.rotate(slope);
    _drawScooter(canvas);
    canvas.restore();
  }

  double? _heightAt(double worldX) {
    for (final seg in segments) {
      final h = seg.heightAtWorldX(worldX);
      if (h != null) return h;
    }
    return null;
  }

  double _slopeAt(double worldX) {
    for (final seg in segments) {
      final h = seg.heightAtWorldX(worldX);
      if (h != null) return seg.slopeAtWorldX(worldX);
    }
    return 0;
  }

  void _drawScooter(Canvas canvas) {
    if (scooterImage != null) {
      // The image is likely high-res; scale it down.
      // Offset so the wheels touch the ground (y=0 approx).
      final rect = Rect.fromCenter(center: const Offset(0, -28), width: 72, height: 72);
      paintImage(
        canvas: canvas,
        rect: rect,
        image: scooterImage!,
        fit: BoxFit.contain,
      );
      return;
    }

    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    
    final fillPaint = Paint()..color = Colors.black;

    // Wheels (hollow with a dot in center)
    canvas.drawCircle(const Offset(-16, 0), 6, paint);
    canvas.drawCircle(const Offset(-16, 0), 1, fillPaint);
    canvas.drawCircle(const Offset(16, 0), 6, paint);
    canvas.drawCircle(const Offset(16, 0), 1, fillPaint);
    
    // Scooter body
    final deck = Path()
      ..moveTo(-16, -6)
      ..lineTo(10, -6) // footrest
      ..lineTo(16, -20) // steering column
      ..lineTo(12, -22) // handle bars
      ..moveTo(16, -20)
      ..lineTo(22, -22); 
    canvas.drawPath(deck, paint);
    
    // Fenders
    canvas.drawArc(Rect.fromCircle(center: const Offset(16,0), radius: 8), pi, pi, false, paint);
    canvas.drawArc(Rect.fromCircle(center: const Offset(-16,0), radius: 8), pi, pi, false, paint);

    // Delivery box
    canvas.drawRect(const Rect.fromLTWH(-20, -28, 16, 16), paint);
    // Box logo 'w'
    final logo = Path()
      ..moveTo(-16, -22)
      ..lineTo(-14, -16)
      ..lineTo(-12, -20)
      ..lineTo(-10, -16)
      ..lineTo(-8, -22);
    canvas.drawPath(logo, paint..strokeWidth = 1);
    paint.strokeWidth = 2; // reset

    // Rider silhouette
    final rider = Path()
      ..moveTo(-4, -28) // sitting
      ..lineTo(-4, -40) // back
      ..lineTo(6, -42)  // neck/shoulder
      ..lineTo(12, -22) // arm reaching to handle
      ..moveTo(6, -42)
      ..lineTo(14, -46) // head/helmet
      ..moveTo(-4, -28)
      ..lineTo(6, -26) // thigh
      ..lineTo(10, -6); // leg
    canvas.drawPath(rider, paint);

    // Helmet detail
    canvas.drawArc(Rect.fromCircle(center: const Offset(10, -46), radius: 5), pi, pi, false, fillPaint);
  }

  void _drawCloud(Canvas canvas, double cx, double cy, int type, Paint fillPaint, Paint strokePaint) {
    if (cloudImage != null) {
      final double sizeScale = type == 1 ? 1.3 : (type == 2 ? 0.8 : 1.0);
      final double w = 80 * sizeScale;
      final double h = 40 * sizeScale;
      final rect = Rect.fromCenter(center: Offset(cx + 20, cy), width: w, height: h);
      paintImage(
        canvas: canvas,
        rect: rect,
        image: cloudImage!,
        fit: BoxFit.contain,
      );
      return;
    }

    canvas.save();
    canvas.translate(cx, cy);
    if (type == 0) {
      canvas.drawRect(const Rect.fromLTWH(0, 0, 40, 10), fillPaint);
      canvas.drawRect(const Rect.fromLTWH(10, -10, 20, 10), fillPaint);
      canvas.drawRect(const Rect.fromLTWH(5, -5, 10, 10), fillPaint);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 40, 10), strokePaint);
      canvas.drawRect(const Rect.fromLTWH(10, -10, 20, 10), strokePaint);
    } else if (type == 1) {
      canvas.drawRect(const Rect.fromLTWH(0, 0, 50, 10), fillPaint);
      canvas.drawRect(const Rect.fromLTWH(15, -15, 20, 15), fillPaint);
      canvas.drawRect(const Rect.fromLTWH(30, -5, 15, 10), fillPaint);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 50, 10), strokePaint);
      canvas.drawRect(const Rect.fromLTWH(15, -15, 20, 15), strokePaint);
    } else {
      canvas.drawRect(const Rect.fromLTWH(0, 0, 30, 8), fillPaint);
      canvas.drawRect(const Rect.fromLTWH(5, -8, 15, 8), fillPaint);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 30, 8), strokePaint);
      canvas.drawRect(const Rect.fromLTWH(5, -8, 15, 8), strokePaint);
    }
    
    // scatter a few dots around the cloud base
    final dotPaint = Paint()..color = Colors.black.withOpacity(0.5);
    canvas.drawRect(const Rect.fromLTWH(5, 12, 2, 2), dotPaint);
    canvas.drawRect(const Rect.fromLTWH(15, 14, 2, 2), dotPaint);
    canvas.drawRect(const Rect.fromLTWH(25, 12, 2, 2), dotPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RunnerPainter oldDelegate) => true;
}
