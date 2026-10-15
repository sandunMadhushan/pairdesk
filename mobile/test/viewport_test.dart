// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/screen/viewport.dart';

void main() {
  const view = Size(400, 300);
  const picture = Size(1600, 900);

  test('at zoom 1 the whole picture fits, centred', () {
    final v = ScreenViewport();
    final t = v.transform(view, picture);
    expect(t.scale, 0.25);
    expect(t.offset, const Offset(0, (300 - 225) / 2));
    // Following does nothing when everything is visible.
    v.follow(const Offset(1590, 890), view, picture);
    expect(v.transform(view, picture).offset, t.offset);
  });

  test('zooming keeps the point under the fingers in place', () {
    final v = ScreenViewport();
    const focus = Offset(100, 120);
    final before = v.transform(view, picture).toPicture(focus);
    v.zoomBy(2, focus, view, picture);
    final t = v.transform(view, picture);
    expect(v.zoom, 2);
    expect(t.scale, 0.5);
    expect(t.toView(before).dx, closeTo(focus.dx, 0.001));
    expect(t.toView(before).dy, closeTo(focus.dy, 0.5));
    // Never past the picture's edges.
    expect(t.offset.dx, lessThanOrEqualTo(0));
    expect(t.pictureRect(picture).right, greaterThanOrEqualTo(view.width));
  });

  test('zoom is limited', () {
    final v = ScreenViewport();
    v.zoomBy(100, Offset.zero, view, picture);
    expect(v.zoom, ScreenViewport.maxZoom);
    v.zoomBy(0.0001, Offset.zero, view, picture);
    expect(v.zoom, 1);
  });

  test('when zoomed in, the view follows the pointer', () {
    final v = ScreenViewport();
    v.zoomBy(4, const Offset(200, 150), view, picture);
    // Pointer far to the right of what is shown.
    const pointer = Offset(1500, 450);
    v.follow(pointer, view, picture);
    final p = v.transform(view, picture).toView(pointer);
    expect(p.dx, inInclusiveRange(0, view.width));
    expect(p.dx, lessThanOrEqualTo(view.width * (1 - ScreenViewport.followMargin) + 0.001));
    // Pointer at the very corner: the view stops at the picture's edge.
    v.follow(const Offset(1600, 900), view, picture);
    final t = v.transform(view, picture);
    expect(t.pictureRect(picture).right, closeTo(view.width, 0.001));
    expect(t.pictureRect(picture).bottom, closeTo(view.height, 0.001));
  });
}
