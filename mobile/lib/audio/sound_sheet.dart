// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import 'audio_controller.dart';

/// The Sound panel: listen to the computer, talk to it.
class SoundSheet extends StatelessWidget {
  const SoundSheet({super.key, required this.audio});

  final AudioController audio;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final usable = audio.available && audio.allowed;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('Sound', style: theme.textTheme.titleLarge),
                ),
                if (!audio.available)
                  const _Note(
                    icon: Icons.system_update_alt,
                    text: 'Update PairDesk on the computer (0.10 or newer) to hear it and talk to it.',
                  )
                else if (!audio.allowed)
                  const _Note(
                    icon: Icons.block,
                    text: 'Sound is turned off on the computer: PairDesk → Permissions → Sound and talking.',
                  ),
                if (audio.error != null) _Note(icon: Icons.error_outline, text: audio.error!, error: true),
                const _Header('Listen'),
                SwitchListTile(
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: const Text('Computer sound'),
                  subtitle: const Text('Videos, music and calls playing on the computer'),
                  value: audio.sound,
                  onChanged: usable && !audio.busy ? audio.setSound : null,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.mic_none),
                  title: const Text('Computer\'s microphone'),
                  subtitle: Text(
                    audio.micAllowed
                        ? 'Hear people near the computer. The computer shows that you\'re listening.'
                        : 'Off on the computer. To allow it: PairDesk → Permissions → Hear the microphone.',
                  ),
                  value: audio.mic,
                  onChanged: usable && audio.micAllowed && !audio.busy ? audio.setMic : null,
                ),
                const _Header('Talk to the computer'),
                const SizedBox(height: 8),
                Center(
                  child: _TalkButton(audio: audio, enabled: usable),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    audio.talking
                        ? (audio.handsFree ? 'Talking. Tap to stop.' : 'Talking…')
                        : 'Hold to talk through the computer\'s speakers',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.record_voice_over_outlined),
                  title: const Text('Keep talking'),
                  subtitle: const Text('Hands-free, until you turn it off'),
                  value: audio.handsFree,
                  onChanged: usable ? audio.setHandsFree : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Talk and listen at the same time, like a call. Use headphones on the phone for the best sound.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TalkButton extends StatelessWidget {
  const _TalkButton({required this.audio, required this.enabled});

  final AudioController audio;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = audio.talking;
    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: on ? 104 : 96,
      height: on ? 104 : 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: !enabled ? scheme.surfaceContainerHighest : (on ? scheme.error : scheme.primary),
      ),
      child: Icon(
        on ? Icons.mic : Icons.mic_none,
        size: 44,
        color: !enabled ? scheme.onSurfaceVariant : (on ? scheme.onError : scheme.onPrimary),
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
        child: button,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.error = false});
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      color: error ? scheme.errorContainer : scheme.surfaceContainerHigh,
      elevation: 0,
      child: ListTile(
        leading: Icon(icon, color: error ? scheme.onErrorContainer : null),
        title: Text(text, style: TextStyle(color: error ? scheme.onErrorContainer : null)),
      ),
    );
  }
}
