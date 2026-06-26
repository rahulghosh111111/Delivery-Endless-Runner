import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'dart:ui' as ui;

void main() {
  test('analyze hill image', () async {
    final bytes = File('hill.png').readAsBytesSync();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    
    print('Width: ${image.width}, Height: ${image.height}');
    
    final byteData = await image.toByteData();
    if (byteData == null) {
      print('No byte data');
      return;
    }
    
    final List<int> heights = [];
    for (int x = 0; x < image.width; x++) {
      int surfaceY = 284;
      for (int y = 0; y < image.height; y++) {
        int offset = (y * image.width + x) * 4;
        int alpha = byteData.getUint8(offset + 3);
        if (alpha > 0) {
          surfaceY = y;
          break;
        }
      }
      heights.add(surfaceY);
    }
    
    final StringBuffer sb = StringBuffer();
    sb.writeln('const List<double> hillHeightMap = [');
    for (int h in heights) {
      // The image is 284 high. Let's make the height relative to 0 being flat.
      // So height = 284 - surfaceY.
      // But our game uses `groundY + h`, where h is the negative offset for peaks.
      // So `h = surfaceY - 284`.
      sb.writeln('  ${(h - 284).toDouble()},');
    }
    sb.writeln('];');
    sb.writeln('const double hillImageWidth = ${image.width.toDouble()};');
    sb.writeln('const double hillImageHeight = ${image.height.toDouble()};');
    
    File('lib/game/hill_heightmap.dart').writeAsStringSync(sb.toString());
    print('Generated lib/game/hill_heightmap.dart');
  });
}
