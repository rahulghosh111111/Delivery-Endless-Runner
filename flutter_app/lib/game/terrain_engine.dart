/// Procedural terrain generator + randomized coin spawner.
///
/// Implements the design from the spec images:
///  - 5 reusable "shape templates" (hill, double-hump, gentle valley, big
///    hill, rolling hills) that the loop cycles through endlessly.
///  - Every time a segment is (re)generated — even if it's the same shape
///    template as a previous lap — coins are freshly randomized, so the
///    terrain repeats but the coin pattern never feels identical twice.
///  - Coins are biased toward hilltops / slopes / valleys / clusters, with a
///    minimum spacing rule so they never feel crowded.

import 'dart:math';
import 'game_models.dart';

typedef HeightFn = double Function(double t); // t in [0,1] across the segment

class TerrainEngine {
  final Random _rng = Random();

  /// Visual scale of the terrain (peak-to-trough amplitude, world px).
  final double amplitude;

  /// Baseline ground height (world y for a flat road).
  final double baseline;

  /// Sampling resolution — smaller = smoother curve, more memory.
  final double sampleStep;

  /// Width (world px) of one segment. Shortened to 2400 for punchier hills.
  final double segmentWidth;

  int _shapeCycle = 0;

  TerrainEngine({
    this.amplitude = 80,
    this.baseline = 0,
    this.sampleStep = 12,
    this.segmentWidth = 2400,
  });

  // ---- Shape templates (Segment A..E from the spec) ----------------------
  static final List<HeightFn> _shapes = [
    // A: flat -> bump -> valley -> flat
    (t) {
      if (t < 0.1 || t > 0.9) return 0.0;
      double local = (t - 0.1) / 0.8; 
      return sin(local * pi * 2) * 0.6; 
    },
    // B: flat -> large bump -> flat
    (t) {
      if (t < 0.2 || t > 0.7) return 0.0;
      double local = (t - 0.2) / 0.5;
      return sin(local * pi) * 1.0; 
    },
    // C: flat -> deep valley -> flat
    (t) {
      if (t < 0.1 || t > 0.5) return 0.0;
      double local = (t - 0.1) / 0.4;
      return -sin(local * pi) * 0.7;
    },
    // D: flat -> double bump -> flat
    (t) {
      if (t < 0.2 || t > 0.9) return 0.0;
      double local = (t - 0.2) / 0.7;
      return max(0.0, sin(local * pi * 2) * 0.5 + sin(local * pi) * 0.6); 
    },
    // E: completely flat
    (t) => 0.0,
  ];

  List<TerrainSegment> buildInitialQueue({int count = 4}) {
    final queue = <TerrainSegment>[];
    double cursor = 0;
    for (int i = 0; i < count; i++) {
      queue.add(_generateSegment(worldStartX: cursor));
      cursor += segmentWidth;
    }
    return queue;
  }

  /// Recycle the front segment to the back of the queue with a fresh coin
  /// layout (terrain shape advances to the next in rotation).
  TerrainSegment recycle(TerrainSegment old, double newWorldStartX) {
    return _generateSegment(worldStartX: newWorldStartX);
  }

  TerrainSegment _generateSegment({required double worldStartX}) {
    final shapeIndex = _shapeCycle % _shapes.length;
    _shapeCycle++;
    final fn = _shapes[shapeIndex];

    final steps = (segmentWidth / sampleStep).ceil();
    final heights = List<double>.generate(steps + 1, (i) {
      final t = i / steps;
      return baseline - fn(t) * amplitude; // negative = up on screen
    });

    final coins = _spawnCoins(heights);

    return TerrainSegment(
      shapeIndex: shapeIndex,
      width: segmentWidth,
      heights: heights,
      sampleStep: sampleStep,
      coins: coins,
      worldStartX: worldStartX,
    );
  }

  // ---- Randomized coin spawning rules -------------------------------------
  List<CoinSpot> _spawnCoins(List<double> heights) {
    final coins = <CoinSpot>[];

    // Rule: random count, 1 to 5 coins per segment.
    final count = 1 + _rng.nextInt(5);

    // Rule: random pattern choice.
    final pattern = _rng.nextInt(4); // 0 single/spread, 1 cluster, 2 zigzag, 3 mixed

    // Candidate placement points: local minima (valleys), local maxima
    // (hilltops), and mid-slope points.
    final hilltops = <int>[];
    final valleys = <int>[];
    for (int i = 1; i < heights.length - 1; i++) {
      if (heights[i] < heights[i - 1] && heights[i] < heights[i + 1]) {
        hilltops.add(i); // remember: lower y == higher on screen == hilltop
      }
      if (heights[i] > heights[i - 1] && heights[i] > heights[i + 1]) {
        valleys.add(i);
      }
    }

    final minSpacingIdx = (heights.length / (count * 2)).clamp(2, 1000).toInt();
    final usedIndices = <int>[];

    int pickIndex() {
      List<int> pool;
      switch (pattern) {
        case 1: // cluster: bunch near one random point
          final centre = _rng.nextInt(heights.length);
          return (centre + _rng.nextInt(20) - 10).clamp(0, heights.length - 1);
        case 2: // zigzag: alternate hilltop/valley
          pool = usedIndices.length.isEven && hilltops.isNotEmpty
              ? hilltops
              : (valleys.isNotEmpty ? valleys : hilltops);
          break;
        case 3: // mixed: anywhere, slight bias to hilltops/valleys
          pool = [...hilltops, ...valleys, ...hilltops];
          break;
        default: // single/spread: evenly spaced with randInputJitter
          final span = heights.length ~/ count;
          final base = (usedIndices.length * span) + _rng.nextInt(span);
          return base.clamp(0, heights.length - 1);
      }
      if (pool.isEmpty) return _rng.nextInt(heights.length);
      return pool[_rng.nextInt(pool.length)];
    }

    int guard = 0;
    while (coins.length < count && guard < 50) {
      guard++;
      final idx = pickIndex();
      final tooClose = usedIndices.any((u) => (u - idx).abs() < minSpacingIdx);
      if (tooClose) continue;
      usedIndices.add(idx);
      coins.add(CoinSpot(
        localX: idx * sampleStep,
        // float the coin slightly above the road surface
        y: heights[idx] - 34,
      ));
    }

    return coins;
  }
}
