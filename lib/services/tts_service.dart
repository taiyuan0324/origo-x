// 文件说明：当前主链路 TTS 服务，直接封装 FlutterTts 并管理朗读状态。
// 技术要点：服务层、Flutter TTS、SharedPreferences、渲染层、Flutter。

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/reader/reader_aloud_controller.dart';
import 'online_tts_engine.dart';

class TtsVoiceOption {
  final String name;
  final String locale;
  final String? identifier;
  final String? displayName;
  final String? quality;
  final String? gender;

  const TtsVoiceOption({
    required this.name,
    required this.locale,
    this.identifier,
    this.displayName,
    this.quality,
    this.gender,
  });

  factory TtsVoiceOption.fromMap(Map<dynamic, dynamic> raw) {
    String readString(String key) {
      final value = raw[key];
      return value?.toString().trim() ?? '';
    }

    String? readNullable(String key) {
      final value = raw[key]?.toString().trim();
      if (value == null || value.isEmpty) {
        return null;
      }
      return value;
    }

    return TtsVoiceOption(
      name: readString('name'),
      locale: readString('locale'),
      identifier: readNullable('identifier'),
      displayName: readNullable('displayName'),
      quality: readNullable('quality'),
      gender: readNullable('gender'),
    );
  }

  TtsVoiceOption copyWith({
    String? name,
    String? locale,
    String? identifier,
    String? displayName,
    String? quality,
    String? gender,
  }) {
    return TtsVoiceOption(
      name: name ?? this.name,
      locale: locale ?? this.locale,
      identifier: identifier ?? this.identifier,
      displayName: displayName ?? this.displayName,
      quality: quality ?? this.quality,
      gender: gender ?? this.gender,
    );
  }

  String get normalizedLocale => locale.replaceAll('_', '-').trim();

  String get languageCode {
    final normalized = normalizedLocale.toLowerCase();
    if (normalized.isEmpty) {
      return '';
    }
    return normalized.split('-').first;
  }

  String get id {
    final trimmedIdentifier = identifier?.trim();
    if (trimmedIdentifier != null && trimmedIdentifier.isNotEmpty) {
      return trimmedIdentifier;
    }
    final normalizedName = name.trim().isNotEmpty ? name.trim() : 'default';
    final normalizedVoiceLocale = normalizedLocale.isNotEmpty
        ? normalizedLocale
        : 'und';
    return '$normalizedVoiceLocale::$normalizedName';
  }

  String get title {
    final preferredLabel = displayName?.trim();
    if (preferredLabel != null && preferredLabel.isNotEmpty) {
      return preferredLabel;
    }
    final trimmedName = name.trim();
    if (trimmedName.isNotEmpty) {
      return trimmedName;
    }
    return normalizedLocale.isNotEmpty ? normalizedLocale : 'System Voice';
  }

  String get subtitle {
    final parts = <String>[
      if (normalizedLocale.isNotEmpty) normalizedLocale,
      if (quality?.trim().isNotEmpty ?? false) _prettifyMeta(quality!),
      if (gender?.trim().isNotEmpty ?? false) _prettifyMeta(gender!),
    ];
    return parts.join(' · ');
  }

  bool matchesLanguage(String localeOrLanguage) {
    final normalized = localeOrLanguage.replaceAll('_', '-').trim();
    if (normalized.isEmpty) {
      return false;
    }
    return languageCode == normalized.toLowerCase().split('-').first;
  }

  bool matchesLocale(String localeOrLanguage) {
    return normalizedLocale.toLowerCase() ==
        localeOrLanguage.replaceAll('_', '-').trim().toLowerCase();
  }

  static String _prettifyMeta(String raw) {
    final normalized = raw.replaceAll('_', ' ').trim();
    if (normalized.isEmpty) {
      return raw;
    }
    return normalized[0].toUpperCase() + normalized.substring(1);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is TtsVoiceOption && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// 只使用系统 TTS（flutter_tts 封装平台系统引擎）。
class _QueuedTtsOperation {
  _QueuedTtsOperation({required this.texts, required this.onTextStarted});

  final List<String> texts;
  final ValueChanged<int> onTextStarted;
  final Completer<void> completion = Completer<void>();
  int nativeStartCount = 0;
  int completedCount = 0;
  int lastReportedIndex = -1;
  Object? error;
}

class TtsService extends ChangeNotifier
    implements
        ReaderAloudAdjustableEngine,
        ReaderAloudContinuousEngine,
        ReaderAloudQueuedEngine {
  static const String _voiceIdPrefKey = 'tts_voice_id';
  static const String _voiceIdentifierPrefKey = 'tts_voice_identifier';
  static const String _voiceNamePrefKey = 'tts_voice_name';
  static const String _voiceLocalePrefKey = 'tts_voice_locale';
  static const String _xiaomiTtsEngine = 'com.xiaomi.mibrain.speech';

  FlutterTts? _flutterTts;
  Future<void>? _initializationFuture;
  Future<void>? _voiceLoadingFuture;
  Completer<void>? _activeSpeakSignal;
  _QueuedTtsOperation? _activeQueuedOperation;
  Timer? _webStartTimer;
  Future<void> _speakModeTransition = Future<void>.value();
  int _speakCancellationVersion = 0;
  bool _isDisposed = false;

  bool _isPlaying = false;
  bool _isPaused = false;
  bool _isInitialized = false;
  bool _isInitializing = false;
  double _speechRate = 0.5;
  double _speechVolume = 1.0;
  double _speechPitch = 1.0;
  String _currentLanguage = 'zh-CN';
  List<String> _availableLanguages = const <String>[];
  String _currentText = '';
  int _currentPosition = 0;
  int _utteranceBasePosition = 0;
  String? _lastError;
  String? _lastErrorLanguage;
  bool _isLoadingVoices = false;
  String? _voiceLoadError;
  List<TtsVoiceOption> _availableVoices = const <TtsVoiceOption>[];
  TtsVoiceOption? _currentVoice;
  String? _androidTtsEngine;
  OnlineTtsEngine? _onlineEngine;
  bool _onlineEnabled = false;
  final FlutterTts Function() _ttsFactory;

  /// 在线 TTS 已启用且引擎就绪时，所有朗读操作委托给在线引擎。
  bool get _onlineActive => _onlineEnabled && _onlineEngine != null;

  OnlineTtsEngine? get _online => _onlineActive ? _onlineEngine : null;

  @override
  bool get isPlaying => _online?.isPlaying ?? _isPlaying;
  @override
  bool get isPaused => _online?.isPaused ?? _isPaused;
  @override
  int get currentPosition => _online?.currentPosition ?? _currentPosition;
  @override
  bool get supportsContinuousText => false;
  @override
  bool get supportsQueuedText =>
      _onlineActive || (!kIsWeb && _systemPlatformSupportsQueuedText);
  bool get isInitialized => _isInitialized;
  bool get isInitializing => _isInitializing;
  bool get isAvailable => _isInitialized;
  String? get lastError => _lastError;
  String? get lastErrorLanguage => _lastErrorLanguage;
  @override
  double get speechRate => _online?.speechRate ?? _speechRate;
  @override
  double get speechVolume => _online?.speechVolume ?? _speechVolume;
  double get speechPitch => _speechPitch;
  String get currentLanguage => _currentLanguage;
  List<String> get availableLanguages => _availableLanguages;
  String get currentVoiceLabel => _currentVoice?.title ?? 'system_default';

  static bool get _systemPlatformSupportsQueuedText =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// 是否处于在线 TTS 模式。
  bool get isOnlineMode => _onlineActive;

  List<OnlineSpeaker> get onlineSpeakers =>
      _onlineEngine?.speakers ?? kBuiltinOnlineSpeakers;

  String get currentOnlineSpeaker => _onlineEngine?.speaker ?? '温柔桃子';

  bool get isLoadingOnlineSpeakers => _onlineEngine?.isLoadingSpeakers ?? false;

  String? get onlineSpeakerLoadError => _onlineEngine?.speakerLoadError;

  String get currentText => _currentText;
  bool get isLoadingVoices => _isLoadingVoices;
  String? get voiceLoadError => _voiceLoadError;
  List<TtsVoiceOption> get availableVoices =>
      _onlineActive ? const <TtsVoiceOption>[] : _availableVoices;
  TtsVoiceOption? get currentVoice => _onlineActive ? null : _currentVoice;

  TtsService({FlutterTts Function()? ttsFactory})
    : _ttsFactory = ttsFactory ?? FlutterTts.new {
    unawaited(initialize());
  }

  Future<void> initialize({bool force = false}) async {
    if (_isDisposed) return;

    if (_isInitializing) {
      final pending = _initializationFuture;
      if (pending != null) {
        await pending;
      }
      return;
    }

    if (!force && _isInitialized && _flutterTts != null) {
      return;
    }

    final completer = Completer<void>();
    _initializationFuture = completer.future;

    _isInitializing = true;
    _lastError = null;
    if (force) {
      _isInitialized = false;
    }
    _notifySafe();

    try {
      await _loadSettings();

      final tts = _ttsFactory();
      _wireHandlers(tts);
      await _configureSystemTts(tts);
      await _detectAndroidTtsEngine(tts);
      await _refreshAvailableLanguages(tts);
      await _applyBestLanguage(tts);
      await _restoreSavedVoice(tts);
      // Several Android vendor engines reset their playback parameters when
      // setLanguage/setVoice is called. Voice selection therefore has to
      // happen before restoring rate, volume, and pitch.
      await _applyPlaybackParameters(tts);

      _flutterTts = tts;
      _isInitialized = true;
      _lastError = null;
      debugPrint('TTS 初始化成功，语言: $_currentLanguage');
    } catch (e) {
      _isInitialized = false;
      _isPlaying = false;
      _isPaused = false;
      _lastError = _toErrorText(e);
      debugPrint('TTS 初始化失败: $e');
    } finally {
      _isInitializing = false;
      _notifySafe();

      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_initializationFuture, completer.future)) {
        _initializationFuture = null;
      }
    }
  }

  Future<void> retryInitialize() async {
    await initialize(force: true);
  }

  /// 创建并挂载在线 TTS 引擎，状态变化经 [_relayChange] 转发给 UI。
  OnlineTtsEngine _attachOnlineEngine() {
    final existing = _onlineEngine;
    if (existing != null) {
      return existing;
    }
    final engine = OnlineTtsEngine();
    engine.addListener(_relayChange);
    _onlineEngine = engine;
    return engine;
  }

  Future<void> setOnlineTtsEnabled(bool value) async {
    if (_onlineEnabled == value) return;
    if (value) {
      _onlineEnabled = true;
      final engine = _attachOnlineEngine();
      await _saveSettings();
      _notifySafe();
      // 开关打开时立即探测服务，失败不阻塞界面，仅记录错误。
      unawaited(engine.testConnection());
      return;
    }
    _onlineEnabled = false;
    await _saveSettings();
    _notifySafe();
    await stop();
  }

  Future<void> setOnlineServerUrl(String url) async {
    final engine = _attachOnlineEngine();
    await engine.setServerUrl(url);
  }

  Future<void> setOnlineSpeaker(String speaker) async {
    final engine = _attachOnlineEngine();
    await engine.setSpeaker(speaker);
  }

  Future<void> refreshOnlineSpeakers() async {
    final engine = _onlineEngine;
    if (engine == null) return;
    await engine.refreshSpeakers();
  }

  Future<String?> testOnlineConnection() async {
    final engine = _attachOnlineEngine();
    return engine.testConnection();
  }

  String get onlineServerUrl =>
      _onlineEngine?.serverUrl ?? 'http://192.168.1.74:3456';

  Future<void> _configureSystemTts(FlutterTts tts) async {
    await tts.awaitSpeakCompletion(true);

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await tts.awaitSynthCompletion(true);
      // 0: flush，确保每次朗读直接替换旧任务，避免排队导致“没反应”。
      await tts.setQueueMode(0);
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      // Keep system speech nonmixable and retain the shared audio session
      // between queued utterances so chapter transitions do not introduce gaps.
      await tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        const <IosTextToSpeechAudioCategoryOptions>[],
        IosTextToSpeechAudioMode.defaultMode,
      );
      await tts.autoStopSharedSession(false);
      await tts.setSharedInstance(true);
    }
  }

  void _wireHandlers(FlutterTts tts) {
    tts.setStartHandler(() {
      _webStartTimer?.cancel();
      _webStartTimer = null;
      final queued = _activeQueuedOperation;
      if (queued != null) {
        final index = queued.nativeStartCount;
        if (index < queued.texts.length) {
          queued.nativeStartCount++;
          _reportQueuedTextStarted(queued, index);
        }
      }
      _isPlaying = true;
      _isPaused = false;
      _lastError = null;
      _notifySafe();
    });

    tts.setCompletionHandler(() {
      final queued = _activeQueuedOperation;
      if (queued != null) {
        // stop() can deliver one late completion after a replacement queue
        // is installed. Ignore only callbacks that cannot belong to an item
        // which has already started.
        if (queued.completedCount >= queued.nativeStartCount) {
          return;
        }
        queued.completedCount++;
        if (queued.completedCount < queued.texts.length) {
          _isPlaying = true;
          _isPaused = false;
          _notifySafe();
          return;
        }
        if (identical(_activeQueuedOperation, queued)) {
          _activeQueuedOperation = null;
        }
        _isPlaying = false;
        _isPaused = false;
        _currentPosition = queued.texts.last.length;
        _utteranceBasePosition = 0;
        if (!queued.completion.isCompleted) queued.completion.complete();
        _notifySafe();
        return;
      }
      _isPlaying = false;
      _isPaused = false;
      _currentPosition = 0;
      _utteranceBasePosition = 0;
      _notifySafe();
    });

    tts.setPauseHandler(() {
      _isPlaying = false;
      _isPaused = true;
      _notifySafe();
    });

    tts.setContinueHandler(() {
      _isPlaying = true;
      _isPaused = false;
      _notifySafe();
    });

    tts.setCancelHandler(() {
      _completeQueuedOperation();
      _isPlaying = false;
      _isPaused = false;
      _utteranceBasePosition = 0;
      _notifySafe();
    });

    tts.setProgressHandler((
      String text,
      int startOffset,
      int endOffset,
      String word,
    ) {
      final queued = _activeQueuedOperation;
      if (queued != null) {
        // onStart is the primary sentence boundary signal. Some engines send
        // progress first, so use the progress text as a safe fallback.
        if (queued.lastReportedIndex < 0 || _currentText != text) {
          final startIndex = (queued.lastReportedIndex + 1).clamp(
            0,
            queued.texts.length,
          );
          var matchingIndex = -1;
          for (var index = startIndex; index < queued.texts.length; index++) {
            if (queued.texts[index] == text) {
              matchingIndex = index;
              break;
            }
          }
          if (matchingIndex >= 0) {
            _reportQueuedTextStarted(queued, matchingIndex);
          }
        }
      }
      _currentPosition = (_utteranceBasePosition + startOffset).clamp(
        0,
        _currentText.length,
      );
      _notifySafe();
    });

    tts.setErrorHandler((message) {
      _webStartTimer?.cancel();
      _webStartTimer = null;
      _isPlaying = false;
      _isPaused = false;
      _lastError = message?.toString().trim().isNotEmpty == true
          ? message.toString()
          : 'tts_call_failed';
      _completeQueuedOperation(error: StateError('tts_call_failed'));
      final activeSignal = _activeSpeakSignal;
      if (activeSignal != null && !activeSignal.isCompleted) {
        activeSignal.completeError(StateError('tts_call_failed'));
      }
      _notifySafe();
      debugPrint('TTS 运行错误: $message');
    });
  }

  void _reportQueuedTextStarted(_QueuedTtsOperation queued, int index) {
    if (!identical(_activeQueuedOperation, queued) ||
        index < 0 ||
        index >= queued.texts.length ||
        index <= queued.lastReportedIndex) {
      return;
    }
    queued.lastReportedIndex = index;
    _currentText = queued.texts[index];
    _currentPosition = 0;
    _utteranceBasePosition = 0;
    try {
      queued.onTextStarted(index);
    } catch (error) {
      debugPrint('TTS queue start callback failed: $error');
    }
  }

  Future<void> _refreshAvailableLanguages(FlutterTts tts) async {
    try {
      final result = await tts.getLanguages;
      if (result is Iterable) {
        final unique = <String>{};
        for (final item in result) {
          final value = item.toString().trim();
          if (value.isNotEmpty) {
            unique.add(value);
          }
        }
        _availableLanguages = unique.toList(growable: false)..sort();
      } else {
        _availableLanguages = const <String>[];
      }
    } catch (e) {
      _availableLanguages = const <String>[];
      debugPrint('获取 TTS 语言列表失败: $e');
    }
  }

  Future<void> ensureVoicesLoaded({bool force = false}) async {
    if (_isDisposed) return;

    final online = _online;
    if (online != null) {
      return online.refreshSpeakers();
    }

    if (!force && _availableVoices.isNotEmpty) {
      return;
    }

    final pending = _voiceLoadingFuture;
    if (pending != null) {
      await pending;
      return;
    }

    final completer = Completer<void>();
    _voiceLoadingFuture = completer.future;

    _isLoadingVoices = true;
    _voiceLoadError = null;
    _notifySafe();

    try {
      await initialize();
      final tts = _flutterTts;
      if (!_isInitialized || tts == null) {
        return;
      }

      final voices = await _loadVoicesFromEngine(tts);
      _availableVoices = voices;
      _currentVoice = _syncVoiceWithAvailableList(_currentVoice, voices);
      _voiceLoadError = null;
    } catch (e) {
      _voiceLoadError = _toErrorText(e);
      debugPrint('加载 TTS 音色失败: $e');
    } finally {
      _isLoadingVoices = false;
      _notifySafe();

      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_voiceLoadingFuture, completer.future)) {
        _voiceLoadingFuture = null;
      }
    }
  }

  Future<void> setVoice(TtsVoiceOption voice) async {
    // 在线模式的音色由 setOnlineSpeaker 管理。
    if (_onlineActive) return;
    await initialize();
    final tts = _flutterTts;
    if (!_isInitialized || tts == null) {
      _lastError = _lastError ?? 'tts_unavailable';
      _notifySafe();
      return;
    }

    try {
      _lastError = null;
      _voiceLoadError = null;

      await _applyVoiceToEngine(tts, voice);
      _currentLanguage = voice.normalizedLocale.isNotEmpty
          ? voice.normalizedLocale
          : voice.locale;
      _currentVoice =
          _syncVoiceWithAvailableList(voice, _availableVoices) ?? voice;

      await _saveSettings();
      _notifySafe();
    } catch (e) {
      _lastError = _toErrorText(e);
      _notifySafe();
      debugPrint('设置 TTS 音色失败: $e');
    }
  }

  Future<void> clearSelectedVoice() async {
    if (_onlineActive) return;
    await initialize();
    final tts = _flutterTts;
    if (!_isInitialized || tts == null) {
      _lastError = _lastError ?? 'tts_unavailable';
      _notifySafe();
      return;
    }

    try {
      _lastError = null;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        await tts.clearVoice();
      }
      await _trySetLanguage(tts, _currentLanguage);
      _currentVoice = null;
      await _saveSettings();
      _notifySafe();
    } catch (e) {
      _lastError = _toErrorText(e);
      _notifySafe();
      debugPrint('清除 TTS 音色失败: $e');
    }
  }

  Future<void> _applyBestLanguage(FlutterTts tts) async {
    final locale = PlatformDispatcher.instance.locale;
    final deviceLocaleTag = _localeTag(locale);

    final candidates = <String>[
      _currentLanguage,
      if (deviceLocaleTag.isNotEmpty) deviceLocaleTag,
      if (locale.languageCode.isNotEmpty) locale.languageCode,
      'zh-CN',
      'zh_CN',
      'zh',
      'en-US',
      'en_US',
      'en',
    ];

    final tested = <String>{};
    for (final lang in candidates) {
      final value = lang.trim();
      if (value.isEmpty || !tested.add(value)) continue;
      if (await _trySetLanguage(tts, value)) {
        _currentLanguage = value;
        await _saveSettings();
        return;
      }
    }
  }

  String _localeTag(Locale locale) {
    if (locale.countryCode?.isNotEmpty ?? false) {
      return '${locale.languageCode}-${locale.countryCode}';
    }
    return locale.languageCode;
  }

  Future<bool> _trySetLanguage(FlutterTts tts, String language) async {
    try {
      final available = await tts.isLanguageAvailable(language);
      if (available == false) {
        return false;
      }
    } catch (_) {
      // 某些平台不支持 isLanguageAvailable，直接尝试设置。
    }

    try {
      await tts.setLanguage(language);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _safeSetSpeechRate(FlutterTts tts, double rate) async {
    try {
      await tts.setSpeechRate(_effectivePlatformSpeechRate(rate));
    } catch (e) {
      debugPrint('设置 TTS 语速失败: $e');
    }
  }

  Future<void> _detectAndroidTtsEngine(FlutterTts tts) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      _androidTtsEngine = (await tts.getDefaultEngine)?.toString().trim();
      debugPrint('Android TTS engine: $_androidTtsEngine');
    } catch (error) {
      _androidTtsEngine = null;
      debugPrint('Unable to detect Android TTS engine: $error');
    }
  }

  double _effectivePlatformSpeechRate(double storedRate) {
    final normalized = storedRate.clamp(0.1, 1.0).toDouble();
    if (_androidTtsEngine != _xiaomiTtsEngine) return normalized;

    // Xiaomi's system engine compresses Android's standard speech rate to a
    // small integer range. Expand only the faster half for that engine.
    final multiplier = normalized * 2;
    if (multiplier <= 1) return normalized;
    return (0.5 + (multiplier - 1) * 2.5).clamp(0.1, 3.0).toDouble();
  }

  Future<void> _safeSetVolume(FlutterTts tts, double volume) async {
    try {
      await tts.setVolume(volume.clamp(0.0, 1.0));
    } catch (e) {
      debugPrint('设置 TTS 音量失败: $e');
    }
  }

  Future<void> _safeSetPitch(FlutterTts tts, double pitch) async {
    try {
      await tts.setPitch(pitch.clamp(0.5, 2.0));
    } catch (e) {
      debugPrint('设置 TTS 音调失败: $e');
    }
  }

  Future<void> _applyPlaybackParameters(
    FlutterTts tts, {
    bool logEffectiveRate = false,
  }) async {
    await _safeSetSpeechRate(tts, _speechRate);
    await _safeSetVolume(tts, _speechVolume);
    await _safeSetPitch(tts, _speechPitch);
    if (logEffectiveRate &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      // flutter_tts maps its 0.5 value to Android TextToSpeech's native 1.0.
      debugPrint(
        'Android TTS queue rate: '
        '${(_speechRate * 2).toStringAsFixed(2)}x '
        '(flutter_tts=${_effectivePlatformSpeechRate(_speechRate)}, '
        'engine=${_androidTtsEngine ?? 'unknown'})',
      );
    }
  }

  @override
  Future<void> speak(String text) async {
    final content = text.trim();
    if (content.isEmpty) {
      return;
    }

    final online = _online;
    if (online != null) {
      return online.speak(content);
    }

    await initialize();
    final tts = _flutterTts;
    if (!_isInitialized || tts == null) {
      _lastError = _lastError ?? 'tts_unavailable';
      _notifySafe();
      throw StateError('tts_unavailable');
    }

    final needsNativeStop =
        _isPlaying ||
        _isPaused ||
        _activeSpeakSignal != null ||
        _activeQueuedOperation != null;
    _speakCancellationVersion++;
    final cancellationVersion = _speakCancellationVersion;
    _completeActiveSpeakWait();
    _completeQueuedOperation();
    Completer<void>? activeSignal;
    try {
      if (needsNativeStop) {
        await tts.stop();
      }
      // A queued operation can still be switching awaitSpeakCompletion(false)
      // before it installs its native callback counters. Serializing this
      // restore prevents a replacement single utterance from returning early.
      await _restoreDefaultSpeakMode(tts);
      if (cancellationVersion != _speakCancellationVersion) return;

      final speakSignal = Completer<void>();
      activeSignal = speakSignal;
      _activeSpeakSignal = speakSignal;
      _currentText = content;
      _currentPosition = 0;
      _utteranceBasePosition = 0;
      _lastError = null;
      _notifySafe();

      await _applyCurrentVoiceIfNeeded(tts);
      await _applyPlaybackParameters(tts);
      if (kIsWeb) {
        _webStartTimer?.cancel();
        _webStartTimer = Timer(const Duration(seconds: 6), () {
          if (identical(_activeSpeakSignal, speakSignal) &&
              !_isPlaying &&
              !speakSignal.isCompleted) {
            speakSignal.completeError(
              StateError('浏览器系统语音没有开始播放；请检查标签页是否静音和系统语音是否可用。'),
            );
          }
        });
      }
      // The web implementation of flutter_tts returns 0 after a cancelled
      // utterance even though SpeechSynthesis has accepted the replacement.
      // Its start/error callbacks are the authoritative playback signal.
      // On native platforms preserve the plugin return-value check.
      final result = await Future.any<dynamic>([
        _speakWithAudioFocus(tts, content),
        activeSignal.future,
      ]);
      if (cancellationVersion != _speakCancellationVersion) return;
      if (!kIsWeb && (result == 0 || result == false)) {
        throw StateError('tts_call_failed');
      }
    } catch (e, stackTrace) {
      if (activeSignal?.isCompleted == false) {
        activeSignal?.complete();
      }
      if (cancellationVersion != _speakCancellationVersion) return;
      _isPlaying = false;
      _isPaused = false;
      _lastError =
          e is StateError &&
              (e.message == 'tts_unavailable' || e.message == 'tts_call_failed')
          ? e.message
          : _toErrorText(e);
      _notifySafe();
      debugPrint('TTS 播放失败: $e');
      Error.throwWithStackTrace(e, stackTrace);
    } finally {
      _webStartTimer?.cancel();
      _webStartTimer = null;
      if (identical(_activeSpeakSignal, activeSignal)) {
        _activeSpeakSignal = null;
      }
    }
  }

  @override
  Future<void> speakQueued(
    List<String> texts, {
    required ValueChanged<int> onTextStarted,
  }) async {
    final contents = texts
        .map((text) => text.trim())
        .where((text) => text.isNotEmpty)
        .toList(growable: false);
    if (contents.isEmpty) return;

    final online = _online;
    if (online != null) {
      return online.speakQueued(contents, onTextStarted: onTextStarted);
    }

    await initialize();
    final tts = _flutterTts;
    if (!_isInitialized || tts == null || !supportsQueuedText) {
      throw StateError('tts_unavailable');
    }

    final needsNativeStop =
        _isPlaying ||
        _isPaused ||
        _activeSpeakSignal != null ||
        _activeQueuedOperation != null;
    _speakCancellationVersion++;
    final operationVersion = _speakCancellationVersion;
    _completeActiveSpeakWait();
    _completeQueuedOperation();
    try {
      if (needsNativeStop) {
        await tts.stop();
        // Let a delayed cancel/completion from the old native queue cross the
        // method channel before installing the new FIFO counters.
        await Future<void>.delayed(Duration.zero);
      }
      await _applyCurrentVoiceIfNeeded(tts);
      await _applyPlaybackParameters(tts, logEffectiveRate: true);
      final enteredQueueMode = await _enterQueuedSpeakMode(
        tts,
        operationVersion,
      );
      if (!enteredQueueMode) return;

      final queued = _QueuedTtsOperation(
        texts: contents,
        onTextStarted: onTextStarted,
      );
      _activeQueuedOperation = queued;
      _currentText = contents.first;
      _currentPosition = 0;
      _utteranceBasePosition = 0;
      _isPlaying = true;
      _isPaused = false;
      _lastError = null;
      _notifySafe();

      for (var index = 0; index < contents.length; index++) {
        if (!identical(_activeQueuedOperation, queued) ||
            operationVersion != _speakCancellationVersion) {
          return;
        }
        final result = await _speakQueuedText(
          tts,
          contents[index],
          requestAudioFocus: index == 0,
        );
        if (result == 0 || result == false) {
          throw StateError('tts_call_failed');
        }
      }
      await queued.completion.future;
      final queuedError = queued.error;
      if (queuedError != null) throw queuedError;
    } catch (error, stackTrace) {
      if (operationVersion != _speakCancellationVersion) return;
      _completeQueuedOperation();
      _isPlaying = false;
      _isPaused = false;
      _lastError = error is StateError ? error.message : _toErrorText(error);
      _notifySafe();
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (operationVersion == _speakCancellationVersion) {
        await _restoreDefaultSpeakMode(tts);
      }
    }
  }

  @override
  Future<void> pause() async {
    final online = _online;
    if (online != null) {
      return online.pause();
    }
    final tts = _flutterTts;
    if (!_isInitialized || tts == null || !_isPlaying || _isPaused) {
      return;
    }

    try {
      _speakCancellationVersion++;
      _completeActiveSpeakWait();
      final wasQueued = _activeQueuedOperation != null;
      _completeQueuedOperation();
      if (wasQueued) {
        // flutter_tts pause only remembers one utterance and cannot preserve
        // the remaining native queue. The controller has already saved the
        // current sentence offset, so stop and rebuild the queue on resume.
        await tts.stop();
        await _restoreDefaultSpeakMode(tts);
      } else {
        await tts.pause();
      }
      _isPlaying = false;
      _isPaused = true;
      _notifySafe();
    } catch (e, stackTrace) {
      _lastError = _toErrorText(e);
      _notifySafe();
      debugPrint('TTS 暂停失败: $e');
      Error.throwWithStackTrace(e, stackTrace);
    }
  }

  Future<void> resume() async {
    final online = _online;
    if (online != null) {
      return online.resume();
    }
    final tts = _flutterTts;
    if (!_isInitialized || tts == null || !_isPaused) {
      return;
    }

    try {
      final fallbackText = _currentText;
      final startIndex = _currentPosition.clamp(0, fallbackText.length);
      final remainingText = startIndex < fallbackText.length
          ? fallbackText.substring(startIndex)
          : '';
      _utteranceBasePosition = startIndex;
      await _applyCurrentVoiceIfNeeded(tts);
      await _applyPlaybackParameters(tts);
      await _speakWithAudioFocus(
        tts,
        remainingText.isEmpty ? fallbackText : remainingText,
      );
    } catch (e) {
      _lastError = _toErrorText(e);
      _notifySafe();
      debugPrint('TTS 继续播放失败: $e');
    }
  }

  @override
  Future<void> stop() async {
    _webStartTimer?.cancel();
    _webStartTimer = null;
    final online = _online;
    if (online != null) {
      return online.stop();
    }
    final tts = _flutterTts;
    if (tts == null) {
      return;
    }

    try {
      _speakCancellationVersion++;
      _completeActiveSpeakWait();
      _completeQueuedOperation();
      await tts.stop();
      await _restoreDefaultSpeakMode(tts);
    } catch (e) {
      _lastError = _toErrorText(e);
      debugPrint('TTS 停止失败: $e');
    } finally {
      _isPlaying = false;
      _isPaused = false;
      _currentPosition = 0;
      _utteranceBasePosition = 0;
      _notifySafe();
    }
  }

  Future<void> setSpeechRate(double rate) async {
    final online = _online;
    if (online != null) {
      return online.setSpeechRate(rate);
    }
    _speechRate = rate.clamp(0.1, 1.0);
    final tts = _flutterTts;
    if (tts != null) {
      await _safeSetSpeechRate(tts, _speechRate);
    }
    await _saveSettings();
    _notifySafe();
  }

  Future<void> setVolume(double volume) async {
    final online = _online;
    if (online != null) {
      return online.setVolume(volume);
    }
    _speechVolume = volume.clamp(0.0, 1.0);
    final tts = _flutterTts;
    if (tts != null) {
      await _safeSetVolume(tts, _speechVolume);
    }
    await _saveSettings();
    _notifySafe();
  }

  Future<void> setPitch(double pitch) async {
    // 在线 TTS 服务不暴露音调参数，仅系统模式生效。
    if (_onlineActive) return;
    _speechPitch = pitch.clamp(0.5, 2.0);
    final tts = _flutterTts;
    if (tts != null) {
      await _safeSetPitch(tts, _speechPitch);
    }
    await _saveSettings();
    _notifySafe();
  }

  Future<dynamic> _speakWithAudioFocus(FlutterTts tts, String text) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return tts.speak(text, focus: true);
    }
    return tts.speak(text);
  }

  Future<dynamic> _speakQueuedText(
    FlutterTts tts,
    String text, {
    required bool requestAudioFocus,
  }) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return tts.speak(text, focus: requestAudioFocus);
    }
    return tts.speak(text);
  }

  void _completeActiveSpeakWait() {
    final active = _activeSpeakSignal;
    if (active != null && !active.isCompleted) active.complete();
  }

  void _completeQueuedOperation({Object? error}) {
    final queued = _activeQueuedOperation;
    _activeQueuedOperation = null;
    if (queued == null || queued.completion.isCompleted) return;
    queued.error = error;
    queued.completion.complete();
  }

  Future<T> _withSpeakModeTransition<T>(Future<T> Function() operation) async {
    final previous = _speakModeTransition;
    final release = Completer<void>();
    _speakModeTransition = release.future;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }

  Future<bool> _enterQueuedSpeakMode(FlutterTts tts, int operationVersion) {
    return _withSpeakModeTransition(() async {
      if (operationVersion != _speakCancellationVersion) return false;

      await tts.awaitSpeakCompletion(false);
      if (operationVersion != _speakCancellationVersion) {
        await _restoreDefaultSpeakModeUnlocked(tts);
        return false;
      }

      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        // QUEUE_ADD is Android-only. AVSpeechSynthesizer already preserves
        // FIFO order when several speak calls are submitted without awaiting
        // each utterance's completion.
        await tts.setQueueMode(1);
        if (operationVersion != _speakCancellationVersion) {
          await _restoreDefaultSpeakModeUnlocked(tts);
          return false;
        }
      }
      return true;
    });
  }

  Future<void> _restoreDefaultSpeakMode(FlutterTts tts) {
    return _withSpeakModeTransition(
      () => _restoreDefaultSpeakModeUnlocked(tts),
    );
  }

  Future<void> _restoreDefaultSpeakModeUnlocked(FlutterTts tts) async {
    if (kIsWeb) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      await tts.setQueueMode(0);
    } else if (defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    await tts.awaitSpeakCompletion(true);
  }

  Future<void> _disposeNativeTts(FlutterTts tts) async {
    try {
      await tts.stop();
      await _restoreDefaultSpeakMode(tts);
    } catch (error) {
      debugPrint('TTS dispose failed: $error');
    }
  }

  Future<void> setLanguage(String language) async {
    final normalized = language.trim();
    if (normalized.isEmpty) {
      return;
    }
    if (_onlineActive) return;

    _currentLanguage = normalized;
    await _saveSettings();

    final tts = _flutterTts;
    if (!_isInitialized || tts == null) {
      return;
    }

    final success = await _trySetLanguage(tts, normalized);
    if (!success) {
      _lastError = 'tts_unsupported_language';
      _lastErrorLanguage = normalized;
    } else {
      if (_currentVoice != null &&
          !_currentVoice!.matchesLanguage(normalized)) {
        _currentVoice = null;
        await _saveSettings();
      }
      _lastError = null;
      _lastErrorLanguage = null;
    }
    _notifySafe();
  }

  double get playbackProgress {
    if (_currentText.isEmpty) return 0.0;
    return (_currentPosition / _currentText.length).clamp(0.0, 1.0);
  }

  Future<bool> isLanguageAvailable(String language) async {
    final tts = _flutterTts;
    if (!_isInitialized || tts == null) {
      return false;
    }

    try {
      final result = await tts.isLanguageAvailable(language);
      return result ?? false;
    } catch (e) {
      debugPrint('检查语言可用性失败: $e');
      return false;
    }
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _onlineEnabled = prefs.getBool('tts_online_enabled') ?? false;
      if (_onlineEnabled && _onlineEngine == null) {
        _attachOnlineEngine();
      }
      _speechRate =
          (prefs.getDouble('tts_speech_rate') ??
                  prefs.getDouble('ttsSpeed') ??
                  0.5)
              .clamp(0.1, 1.0);
      _speechVolume =
          (prefs.getDouble('tts_speech_volume') ??
                  prefs.getDouble('ttsVolume') ??
                  1.0)
              .clamp(0.0, 1.0);
      _speechPitch =
          (prefs.getDouble('tts_speech_pitch') ??
                  prefs.getDouble('ttsPitch') ??
                  1.0)
              .clamp(0.5, 2.0);
      _currentLanguage = prefs.getString('tts_language') ?? 'zh-CN';
      final savedIdentifier = prefs.getString(_voiceIdentifierPrefKey)?.trim();
      final savedName = prefs.getString(_voiceNamePrefKey)?.trim() ?? '';
      final savedLocale =
          (prefs.getString(_voiceLocalePrefKey) ?? _currentLanguage).trim();
      if ((savedIdentifier?.isNotEmpty ?? false) ||
          savedName.isNotEmpty ||
          savedLocale.isNotEmpty) {
        _currentVoice = TtsVoiceOption(
          name: savedName,
          locale: savedLocale,
          identifier: savedIdentifier,
        );
      } else {
        _currentVoice = null;
      }
    } catch (e) {
      debugPrint('加载 TTS 设置失败: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('tts_online_enabled', _onlineEnabled);
      await prefs.setDouble('tts_speech_rate', _speechRate);
      await prefs.setDouble('tts_speech_volume', _speechVolume);
      await prefs.setDouble('tts_speech_pitch', _speechPitch);
      await prefs.setString('tts_language', _currentLanguage);

      // 兼容设置页旧键名，确保两处入口数据一致。
      await prefs.setDouble('ttsSpeed', _speechRate);
      await prefs.setDouble('ttsVolume', _speechVolume);
      await prefs.setDouble('ttsPitch', _speechPitch);

      final voice = _currentVoice;
      if (voice == null) {
        await prefs.remove(_voiceIdPrefKey);
        await prefs.remove(_voiceIdentifierPrefKey);
        await prefs.remove(_voiceNamePrefKey);
        await prefs.remove(_voiceLocalePrefKey);
      } else {
        await prefs.setString(_voiceIdPrefKey, voice.id);
        await prefs.setString(_voiceNamePrefKey, voice.name);
        await prefs.setString(
          _voiceLocalePrefKey,
          voice.normalizedLocale.isNotEmpty
              ? voice.normalizedLocale
              : _currentLanguage,
        );
        final identifier = voice.identifier?.trim();
        if (identifier != null && identifier.isNotEmpty) {
          await prefs.setString(_voiceIdentifierPrefKey, identifier);
        } else {
          await prefs.remove(_voiceIdentifierPrefKey);
        }
      }
    } catch (e) {
      debugPrint('保存 TTS 设置失败: $e');
    }
  }

  Future<void> _restoreSavedVoice(FlutterTts tts) async {
    final savedVoice = _currentVoice;
    if (savedVoice == null) {
      return;
    }

    try {
      await _applyVoiceToEngine(tts, savedVoice);
      _currentLanguage = savedVoice.normalizedLocale.isNotEmpty
          ? savedVoice.normalizedLocale
          : _currentLanguage;
    } catch (e) {
      debugPrint('恢复 TTS 音色失败: $e');
      _currentVoice = null;
    }
  }

  Future<void> _applyCurrentVoiceIfNeeded(FlutterTts tts) async {
    final voice = _currentVoice;
    if (voice != null) {
      await _applyVoiceToEngine(tts, voice);
      return;
    }
    if (_currentLanguage.trim().isNotEmpty) {
      await _trySetLanguage(tts, _currentLanguage);
    }
  }

  Future<void> _applyVoiceToEngine(FlutterTts tts, TtsVoiceOption voice) async {
    final locale = voice.normalizedLocale.isNotEmpty
        ? voice.normalizedLocale
        : _currentLanguage;
    if (locale.isNotEmpty) {
      await _trySetLanguage(tts, locale);
    }

    final identifier = voice.identifier?.trim();
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        identifier != null &&
        identifier.isNotEmpty) {
      await tts.setVoice(<String, String>{'identifier': identifier});
      return;
    }

    final payload = <String, String>{};
    final name = voice.name.trim();
    if (name.isNotEmpty) {
      payload['name'] = name;
    }
    if (locale.isNotEmpty) {
      payload['locale'] = locale;
    }
    if (payload.isNotEmpty) {
      await tts.setVoice(payload);
    }
  }

  Future<List<TtsVoiceOption>> _loadVoicesFromEngine(FlutterTts tts) async {
    final raw = await tts.getVoices;
    if (raw is! Iterable) {
      return const <TtsVoiceOption>[];
    }

    final deduped = <String, TtsVoiceOption>{};
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final voice = TtsVoiceOption.fromMap(item);
      if (voice.name.trim().isEmpty && voice.locale.trim().isEmpty) {
        continue;
      }

      final existing = deduped[voice.id];
      if (existing == null || _compareVoicePriority(voice, existing) < 0) {
        deduped[voice.id] = voice;
      }
    }

    final voices = deduped.values.toList(growable: false);
    voices.sort(_compareVoicePriority);
    return voices;
  }

  TtsVoiceOption? _syncVoiceWithAvailableList(
    TtsVoiceOption? current,
    List<TtsVoiceOption> voices,
  ) {
    if (current == null) {
      return null;
    }

    for (final voice in voices) {
      if (voice == current) {
        return voice;
      }
    }

    for (final voice in voices) {
      if (voice.name == current.name &&
          voice.normalizedLocale == current.normalizedLocale) {
        return voice;
      }
    }

    return current;
  }

  int _compareVoicePriority(TtsVoiceOption left, TtsVoiceOption right) {
    final languageScoreDiff = _languageMatchScore(
      left,
    ).compareTo(_languageMatchScore(right));
    if (languageScoreDiff != 0) {
      return languageScoreDiff;
    }

    final qualityDiff = _voiceQualityRank(
      left.quality,
    ).compareTo(_voiceQualityRank(right.quality));
    if (qualityDiff != 0) {
      return qualityDiff;
    }

    final localeDiff = left.normalizedLocale.toLowerCase().compareTo(
      right.normalizedLocale.toLowerCase(),
    );
    if (localeDiff != 0) {
      return localeDiff;
    }

    return left.title.toLowerCase().compareTo(right.title.toLowerCase());
  }

  int _languageMatchScore(TtsVoiceOption voice) {
    if (voice.matchesLocale(_currentLanguage)) {
      return 0;
    }
    if (voice.matchesLanguage(_currentLanguage)) {
      return 1;
    }
    return 2;
  }

  int _voiceQualityRank(String? quality) {
    switch (quality?.trim().toLowerCase()) {
      case 'premium':
        return 0;
      case 'enhanced':
        return 1;
      case 'default':
        return 2;
      default:
        return 3;
    }
  }

  String _toErrorText(Object error) {
    final raw = error.toString().trim();
    if (raw.isEmpty) return 'tts_call_failed';
    return raw.length > 220 ? raw.substring(0, 220) : raw;
  }

  void _notifySafe() {
    if (_isDisposed) return;
    notifyListeners();
  }

  /// 在线引擎状态变化转发给本服务的监听者（UI 同时监听 TtsService）。
  void _relayChange() => _notifySafe();

  @override
  void dispose() {
    _isDisposed = true;
    _speakCancellationVersion++;
    _webStartTimer?.cancel();
    _completeActiveSpeakWait();
    _completeQueuedOperation();
    final tts = _flutterTts;
    _flutterTts = null;
    _initializationFuture = null;
    if (tts != null) {
      unawaited(_disposeNativeTts(tts));
    }
    final online = _onlineEngine;
    _onlineEngine = null;
    if (online != null) {
      online.removeListener(_relayChange);
      online.dispose();
    }
    super.dispose();
  }
}
