// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/buttons/custom_button.dart';
import 'package:pairdesk/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('every action type survives a save round trip', () {
    final buttons = [
      CustomButton(
        id: '1',
        label: 'Copy',
        action: const ComboAction([Modifier.ctrl], char: 'c'),
      ),
      CustomButton(
        id: '2',
        label: 'Task Mgr',
        action: const ComboAction([Modifier.ctrl, Modifier.shift], key: AgentKey.escape),
      ),
      CustomButton(id: '3', label: 'Start', action: const ComboAction([Modifier.meta])),
      CustomButton(id: '4', label: 'Email', action: const TextAction('me@example.com')),
      CustomButton(id: '5', label: 'Calc', action: const AppAction('a1', 'Calculator')),
      CustomButton(id: '6', label: 'Bed', action: const PowerButtonAction(PowerAction.sleep)),
    ];
    for (final b in buttons) {
      final copy = CustomButton.fromJson(b.toJson())!;
      expect(copy.toJson(), b.toJson());
    }
  });

  test('broken saved buttons are dropped, not crashed on', () {
    expect(
      CustomButton.fromJson({
        'id': 'x',
        'label': 'x',
        'action': {'type': 'combo'},
      }),
      isNull,
    );
    expect(
      CustomButton.fromJson({
        'id': 'x',
        'label': 'x',
        'action': {'type': 'power', 'a': 'explode'},
      }),
      isNull,
    );
    expect(
      CustomButton.fromJson({
        'id': 'x',
        'label': 'x',
        'action': {'type': 'text', 's': ''},
      }),
      isNull,
    );
    expect(
      CustomButton.fromJson({
        'id': 'x',
        'label': 'x',
        'action': {'type': 'shell', 'cmd': 'rm'},
      }),
      isNull,
    );
    expect(CustomButton.fromJson('nope'), isNull);
  });

  test('describes shortcuts with the right name for the Windows key', () {
    const a = ComboAction([Modifier.meta, Modifier.shift], char: 's');
    expect(a.describe(os: 'windows'), 'Win + Shift + S');
    expect(a.describe(os: 'linux'), 'Super + Shift + S');
    expect(const ComboAction([Modifier.alt], key: AgentKey.f4).describe(), 'Alt + F4');
  });

  test('default buttons fit the computer', () {
    final win = defaultButtons(os: 'windows').map((b) => b.label);
    final linux = defaultButtons(os: 'linux').map((b) => b.label);
    expect(win, containsAll(['Copy', 'Paste', 'Task Manager', 'Screenshot']));
    expect(linux, contains('Screenshot'));
    expect(linux, isNot(contains('Task Manager')));
    final ids = defaultButtons(os: 'windows').map((b) => b.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'ids are unique');
  });

  test('button store and favourites persist', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ButtonStore();
    expect(await store.load(), isNull, reason: 'defaults until changed');
    await store.save([CustomButton(id: 'x', label: 'Hi', action: const TextAction('hi'))]);
    expect((await store.load())!.single.label, 'Hi');
    await store.reset();
    expect(await store.load(), isNull);

    final favs = FavouriteStore();
    await favs.save('pc1', ['a1', 'a2']);
    expect(await favs.load('pc1'), ['a1', 'a2']);
    expect(await favs.load('pc2'), isEmpty);
  });

  group('app lock timing', () {
    final t0 = DateTime(2026, 1, 1, 12);
    test('off means never', () {
      expect(shouldLock(enabled: false, after: LockAfter.immediately, backgroundedAt: t0, now: t0), isFalse);
    });
    test('immediately locks on any return', () {
      expect(shouldLock(enabled: true, after: LockAfter.immediately, backgroundedAt: t0, now: t0), isTrue);
    });
    test('after a minute only once a minute has passed', () {
      bool at(int secs) => shouldLock(
        enabled: true,
        after: LockAfter.oneMinute,
        backgroundedAt: t0,
        now: t0.add(Duration(seconds: secs)),
      );
      expect(at(30), isFalse);
      expect(at(60), isTrue);
    });
    test('never backgrounded means no lock', () {
      expect(shouldLock(enabled: true, after: LockAfter.immediately, backgroundedAt: null, now: t0), isFalse);
    });
  });

  test('settings persist and clamp', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await AppSettings.load();
    expect(s.appLock, isFalse);
    expect(s.pointerSpeed, 1.0);
    expect(s.naturalScroll, isTrue);
    await s.setPointerSpeed(99);
    expect(s.pointerSpeed, AppSettings.maxSpeed);
    await s.setAppLock(true);
    await s.setLockAfter(LockAfter.fiveMinutes);
    final again = await AppSettings.load();
    expect(again.appLock, isTrue);
    expect(again.lockAfter, LockAfter.fiveMinutes);
  });
}
