// SPDX-License-Identifier: GPL-3.0-or-later
// Which part of the computer's picture is shown, for the touchpad-style
// screen view: zoom with two fingers, and the view follows the pointer.
// Pure Dart, so it can be unit-tested.

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// Where the picture is drawn: picture pixel p appears at offset + p·scale.
class ViewTransform {
  const ViewTransform(this.scale, this.offset);
  final double scale;
  final Offset offset;

  Offset toView(Offset picture) => offset + picture * scale;
  Offset toPicture(Offset view) => (view - offset) / scale;
  Rect pictureRect(Size picture) => offset & (picture * scale);
}

class ScreenViewport {
  static const maxZoom = 6.0;

  /// Part of the view (on each side) the pointer may enter before the
  /// view moves along with it.
  static const followMargin = 0.2;

  double _zoom = 1;
  Offset? _center;

  /// 1 = the whole picture fits.
  double get zoom => _zoom;

  ViewTransform transform(Size view, Size picture) {
    final fit = math.min(view.width / picture.width, view.height / picture.height);
    final scale = fit * _zoom;
    final c = _clamp(_center ?? picture.center(Offset.zero), view, picture, scale);
    _center = c;
    double axis(double viewLen, double picLen, double centre) {
      final shown = picLen * scale;
      return shown <= viewLen ? (viewLen - shown) / 2 : viewLen / 2 - centre * scale;
    }

    return ViewTransform(
      scale,
      Offset(axis(view.width, picture.width, c.dx), axis(view.height, picture.height, c.dy)),
    );
  }

  /// Keeps [pointer] (picture pixels) out of the view's edges when zoomed in.
  void follow(Offset pointer, Size view, Size picture) {
    if (_zoom <= 1) return;
    final t = transform(view, picture);
    final p = t.toView(pointer);
    double push(double pos, double len) {
      final m = len * followMargin;
      if (pos < m) return pos - m;
      if (pos > len - m) return pos - (len - m);
      return 0;
    }

    final move = Offset(push(p.dx, view.width), push(p.dy, view.height));
    if (move != Offset.zero) _center = _center! + move / t.scale;
  }

  /// Zooms by [factor], keeping the picture point under [focus] (view
  /// position) where it is.
  void zoomBy(double factor, Offset focus, Size view, Size picture) {
    final before = transform(view, picture);
    final anchor = before.toPicture(focus);
    _zoom = (_zoom * factor).clamp(1.0, maxZoom);
    final after = transform(view, picture);
    // Shift so that anchor lands back under focus.
    _center = _center! + (after.toView(anchor) - focus) / after.scale;
  }

  void reset() {
    _zoom = 1;
    _center = null;
  }

  static Offset _clamp(Offset c, Size view, Size picture, double scale) {
    double axis(double v, double viewLen, double picLen) {
      final half = viewLen / (2 * scale);
      if (picLen <= 2 * half) return picLen / 2;
      return v.clamp(half, picLen - half);
    }

    return Offset(axis(c.dx, view.width, picture.width), axis(c.dy, view.height, picture.height));
  }
}
