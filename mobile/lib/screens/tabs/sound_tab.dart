// SPDX-License-Identifier: GPL-3.0-or-later
// Sound: hear the computer, talk through it, and its media keys.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../agent_connection.dart';
import '../../audio/audio_controller.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SoundTab extends StatelessWidget {
  const SoundTab({super.key, required this.audio, required this.connection});

  final AudioController audio;
  final AgentConnection connection;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final usable = audio.available && audio.allowed;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            if (!audio.available)
              const _Note(
                icon: Icons.system_update_alt_rounded,
                text: 'Update PairDesk on the computer (0.10 or newer) to hear it and talk to it.',
              )
            else if (!audio.allowed)
              const _Note(
                icon: Icons.block_rounded,
                text: 'Sound is turned off on the computer: PairDesk → Permissions → Sound and talking.',
              ),
            if (audio.error != null) _Note(icon: Icons.error_outline_rounded, text: audio.error!),
            PdCard(
              child: Column(
                children: [
                  PdRow(
                    icon: Icons.volume_up_rounded,
                    title: 'Computer sound',
                    subtitle: 'Videos, music and calls playing on the computer',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Bars(on: audio.sound),
                        const SizedBox(width: 8),
                        Switch(value: audio.sound, onChanged: usable && !audio.busy ? audio.setSound : null),
                      ],
                    ),
                    onTap: usable && !audio.busy ? () => audio.setSound(!audio.sound) : null,
                  ),
                  const PdDivider(),
                  PdRow(
                    icon: Icons.mic_none_rounded,
                    title: 'Computer\'s microphone',
                    subtitle: audio.micAllowed
                        ? 'Hear people near the computer. The computer shows that you\'re listening.'
                        : 'Off on the computer. To allow it: PairDesk → Permissions → Hear the microphone.',
                    trailing: Switch(
                      value: audio.mic,
                      onChanged: usable && audio.micAllowed && !audio.busy ? audio.setMic : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            PdCard(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
              child: Column(
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Talk through the computer',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _TalkButton(audio: audio, enabled: usable),
                  const SizedBox(height: 10),
                  Text(
                    audio.talking
                        ? (audio.handsFree ? 'Talking. Tap to stop.' : 'Talking…')
                        : 'Hold to talk through the computer\'s speakers',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: c.sub),
                  ),
                  const SizedBox(height: 6),
                  const PdDivider(indent: 0),
                  PdRow(
                    icon: Icons.record_voice_over_outlined,
                    title: 'Keep talking',
                    subtitle: 'Hands-free, until you turn it off',
                    trailing: Switch(value: audio.handsFree, onChanged: usable ? audio.setHandsFree : null),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            PdCard(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Media on the computer', style: TextStyle(fontSize: 14, color: c.sub)),
                  const SizedBox(height: 12),
                  _MediaKeys(connection: connection),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
              child: Text(
                'Talk and listen at the same time, like a call. Use headphones on the phone for the best sound.',
                style: TextStyle(fontSize: 13, color: c.sub, height: 1.4),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MediaKeys extends StatelessWidget {
  const _MediaKeys({required this.connection});
  final AgentConnection connection;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    Widget key(IconData icon, String tip, AgentKey k, {bool big = false}) => RoundButton(
      icon: icon,
      tooltip: tip,
      onPressed: () {
        HapticFeedback.lightImpact();
        connection.key(k);
      },
      background: big ? c.inv : c.s2,
      foreground: big ? c.onInv : c.ink,
      size: big ? 62 : 50,
      iconSize: big ? 28 : 22,
    );
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            key(Icons.skip_previous_rounded, 'Previous', AgentKey.prev),
            key(Icons.play_arrow_rounded, 'Play / pause', AgentKey.playPause, big: true),
            key(Icons.skip_next_rounded, 'Next', AgentKey.next),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            key(Icons.volume_down_rounded, 'Volume down', AgentKey.volumeDown),
            key(Icons.volume_off_rounded, 'Mute', AgentKey.mute),
            key(Icons.volume_up_rounded, 'Volume up', AgentKey.volumeUp),
          ],
        ),
      ],
    );
  }
}

/// Five bars that move while the computer's sound is on.
class _Bars extends StatefulWidget {
  const _Bars({required this.on});
  final bool on;

  @override
  State<_Bars> createState() => _BarsState();
}

class _BarsState extends State<_Bars> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  void _sync() {
    if (widget.on && PdMotion.loops(context)) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Bars old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return AnimatedOpacity(
      duration: PdMotion.fade,
      opacity: widget.on ? 1 : 0,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < 4; i++)
              Container(
                width: 4,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                height: 6 + 14 * (0.5 + 0.5 * math.sin((_c.value + i * 0.18) * 2 * math.pi)),
                decoration: BoxDecoration(color: c.ink, borderRadius: BorderRadius.circular(3)),
              ),
          ],
        ),
      ),
    );
  }
}

class _TalkButton extends StatefulWidget {
  const _TalkButton({required this.audio, required this.enabled});

  final AudioController audio;
  final bool enabled;

  @override
  State<_TalkButton> createState() => _TalkButtonState();
}

class _TalkButtonState extends State<_TalkButton> with SingleTickerProviderStateMixin {
  late final AnimationController _rings = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  AudioController get audio => widget.audio;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_TalkButton old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (audio.talking && PdMotion.loops(context)) {
      if (!_rings.isAnimating) _rings.repeat();
    } else {
      _rings.stop();
      _rings.value = 0;
    }
  }

  @override
  void dispose() {
    _rings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final on = audio.talking;
    final enabled = widget.enabled;
    const size = 112.0;
    final button = AnimatedScale(
      scale: on ? 1.06 : 1,
      duration: PdMotion.press,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: !enabled ? c.s2 : (on ? c.inv : c.accent),
          boxShadow: enabled && !on ? c.glow : const [],
        ),
        child: Icon(
          on ? Icons.mic_rounded : Icons.mic_none_rounded,
          size: 44,
          color: !enabled ? c.sub : (on ? (c.dark ? PdColors.onAccent : PdColors.lime) : PdColors.onAccent),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: on ? 'Stop talking' : 'Hold to talk',
      child: GestureDetector(
        onTapDown: !enabled || audio.handsFree ? null : (_) => audio.startTalking(),
        onTapUp: !enabled || audio.handsFree ? null : (_) => audio.stopTalking(),
        onTapCancel: !enabled || audio.handsFree ? null : audio.stopTalking,
        onTap: enabled && audio.handsFree ? () => audio.setHandsFree(false) : null,
        child: SizedBox(
          width: 150,
          height: 150,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (on)
                AnimatedBuilder(
                  animation: _rings,
                  builder: (_, _) => Container(
                    width: size * (1 + 0.3 * _rings.value),
                    height: size * (1 + 0.3 * _rings.value),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: c.accent.withValues(alpha: 1 - _rings.value), width: 3),
                    ),
                  ),
                ),
              button,
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: PdCard(
      child: PdRow(icon: icon, title: text),
    ),
  );
}
