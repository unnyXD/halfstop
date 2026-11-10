import 'package:flutter_test/flutter_test.dart';
import 'package:halfstop/frame_format.dart';

void main() {
  group('zoomGate', () {
    // XPan inside a 3:2 picture: the gate takes the full width and loses the
    // top and bottom. 65 / 24, expressed in the picture's own units.
    const gate = CropBox(0, 0.2229, 1.0, 0.5542);
    const shape = 1.0 / 0.5542;

    test('keeps the gap\'s shape at every zoom level', () {
      for (final factor in [0.2, 0.5, 0.9, 1.0, 1.3, 2.0, 5.0, 20.0]) {
        final out = zoomGate(gate, factor, const Offset(0.5, 0.5));
        expect(
          (out.width / out.height) / shape,
          closeTo(1.0, 0.001),
          reason: 'factor $factor broke the ratio',
        );
      }
    });

    test('never grows past the picture', () {
      // Zooming out used to clamp each axis at 1.0 separately, which turned a
      // wide gate into the whole frame -- and the engine refuses that shape.
      final out = zoomGate(gate, 0.1, const Offset(0.5, 0.5));
      expect(out.width, lessThanOrEqualTo(1.0));
      expect(out.height, lessThanOrEqualTo(1.0));
      expect(out.width, closeTo(1.0, 0.001));
      expect(out.height, closeTo(0.5542, 0.001));
    });

    test('stays inside the frame', () {
      for (final focal in const [Offset(0.0, 0.0), Offset(1.0, 1.0), Offset(0.2, 0.9)]) {
        for (final factor in [0.3, 1.0, 3.0, 12.0]) {
          final out = zoomGate(gate, factor, focal);
          expect(out.x, greaterThanOrEqualTo(-0.001));
          expect(out.y, greaterThanOrEqualTo(-0.001));
          expect(out.x + out.width, lessThanOrEqualTo(1.001));
          expect(out.y + out.height, lessThanOrEqualTo(1.001));
        }
      }
    });

    test('a square gate stays square', () {
      const square = CropBox(0.1, 0.1, 0.5, 0.5);
      for (final factor in [0.4, 1.0, 2.5, 9.0]) {
        final out = zoomGate(square, factor, const Offset(0.35, 0.35));
        expect(out.width, closeTo(out.height, 0.001), reason: 'factor $factor');
      }
    });
  });
}
