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
import '../services/game_session_api.dart';

const int kCoinsPerReward = 100000;
const int kRewardAmountInRupees = 50;

class ResponsiveHud {
  static const double tabletBreakpoint = 768;
  static double getScaleFactor(double width) {
    if (width < 360) return 0.8;
    if (width < 480) return 0.9;
    if (width < tabletBreakpoint) return 1.0;
    return 1.2;
  }
}


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
  int _bestScore = 0;
  int _coins = 0;
  int _lifetimeCoins = 0;
  int _redeemedRewardCoins = 0;
  GamePhase _phase = GamePhase.intro;

  Timer? _syncTimer;
  DateTime? _lastSyncTime;
  bool _isRedeeming = false;

  int get _unclaimedCoins => _lifetimeCoins - _redeemedRewardCoins;
  int get _pendingRewards => (_unclaimedCoins ~/ kCoinsPerReward) * kRewardAmountInRupees;

  double get _playerScreenX {
    final w = MediaQuery.maybeOf(context)?.size.width ?? 400;
    final h = MediaQuery.maybeOf(context)?.size.height ?? 800;
    final scale = min(w / 400, h / 800);
    final logicalWidth = w / scale;
    return logicalWidth * 0.25;
  }

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
      _lifetimeCoins = res.lifetimeCoins;
      _redeemedRewardCoins = res.redeemedRewardCoins ?? 0;
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
    _syncTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_sessionId != null && _phase == GamePhase.playing) {
        try {
          await _api.syncSession(
            widget.authToken,
            _sessionId!,
            score: _score.floor(),
            coins: _coins,
            distance: _distance,
          );
          if (mounted) {
            setState(() {
              _lastSyncTime = DateTime.now();
            });
          }
        } catch (_) {}
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
    final pX = _playerScreenX;
    for (final seg in _segments) {
      for (final spot in seg.coins) {
        if (spot.collected) continue;
        if (spot.localX + seg.worldStartX > _distance + pX - 30 &&
            spot.localX + seg.worldStartX < _distance + pX + 30) {
          spot.collected = true;
          _coins += spot.value;
          _lifetimeCoins += spot.value;
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
        if (res != null) {
          if (mounted) {
            setState(() {
              _bestScore = res.bestScore;
              _lifetimeCoins = res.lifetimeCoins;
              _redeemedRewardCoins = res.redeemedRewardCoins ?? 0;
            });
          }
        }
      } catch (_) {
        // Network failure on completion: keep local result, retry silently
        // could be queued here if you want offline-first behaviour.
      }
    }
  }

  Future<void> _redeemRewards() async {
    final amount = _pendingRewards;
    if (_isRedeeming || amount < kRewardAmountInRupees) return;

    setState(() => _isRedeeming = true);

    try {
      await _api.redeemRewards(widget.authToken);
      if (mounted) {
        setState(() {
          _redeemedRewardCoins += kCoinsPerReward * (amount ~/ kRewardAmountInRupees);
        });

        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 64),
                    const SizedBox(height: 16),
                    Text('₹$amount Redeemed!', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                    const SizedBox(height: 8),
                    const Text('Successfully sent to your wallet.', style: TextStyle(fontFamily: 'monospace')),
                  ],
                ),
              ),
            );
          }
        );

        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to redeem rewards. Please try again.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isRedeeming = false);
      }
    }
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
                playerScreenX: _playerScreenX,
              ),
            ),
            SafeArea(
              child: GameHud(
                score: _score.floor(),
                timeRemaining: _timeRemaining,
                bestScore: _bestScore,
                lifetimeCoins: _lifetimeCoins,
                pendingRewards: _pendingRewards,
                isPaused: _phase == GamePhase.paused,
                lastSyncTime: _lastSyncTime,
                onPauseTap: _togglePause,
                onInfoTap: _showInfoModal,
              ),
            ),
            if (_phase == GamePhase.completed) _completionOverlay(),
          ],
        ),
      ),
    );
  }

  void _showInfoModal() {
    final wasPlaying = _phase == GamePhase.playing;
    if (wasPlaying) _togglePause();

    final isWide = MediaQuery.of(context).size.width > ResponsiveHud.tabletBreakpoint;

    final modalWidget = _InfoModal(
      lifetimeCoins: _lifetimeCoins,
      pendingRewards: _pendingRewards,
      isRedeeming: _isRedeeming,
      lastSyncTime: _lastSyncTime,
      onRedeemTap: () {
        Navigator.of(context).pop();
        _redeemRewards();
      },
      onClose: () => Navigator.of(context).pop(),
    );

    Future<void> future;
    if (isWide) {
      future = showDialog(context: context, builder: (_) => Dialog(child: modalWidget));
    } else {
      future = showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: modalWidget),
      );
    }

    future.then((_) {
      if (wasPlaying) _togglePause();
    });
  }

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
    final double scale = min(size.width / 400, size.height / 800);
    canvas.save();
    canvas.scale(scale);
    
    final logicalSize = Size(size.width / scale, size.height / scale);
    final groundY = logicalSize.height * 0.65;

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
      final cx = (c.x - distance * c.speedFactor) % (logicalSize.width + 300) - 150;
      _drawCloud(canvas, cx, c.y, c.type, cloudPaint, cloudStroke);
    }

    // --- Ground texture (dots and dashes) ---
    final dashPaint = Paint()..color = Colors.black..style = PaintingStyle.fill;
    final double startWorldX = (distance / 16).floor() * 16.0;
    final double endWorldX = ((distance + logicalSize.width) / 16).ceil() * 16.0;
    
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
    for (double sx = 0; sx <= logicalSize.width; sx += 4) {
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
        if (sx < -20 || sx > logicalSize.width + 20) continue;
        final cy = groundY + coin.y;
        
        if (coin.isBonus) {
          // Bonus coin: ( O ) - slightly larger with an inner ring
          canvas.drawCircle(Offset(sx, cy), 11, coinPaint);
          canvas.drawCircle(Offset(sx, cy), 5, coinPaint);
        } else {
          // Regular coin: ( I )
          canvas.drawCircle(Offset(sx, cy), 9, coinPaint);
          canvas.drawLine(Offset(sx, cy - 4), Offset(sx, cy + 4), coinPaint);
        }
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
    canvas.restore(); // restore rotation/translation
    canvas.restore(); // restore global scale
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

class GameHud extends StatelessWidget {
  final int score;
  final Duration timeRemaining;
  final int bestScore;
  final int lifetimeCoins;
  final int pendingRewards;
  final bool isPaused;
  final DateTime? lastSyncTime;
  final VoidCallback onPauseTap;
  final VoidCallback onInfoTap;

  const GameHud({
    Key? key,
    required this.score,
    required this.timeRemaining,
    required this.bestScore,
    required this.lifetimeCoins,
    required this.pendingRewards,
    required this.isPaused,
    this.lastSyncTime,
    required this.onPauseTap,
    required this.onInfoTap,
  }) : super(key: key);

  String _fmtTime(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _hudText(String text, double scaleFactor, {bool bold = true}) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 18 * scaleFactor,
        letterSpacing: 1.5 * scaleFactor,
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        color: Colors.black,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaleFactor = ResponsiveHud.getScaleFactor(constraints.maxWidth);
        
        final leftCluster = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _hudText('SCORE: ${score.toString().padLeft(5, '0')}', scaleFactor),
            const SizedBox(height: 4),
            _hudText('LIFETIME COINS: $lifetimeCoins', scaleFactor, bold: false),
          ],
        );

        final centerCluster = Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            _hudText('TIME: ${_fmtTime(timeRemaining)}', scaleFactor),
          ],
        );

        final rightCluster = Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _hudText('BEST: ${bestScore.toString().padLeft(5, '0')}', scaleFactor),
                SizedBox(width: 8 * scaleFactor),
                GestureDetector(
                  onTap: onInfoTap,
                  child: Icon(Icons.info_outline, color: Colors.black, size: 24 * scaleFactor),
                ),
                SizedBox(width: 8 * scaleFactor),
                GestureDetector(
                  onTap: onPauseTap,
                  child: Icon(isPaused ? Icons.play_arrow : Icons.pause, color: Colors.black, size: 24 * scaleFactor),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _hudText('REWARDS: ₹$pendingRewards', scaleFactor, bold: false),
          ],
        );

        return Padding(
          padding: EdgeInsets.all(16.0 * scaleFactor),
          child: constraints.maxWidth > ResponsiveHud.tabletBreakpoint
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: leftCluster),
                    Expanded(child: centerCluster),
                    Expanded(child: Align(alignment: Alignment.topRight, child: rightCluster)),
                  ],
                )
              : Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.start,
                  spacing: 16 * scaleFactor,
                  runSpacing: 16 * scaleFactor,
                  children: [
                    leftCluster,
                    rightCluster,
                    SizedBox(
                      width: double.infinity,
                      child: centerCluster,
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _InfoModal extends StatelessWidget {
  final int lifetimeCoins;
  final int pendingRewards;
  final bool isRedeeming;
  final DateTime? lastSyncTime;
  final VoidCallback onRedeemTap;
  final VoidCallback onClose;

  const _InfoModal({
    required this.lifetimeCoins,
    required this.pendingRewards,
    this.isRedeeming = false,
    this.lastSyncTime,
    required this.onRedeemTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final syncText = lastSyncTime == null
        ? 'Not synced yet'
        : 'Last updated ${DateTime.now().difference(lastSyncTime!).inSeconds}s ago';
        
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Game Info & Rewards', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                IconButton(icon: const Icon(Icons.close), onPressed: onClose),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            const Text('How to play:', style: TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace')),
            const Text('Touch your screen to move the scooter. Get a delivery to the destination to complete the mission.', style: TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 16),
            const Text('Scoring:', style: TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace')),
            const Text('Distance increases your score. Collecting coins gives a +25 score bonus. "Best" tracks your highest score across all sessions.', style: TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 16),
            const Text('Lifetime Coins:', style: TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace')),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: ((lifetimeCoins % kCoinsPerReward) / kCoinsPerReward).clamp(0.0, 1.0),
              backgroundColor: Colors.grey[300],
              color: Colors.black,
              minHeight: 12,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${lifetimeCoins % kCoinsPerReward} / $kCoinsPerReward to next ₹$kRewardAmountInRupees', style: const TextStyle(fontFamily: 'monospace')),
                Text(syncText, style: const TextStyle(color: Colors.grey, fontSize: 12, fontFamily: 'monospace')),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Rewards:', style: TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace')),
            const Text('Collect 100,000 coins to earn a ₹50 wallet reward!', style: TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 16),
            Text('Current Balance: ₹$pendingRewards', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (pendingRewards >= kRewardAmountInRupees && !isRedeeming) ? onRedeemTap : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  disabledBackgroundColor: Colors.grey,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: isRedeeming
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text('REDEEM ₹$pendingRewards', style: TextStyle(color: pendingRewards >= kRewardAmountInRupees ? Colors.white : Colors.white70, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
