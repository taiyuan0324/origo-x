// 文件说明：在线 TTS 引擎，接入自建豆包 TTS 服务（/tts 合成 + /speakers 音色）。
// 技术要点：在线语音合成、just_audio 播放、SharedPreferences、渲染层、Flutter。
// 设计要点：HTTP/播放器/文件存储均为可注入抽象，核心队列逻辑可单测。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/reader/reader_aloud_controller.dart';

/// 在线音色项。[name] 既是展示名，也是 /tts 接口的 speaker 参数值。
class OnlineSpeaker {
  const OnlineSpeaker({required this.name, required this.category});

  final String name;
  final String category;

  String get categoryLabel => switch (category) {
    'female' => '女声',
    'male' => '男声',
    'special' => '特色',
    _ => '其他',
  };

  @override
  bool operator ==(Object other) =>
      other is OnlineSpeaker &&
      other.name == name &&
      other.category == category;

  @override
  int get hashCode => Object.hash(name, category);
}

/// 服务端 /speakers 不可达时的内置音色表（与接口文档 1.1.0 对齐）。
const List<OnlineSpeaker> kBuiltinOnlineSpeakers = <OnlineSpeaker>[
  OnlineSpeaker(name: '温柔桃子', category: 'female'),
  OnlineSpeaker(name: '温柔桃子经典', category: 'female'),
  OnlineSpeaker(name: '知性小棠', category: 'female'),
  OnlineSpeaker(name: '阳光甜妹', category: 'female'),
  OnlineSpeaker(name: '邻家女孩', category: 'female'),
  OnlineSpeaker(name: '魅力苏菲', category: 'female'),
  OnlineSpeaker(name: '撒娇学妹', category: 'female'),
  OnlineSpeaker(name: '文静毛毛', category: 'female'),
  OnlineSpeaker(name: '北京大妞', category: 'female'),
  OnlineSpeaker(name: '清甜瑶瑶', category: 'female'),
  OnlineSpeaker(name: '活泼可昕', category: 'female'),
  OnlineSpeaker(name: '甜美小雪', category: 'female'),
  OnlineSpeaker(name: '清冷阿梦', category: 'female'),
  OnlineSpeaker(name: '磁性俊宇', category: 'male'),
  OnlineSpeaker(name: '邻家男孩', category: 'male'),
  OnlineSpeaker(name: '悠悠君子', category: 'male'),
  OnlineSpeaker(name: '温暖阿虎', category: 'male'),
  OnlineSpeaker(name: '少年梓辛', category: 'male'),
  OnlineSpeaker(name: '阳光阿辰', category: 'male'),
  OnlineSpeaker(name: '傲娇霸总', category: 'male'),
  OnlineSpeaker(name: '温柔子言', category: 'male'),
  OnlineSpeaker(name: '率性阿哲', category: 'male'),
  OnlineSpeaker(name: '深夜播客', category: 'male'),
  OnlineSpeaker(name: '东方浩然', category: 'male'),
  OnlineSpeaker(name: '清爽男大', category: 'male'),
  OnlineSpeaker(name: '渊博小叔', category: 'male'),
  OnlineSpeaker(name: '腹黑霸总', category: 'special'),
  OnlineSpeaker(name: '冷酷霸总', category: 'special'),
  OnlineSpeaker(name: '霸道总裁', category: 'special'),
  OnlineSpeaker(name: '温柔陆辰', category: 'special'),
  OnlineSpeaker(name: '病娇少爷', category: 'special'),
  OnlineSpeaker(name: '清朗宇澄', category: 'special'),
  OnlineSpeaker(name: '奶音俊少', category: 'special'),
  OnlineSpeaker(name: '沉稳皓轩', category: 'special'),
  OnlineSpeaker(name: '温柔俊彦', category: 'special'),
  OnlineSpeaker(name: '青涩沐阳', category: 'special'),
  OnlineSpeaker(name: '睿语舟舟', category: 'special'),
  OnlineSpeaker(name: '随性先生', category: 'special'),
  OnlineSpeaker(name: '俊朗男友', category: 'special'),
  OnlineSpeaker(name: '奶酷小宇', category: 'special'),
  OnlineSpeaker(name: '暖阳阿晨', category: 'special'),
  OnlineSpeaker(name: '低音小北', category: 'special'),
  OnlineSpeaker(name: '男闺蜜俊熙', category: 'special'),
  OnlineSpeaker(name: '深情霸总', category: 'special'),
];

/// 服务内部 60s 硬超时，客户端留出余量。
const Duration _kRequestTimeout = Duration(seconds: 90);

/// HTTP 客户端抽象（默认 dart:io 实现，测试可注入假实现）。
abstract class OnlineTtsHttpClient {
  /// POST /tts，返回 AAC 音频字节。
  Future<Uint8List> postTts(
    String serverUrl, {
    required String text,
    required String speaker,
  });

  /// GET JSON 接口（/status、/speakers）。
  Future<Map<String, Object?>> getJson(String serverUrl, String path);
}

/// 播放器抽象（默认 just_audio 实现，测试可注入假实现）。
abstract class OnlineTtsPlayer {
  Future<void> open(
    String filePath, {
    required double volume,
    required double speed,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();

  /// 播放自然结束（一段音频播完）时发出事件。
  Stream<void> get completionStream;

  Future<void> dispose();
}

/// 临时音频文件存储抽象（默认系统临时目录，测试可注入内存实现）。
abstract class OnlineTtsFileStore {
  Future<String> writeAudio(Uint8List bytes);
  void delete(String path);
}

class _IoOnlineTtsHttpClient implements OnlineTtsHttpClient {
  const _IoOnlineTtsHttpClient(this._client);

  final HttpClient _client;

  @override
  Future<Uint8List> postTts(
    String serverUrl, {
    required String text,
    required String speaker,
  }) async {
    final request = await _client
        .postUrl(Uri.parse('$serverUrl/tts'))
        .timeout(_kRequestTimeout);
    request.headers.contentType = ContentType.json;
    request.headers.set('Accept', 'audio/aac');
    request.write(
      jsonEncode(<String, Object?>{'text': text, 'speaker': speaker}),
    );
    final response = await request.close().timeout(_kRequestTimeout);
    if (response.statusCode != 200) {
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_kRequestTimeout);
      throw StateError(
        'online_tts_http_${response.statusCode}'
        '${body.trim().isEmpty ? '' : ': ${body.trim()}'}',
      );
    }
    final bytes = await response
        .fold<BytesBuilder>(BytesBuilder(copy: false), (builder, chunk) {
          builder.add(chunk);
          return builder;
        })
        .then((builder) => builder.takeBytes())
        .timeout(_kRequestTimeout);
    if (bytes.isEmpty) {
      throw StateError('online_tts_empty_audio');
    }
    return bytes;
  }

  @override
  Future<Map<String, Object?>> getJson(String serverUrl, String path) async {
    final request = await _client
        .getUrl(Uri.parse('$serverUrl$path'))
        .timeout(_kRequestTimeout);
    final response = await request.close().timeout(_kRequestTimeout);
    if (response.statusCode != 200) {
      throw StateError('online_tts_http_${response.statusCode}');
    }
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(_kRequestTimeout);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw StateError('online_tts_bad_payload');
    }
    return decoded;
  }
}

class _JustAudioOnlineTtsPlayer implements OnlineTtsPlayer {
  _JustAudioOnlineTtsPlayer(this._player);

  final AudioPlayer _player;

  @override
  Future<void> open(
    String filePath, {
    required double volume,
    required double speed,
  }) async {
    await _player.setFilePath(filePath);
    try {
      await _player.setVolume(volume);
      await _player.setSpeed(speed);
    } catch (e) {
      debugPrint('应用在线 TTS 播放参数失败: $e');
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.play();

  @override
  Future<void> stop() => _player.stop();

  @override
  Stream<void> get completionStream => _player.playerStateStream
      .where((state) => state.processingState == ProcessingState.completed)
      .map((_) {});

  @override
  Future<void> dispose() => _player.dispose();
}

class _TemporaryFileStore implements OnlineTtsFileStore {
  const _TemporaryFileStore();

  @override
  Future<String> writeAudio(Uint8List bytes) async {
    // 使用 dart:io 系统临时目录，避免依赖平台插件注册表。
    final file = File(
      '${Directory.systemTemp.path}/online_tts_'
      '${DateTime.now().microsecondsSinceEpoch}.aac',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  void delete(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {
      // 临时文件清理失败不影响朗读。
    }
  }
}

/// 在线 TTS 引擎：向自建豆包 TTS 服务逐段合成 AAC 并播放。
///
/// 与系统 TTS 的差异：
/// - 服务单请求内部 60s 超时，逐段串行合成（控制器每段 ≤320 字）；
/// - 服务为单页串行排队，客户端天然逐段请求，无需并发控制；
/// - 服务不暴露语速/音调，语速在本地映射为播放倍速。
class OnlineTtsEngine extends ChangeNotifier
    implements
        ReaderAloudAdjustableEngine,
        ReaderAloudContinuousEngine,
        ReaderAloudQueuedEngine {
  OnlineTtsEngine({
    OnlineTtsHttpClient Function()? httpClientFactory,
    OnlineTtsPlayer Function()? playerFactory,
    OnlineTtsFileStore Function()? fileStoreFactory,
  }) : _httpClientFactory =
           httpClientFactory ?? (() => _IoOnlineTtsHttpClient(HttpClient())),
       _playerFactory =
           playerFactory ?? (() => _JustAudioOnlineTtsPlayer(AudioPlayer())),
       _fileStoreFactory =
           fileStoreFactory ?? (() => const _TemporaryFileStore()) {
    _settingsFuture = _loadSettings();
  }

  static const String _serverUrlKey = 'tts_online_server_url';
  static const String _speakerKey = 'tts_online_speaker';
  static const String _enabledKey = 'tts_online_enabled';

  final OnlineTtsHttpClient Function() _httpClientFactory;
  final OnlineTtsPlayer Function() _playerFactory;
  final OnlineTtsFileStore Function() _fileStoreFactory;
  OnlineTtsHttpClient? _httpClient;
  OnlineTtsPlayer? _player;
  OnlineTtsFileStore? _fileStore;
  late Future<void> _settingsFuture;

  String _serverUrl = 'http://192.168.1.74:3456';
  String _speaker = '温柔桃子';
  bool _enabled = false;

  bool _isPlaying = false;
  bool _isPaused = false;
  bool _isSynthesizing = false;
  int _currentPosition = 0;
  String _currentText = '';
  double _speechRate = 0.5;
  double _speechVolume = 1.0;
  String? _lastError;

  List<OnlineSpeaker> _speakers = kBuiltinOnlineSpeakers;
  bool _loadingSpeakers = false;
  String? _speakerLoadError;

  int _generation = 0;
  Completer<void>? _playbackCompletion;
  String? _activeFilePath;
  bool _isDisposed = false;

  /// 设置加载完成（构造后异步读取 SharedPreferences）。
  Future<void> get whenReady => _settingsFuture;

  @override
  bool get isPlaying => _isPlaying;

  @override
  bool get isPaused => _isPaused;

  bool get isSynthesizing => _isSynthesizing;

  @override
  int get currentPosition => _currentPosition;

  String get currentText => _currentText;

  @override
  bool get supportsContinuousText => false;

  @override
  bool get supportsQueuedText => true;

  @override
  double get speechRate => _speechRate;

  @override
  double get speechVolume => _speechVolume;

  String? get lastError => _lastError;

  bool get enabled => _enabled;

  String get serverUrl => _serverUrl;

  String get speaker => _speaker;

  List<OnlineSpeaker> get speakers => _speakers;

  bool get isLoadingSpeakers => _loadingSpeakers;

  String? get speakerLoadError => _speakerLoadError;

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString(_serverUrlKey)?.trim();
      final savedSpeaker = prefs.getString(_speakerKey)?.trim();
      final savedEnabled = prefs.getBool(_enabledKey);
      _serverUrl = (savedUrl == null || savedUrl.isEmpty)
          ? 'http://192.168.1.74:3456'
          : savedUrl;
      _speaker = (savedSpeaker == null || savedSpeaker.isEmpty)
          ? '温柔桃子'
          : savedSpeaker;
      _enabled = savedEnabled ?? false;
      _notifySafe();
    } catch (e) {
      debugPrint('加载在线 TTS 设置失败: $e');
    }
  }

  Future<void> setServerUrl(String url) async {
    final normalized = _normalizeServerUrl(url);
    if (_serverUrl == normalized) return;
    _serverUrl = normalized;
    await _persist();
    _notifySafe();
  }

  Future<void> setSpeaker(String speaker) async {
    final normalized = speaker.trim();
    if (normalized.isEmpty || _speaker == normalized) return;
    _speaker = normalized;
    await _persist();
    _notifySafe();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    await _persist();
    if (!value) {
      await stop();
    }
    _notifySafe();
  }

  Future<void> setSpeechRate(double rate) async {
    final normalized = rate.clamp(0.1, 1.0).toDouble();
    if (_speechRate == normalized) return;
    _speechRate = normalized;
    _notifySafe();
  }

  Future<void> setVolume(double volume) async {
    final normalized = volume.clamp(0.0, 1.0).toDouble();
    if (_speechVolume == normalized) return;
    _speechVolume = normalized;
    _notifySafe();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_serverUrlKey, _serverUrl);
      await prefs.setString(_speakerKey, _speaker);
      await prefs.setBool(_enabledKey, _enabled);
    } catch (e) {
      debugPrint('保存在线 TTS 设置失败: $e');
    }
  }

  static String _normalizeServerUrl(String raw) {
    var value = raw.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.isEmpty) {
      return 'http://192.168.1.74:3456';
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    return value;
  }

  /// 连接测试：检查 /status 就绪状态并拉取音色。返回 null 表示成功。
  Future<String?> testConnection() async {
    try {
      final status = await _getJson('/status');
      if (status['ready'] == false) {
        return '服务未就绪：浏览器未登录或豆包 Cookie 已失效';
      }
      await refreshSpeakers();
      return null;
    } catch (e) {
      return _toErrorText(e);
    }
  }

  Future<Map<String, Object?>> _getJson(String path) async {
    final client = _httpClient ??= _httpClientFactory();
    return client.getJson(_serverUrl, path);
  }

  Future<void> refreshSpeakers() async {
    if (_loadingSpeakers) return;
    _loadingSpeakers = true;
    _speakerLoadError = null;
    _notifySafe();
    try {
      final payload = await _getJson('/speakers');
      final speakers = _parseSpeakers(payload);
      if (speakers.isNotEmpty) {
        _speakers = speakers;
      }
      _speakerLoadError = null;
    } catch (e) {
      _speakerLoadError = _toErrorText(e);
      debugPrint('拉取在线音色失败: $e');
    } finally {
      _loadingSpeakers = false;
      _notifySafe();
    }
  }

  List<OnlineSpeaker> _parseSpeakers(Map<String, Object?> payload) {
    final byCategory = payload['byCategory'];
    if (byCategory is! Map) return const <OnlineSpeaker>[];
    final speakers = <OnlineSpeaker>[];
    for (final entry in byCategory.entries) {
      final names = entry.value;
      if (names is! List) continue;
      for (final name in names) {
        final text = name.toString().trim();
        if (text.isNotEmpty) {
          speakers.add(
            OnlineSpeaker(name: text, category: entry.key.toString()),
          );
        }
      }
    }
    return speakers;
  }

  @override
  Future<void> speak(String text) async {
    final content = text.trim();
    if (content.isEmpty) return;
    await speakQueued(<String>[content], onTextStarted: (_) {});
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

    await _cancelPlayback();
    final generation = ++_generation;
    _isPlaying = true;
    _isPaused = false;
    _lastError = null;
    _notifySafe();

    for (var index = 0; index < contents.length; index++) {
      if (generation != _generation || _isDisposed) return;
      String? filePath;
      try {
        _isSynthesizing = true;
        _notifySafe();
        filePath = await _synthesizeToFile(contents[index], generation);
        if (generation != _generation || _isDisposed) {
          _deleteFileQuietly(filePath);
          return;
        }
        _isSynthesizing = false;
        _currentText = contents[index];
        _currentPosition = 0;
        onTextStarted(index);
        await _playToCompletion(filePath, generation);
        _deleteFileQuietly(filePath);
        filePath = null;
        if (generation != _generation || _isDisposed) return;
      } catch (error, stackTrace) {
        _isSynthesizing = false;
        if (filePath != null) {
          _deleteFileQuietly(filePath);
        }
        if (generation != _generation || _isDisposed) return;
        _isPlaying = false;
        _isPaused = false;
        _lastError = _toErrorText(error);
        _notifySafe();
        debugPrint('在线 TTS 播放失败: $error');
        Error.throwWithStackTrace(error, stackTrace);
      }
    }

    if (generation != _generation || _isDisposed) return;
    _isPlaying = false;
    _isPaused = false;
    _currentPosition = 0;
    _notifySafe();
  }

  @override
  Future<void> pause() async {
    if (!_isPlaying || _isPaused) return;
    try {
      await _player?.pause();
    } catch (e) {
      debugPrint('在线 TTS 暂停失败: $e');
    }
    _isPlaying = false;
    _isPaused = true;
    _notifySafe();
  }

  Future<void> resume() async {
    if (!_isPaused) return;
    try {
      await _player?.resume();
    } catch (e) {
      debugPrint('在线 TTS 继续播放失败: $e');
    }
    _isPlaying = true;
    _isPaused = false;
    _notifySafe();
  }

  @override
  Future<void> stop() async {
    await _cancelPlayback();
    _isPlaying = false;
    _isPaused = false;
    _currentPosition = 0;
    _currentText = '';
    _notifySafe();
  }

  Future<void> _cancelPlayback() async {
    _generation++;
    final completion = _playbackCompletion;
    _playbackCompletion = null;
    if (completion != null && !completion.isCompleted) {
      completion.complete();
    }
    final activeFile = _activeFilePath;
    _activeFilePath = null;
    if (activeFile != null) {
      _deleteFileQuietly(activeFile);
    }
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('在线 TTS 停止播放失败: $e');
    }
  }

  Future<String> _synthesizeToFile(String text, int generation) async {
    final client = _httpClient ??= _httpClientFactory();
    final store = _fileStore ??= _fileStoreFactory();
    final bytes = await client.postTts(
      _serverUrl,
      text: text,
      speaker: _speaker,
    );
    if (generation != _generation) {
      throw StateError('online_tts_cancelled');
    }
    return store.writeAudio(bytes);
  }

  Future<void> _playToCompletion(String filePath, int generation) async {
    final player = _player ??= _playerFactory();
    _activeFilePath = filePath;
    final completion = Completer<void>();
    _playbackCompletion = completion;
    final subscription = player.completionStream.listen((_) {
      if (!completion.isCompleted) {
        completion.complete();
      }
    });
    try {
      await player.open(
        filePath,
        volume: _speechVolume,
        speed: _rateToSpeed(_speechRate),
      );
      await player.play();
      await completion.future;
    } finally {
      await subscription.cancel();
      if (identical(_playbackCompletion, completion)) {
        _playbackCompletion = null;
      }
    }
    _activeFilePath = null;
    if (generation != _generation) {
      throw StateError('online_tts_cancelled');
    }
  }

  static double _rateToSpeed(double rate) => 0.5 + rate.clamp(0.1, 1.0);

  void _deleteFileQuietly(String path) {
    _fileStore?.delete(path);
  }

  static String _toErrorText(Object error) {
    final raw = error.toString().trim();
    if (raw.isEmpty) return 'online_tts_failed';
    return raw.length > 220 ? raw.substring(0, 220) : raw;
  }

  void _notifySafe() {
    if (_isDisposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _generation++;
    final completion = _playbackCompletion;
    _playbackCompletion = null;
    if (completion != null && !completion.isCompleted) {
      completion.complete();
    }
    final activeFile = _activeFilePath;
    _activeFilePath = null;
    if (activeFile != null) {
      _deleteFileQuietly(activeFile);
    }
    _httpClient = null;
    final player = _player;
    _player = null;
    if (player != null) {
      unawaited(player.dispose());
    }
    super.dispose();
  }
}
