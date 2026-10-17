import 'dart:async';

import 'package:flutter/material.dart';

import '../core/reader/reader_aloud_controller.dart';
import '../services/online_tts_engine.dart';
import '../services/reader_aloud_service.dart';
import '../services/tts_service.dart';
import '../utils/reader_themes.dart';

Future<void> showReaderAloud({
  required BuildContext context,
  required ReaderAloudController controller,
  required TtsService ttsService,
  required ReaderAloudService aloudService,
  required ReaderThemePalette palette,
  required ThemeData themeData,
  String author = '',
}) async {
  await aloudService.initialize();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette.controlBar,
    constraints: BoxConstraints(
      maxWidth: 620,
      maxHeight: MediaQuery.sizeOf(context).height * 0.82,
    ),
    builder: (context) => Theme(
      data: themeData,
      child: ReaderAloudPlayerPage(
        controller: controller,
        ttsService: ttsService,
        aloudService: aloudService,
        palette: palette,
        author: author,
      ),
    ),
  );
}

Future<void> showReaderAloudPlayer({
  required BuildContext context,
  required ReaderAloudController controller,
  required TtsService ttsService,
  required ReaderAloudService aloudService,
  required ReaderThemePalette palette,
  required ThemeData themeData,
  String author = '',
}) => showReaderAloud(
  context: context,
  controller: controller,
  ttsService: ttsService,
  aloudService: aloudService,
  palette: palette,
  themeData: themeData,
  author: author,
);

Future<void> showReaderAloudSettingsSheet({
  required BuildContext context,
  required ReaderAloudController controller,
  required TtsService ttsService,
  required ReaderAloudService aloudService,
  required ReaderThemePalette palette,
  required ThemeData themeData,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  showDragHandle: true,
  backgroundColor: palette.controlBar,
  constraints: const BoxConstraints(maxWidth: 620),
  builder: (context) => Theme(
    data: themeData,
    child: ReaderAloudPanel(
      controller: controller,
      ttsService: ttsService,
      aloudService: aloudService,
      palette: palette,
    ),
  ),
);

@Deprecated('Use showReaderAloudSettingsSheet')
Future<void> showReaderAloudPanelSheet({
  required BuildContext context,
  required ReaderAloudController controller,
  required TtsService ttsService,
  required ReaderAloudService aloudService,
  required ReaderThemePalette palette,
  required ThemeData themeData,
}) => showReaderAloudSettingsSheet(
  context: context,
  controller: controller,
  ttsService: ttsService,
  aloudService: aloudService,
  palette: palette,
  themeData: themeData,
);

class ReaderAloudPlayerPage extends StatefulWidget {
  const ReaderAloudPlayerPage({
    super.key,
    required this.controller,
    required this.ttsService,
    required this.aloudService,
    required this.palette,
    this.author = '',
    this.compactControls = false,
  });

  final ReaderAloudController controller;
  final TtsService ttsService;
  final ReaderAloudService aloudService;
  final ReaderThemePalette palette;
  final String author;
  final bool compactControls;

  @override
  State<ReaderAloudPlayerPage> createState() => _ReaderAloudPlayerPageState();
}

class _ReaderAloudPlayerPageState extends State<ReaderAloudPlayerPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.ttsService.ensureVoicesLoaded());
    if (!widget.controller.isActive) unawaited(widget.controller.start());
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: AnimatedBuilder(
      animation: Listenable.merge([
        widget.controller,
        widget.ttsService,
        widget.aloudService,
      ]),
      builder: (context, _) {
        final chapter = widget.controller.currentChapter;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.controller.source.bookTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (widget.author.trim().isNotEmpty)
                Text(
                  widget.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: 12),
              Text(
                chapter?.title ?? '准备朗读',
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: chapter == null
                    ? null
                    : widget.controller.chapterProgress,
              ),
              const SizedBox(height: 16),
              _PlaybackControls(controller: widget.controller),
              const Divider(height: 32),
              ReaderAloudPanel(
                controller: widget.controller,
                ttsService: widget.ttsService,
                aloudService: widget.aloudService,
                palette: widget.palette,
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({required this.controller});

  final ReaderAloudController controller;

  @override
  Widget build(BuildContext context) {
    final playing =
        controller.state == ReaderAloudPlaybackState.playing ||
        controller.state == ReaderAloudPlaybackState.loading;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一段',
          onPressed: controller.previous,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        const SizedBox(width: 12),
        FilledButton.tonalIcon(
          onPressed: playing ? controller.pause : controller.resume,
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
          label: Text(playing ? '暂停' : '继续'),
        ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: '下一段',
          onPressed: controller.next,
          icon: const Icon(Icons.skip_next_rounded),
        ),
        IconButton(
          tooltip: '停止',
          onPressed: controller.stop,
          icon: const Icon(Icons.stop_rounded),
        ),
      ],
    );
  }
}

class ReaderAloudPanel extends StatelessWidget {
  const ReaderAloudPanel({
    super.key,
    required this.controller,
    required this.ttsService,
    required this.aloudService,
    required this.palette,
  });

  final ReaderAloudController controller;
  final TtsService ttsService;
  final ReaderAloudService aloudService;
  final ReaderThemePalette palette;

  @override
  Widget build(BuildContext context) {
    final online = ttsService.isOnlineMode;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('在线 TTS（豆包）'),
          subtitle: Text(
            online ? ttsService.onlineServerUrl : '关闭时使用系统语音',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          value: online,
          onChanged: (value) =>
              unawaited(ttsService.setOnlineTtsEnabled(value)),
        ),
        if (online) ...[
          _OnlineServerUrlField(ttsService: ttsService),
          const SizedBox(height: 4),
          _OnlineSpeakerSelector(ttsService: ttsService),
          _OnlineConnectionTest(ttsService: ttsService),
          const SizedBox(height: 4),
        ],
        _SettingSlider(
          label: '语速',
          value: ttsService.speechRate,
          min: 0.1,
          max: 1,
          onChanged: ttsService.setSpeechRate,
        ),
        _SettingSlider(
          label: '音量',
          value: ttsService.speechVolume,
          min: 0,
          max: 1,
          onChanged: ttsService.setVolume,
        ),
        if (!online) ...[
          _SettingSlider(
            label: '音调',
            value: ttsService.speechPitch,
            min: 0.5,
            max: 2,
            onChanged: ttsService.setPitch,
          ),
          if (ttsService.availableVoices.isNotEmpty)
            DropdownButtonFormField<TtsVoiceOption>(
              initialValue: ttsService.currentVoice,
              decoration: const InputDecoration(labelText: '系统语音'),
              items: [
                for (final voice in ttsService.availableVoices)
                  DropdownMenuItem(
                    value: voice,
                    child: Text(
                      voice.subtitle.isEmpty
                          ? voice.title
                          : '${voice.title} · ${voice.subtitle}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (voice) {
                if (voice != null) unawaited(ttsService.setVoice(voice));
              },
            ),
        ],
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('朗读时跟随页面'),
          value: aloudService.followPageTurns,
          onChanged: aloudService.setFollowPageTurns,
        ),
      ],
    );
  }
}

class _OnlineServerUrlField extends StatefulWidget {
  const _OnlineServerUrlField({required this.ttsService});

  final TtsService ttsService;

  @override
  State<_OnlineServerUrlField> createState() => _OnlineServerUrlFieldState();
}

class _OnlineServerUrlFieldState extends State<_OnlineServerUrlField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.ttsService.onlineServerUrl,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    unawaited(widget.ttsService.setOnlineServerUrl(url));
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    decoration: InputDecoration(
      labelText: '服务地址',
      hintText: 'http://192.168.1.74:3456',
      suffixIcon: IconButton(
        tooltip: '保存并刷新音色',
        icon: const Icon(Icons.save_rounded),
        onPressed: _submit,
      ),
    ),
    keyboardType: TextInputType.url,
    autocorrect: false,
    textInputAction: TextInputAction.done,
    onSubmitted: (_) => _submit(),
  );
}

class _OnlineSpeakerSelector extends StatelessWidget {
  const _OnlineSpeakerSelector({required this.ttsService});

  final TtsService ttsService;

  @override
  Widget build(BuildContext context) {
    final speakers = ttsService.onlineSpeakers;
    final current = ttsService.currentOnlineSpeaker;
    if (ttsService.isLoadingOnlineSpeakers && speakers.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final groups = <String, List<OnlineSpeaker>>{};
    for (final speaker in speakers) {
      groups
          .putIfAbsent(speaker.category, () => <OnlineSpeaker>[])
          .add(speaker);
    }
    final selected = speakers.firstWhere(
      (speaker) => speaker.name == current,
      orElse: () => speakers.first,
    );
    return DropdownButtonFormField<OnlineSpeaker>(
      initialValue: selected,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '在线音色'),
      selectedItemBuilder: (context) => [
        for (final speaker in speakers)
          Text(speaker.name, overflow: TextOverflow.ellipsis),
      ],
      items: [
        for (final entry in groups.entries) ...[
          DropdownMenuItem<OnlineSpeaker>(
            enabled: false,
            child: Text(
              OnlineSpeaker(name: '', category: entry.key).categoryLabel,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          for (final speaker in entry.value)
            DropdownMenuItem<OnlineSpeaker>(
              value: speaker,
              child: Text(speaker.name, overflow: TextOverflow.ellipsis),
            ),
        ],
      ],
      onChanged: (speaker) {
        if (speaker != null) {
          unawaited(ttsService.setOnlineSpeaker(speaker.name));
        }
      },
    );
  }
}

class _OnlineConnectionTest extends StatefulWidget {
  const _OnlineConnectionTest({required this.ttsService});

  final TtsService ttsService;

  @override
  State<_OnlineConnectionTest> createState() => _OnlineConnectionTestState();
}

class _OnlineConnectionTestState extends State<_OnlineConnectionTest> {
  bool _testing = false;
  String? _result;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final error = await widget.ttsService.testOnlineConnection();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = error ?? '连接正常';
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      children: [
        OutlinedButton.icon(
          onPressed: _testing ? null : () => unawaited(_test()),
          icon: _testing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_tethering_rounded, size: 18),
          label: const Text('测试连接'),
        ),
        if (_result != null) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _result!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _result == '连接正常'
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final Future<void> Function(double) onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 48, child: Text(label)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: (next) => unawaited(onChanged(next)),
        ),
      ),
    ],
  );
}
