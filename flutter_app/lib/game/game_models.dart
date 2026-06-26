/// Core data models for the Delivery Endless Runner game.
/// Kept dependency-free (no Flame, no external game engine) so this can be
/// dropped into any Flutter app and rendered with CustomPainter.

import 'dart:math';

/// A coin placed somewhere along a terrain segment.
class CoinSpot {
  final double localX; // x position relative to the start of its segment
  final double y; // absolute y (world height) where the coin sits
  bool collected;

  CoinSpot({required this.localX, required this.y, this.collected = false});
}

/// One procedurally generated "tile" of terrain (~20-30s of travel at base
/// speed). Segments are recycled: when the player passes one, it is popped
/// from the front of the queue, regenerated (new coin layout, same or next
/// shape in the rotation) and pushed to the back — this is what creates the
/// seamless infinite loop described in the spec.
class TerrainSegment {
  final int shapeIndex; // which of the N shape templates this used
  final double width; // width in world units (px)
  final List<double> heights; // sampled height curve, fixed step
  final double sampleStep;
  final List<CoinSpot> coins;

  /// Absolute world-x where this segment starts. Updated every time the
  /// segment is recycled to the back of the queue.
  double worldStartX;

  TerrainSegment({
    required this.shapeIndex,
    required this.width,
    required this.heights,
    required this.sampleStep,
    required this.coins,
    required this.worldStartX,
  });

  /// Height of the terrain at a given absolute world-x (linear interpolation
  /// between sampled points). Returns null if x is outside this segment.
  double? heightAtWorldX(double worldX) {
    final localX = worldX - worldStartX;
    if (localX < 0 || localX > width) return null;
    final idxF = localX / sampleStep;
    final i0 = idxF.floor().clamp(0, heights.length - 1);
    final i1 = (i0 + 1).clamp(0, heights.length - 1);
    final frac = idxF - i0;
    return heights[i0] + (heights[i1] - heights[i0]) * frac;
  }

  /// Slope (radians) at a world-x — used to tilt the scooter sprite.
  double slopeAtWorldX(double worldX) {
    const probe = 6.0;
    final h0 = heightAtWorldX(worldX - probe) ?? heightAtWorldX(worldX) ?? 0;
    final h1 = heightAtWorldX(worldX + probe) ?? heightAtWorldX(worldX) ?? 0;
    return atan2(h1 - h0, probe * 2);
  }
}

enum GamePhase { intro, playing, paused, completed }
