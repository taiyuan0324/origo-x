// 文件说明：OnlineTtsEngine 单元测试，全部使用假 HTTP/播放器/文件存储，无真实网络。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/services/online_tts_engine.dart';

class _FakeHttpClient implements OnlineTtsHttpClient {
  _FakeHttpClient({this.ttsHandler, this.jsonHandler});

  Future<Uint8List> Function(
    String serverUrl, {
    required String text,
    required String speaker,
  })?
  ttsHandler;
  Future<Map<String, Object?>> Function(String serverUrl, String path)?
  jsonHandler;
  final List<Map<String, Object?>> ttsCalls = <Map<String, Object?>>[];

  @override
  Future<Uint8List> postTts(
    String serverUrl, {
    required String text,
    required String speaker,
  }) async {
    ttsCalls.add(<String, Object?>{
      'serverUrl': serverUrl,
      'text': text,
      'speaker': speaker,
    });
    final handler = ttsHandler;
    if (handler != null) {
      return handler(serverUrl, text: text, speaker: speaker);
    }
    return Uint8List.fromList(const <int>[1, 2, 3]);
  }

  @override
  Future<Map<String, Object?>> getJson(String serverUrl, String path) async {
    final handler = jsonHandler;
    if (handler != null) {
      return handler(serverUrl, path);
    }
    return <String, Object?>{'ready': true, 'speakers': 44};
  }
}

class _FakePlayer implements OnlineTtsPlayer {
  final List<String> opened = <String>[];
  final List<double> volumes = <double>[];
  final List<double> speeds = <double>[];
  final StreamController<void> _completion = StreamController<void>.broadcast();
  int pauseCount = 0;
  int resumeCount = 0;
  int stopCount = 0;
  int playCount = 0;

  @override
  Future<void> open(
    String filePath, {
    required double volume,
    required double speed,
  }) async {
    opened.add(filePath);
    volumes.add(volume);
    speeds.add(speed);
  }

  @override
  Future<void> play() async => playCount++;

  @override
  Future<void> pause() async => pauseCount++;

  @override
  Future<void> resume() async => resumeCount++;

  @override
  Future<void> stop() async => stopCount++;

  @override
  Stream<void> get completionStream => _completion.stream;

  void complete() => _completion.add(null);

  @override
  Future<void> dispose() async {
    await _completion.close();
  }
}

class _FakeFileStore implements OnlineTtsFileStore {
  final List<Uint8List> written = <Uint8List>[];
  final List<String> deleted = <String>[];
  int counter = 0;

  @override
  Future<String> writeAudio(Uint8List bytes) async {
    written.add(bytes);
    return 'fake_${counter++}.aac';
  }

  @override
  void delete(String path) => deleted.add(path);
}

/// 推进微任务队列，等待引擎内部的异步链前进。
Future<void> _settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

OnlineTtsEngine _createEngine({
  required _FakeHttpClient http,
  required _FakePlayer player,
  required _FakeFileStore store,
}) => OnlineTtsEngine(
  httpClientFactory: () => http,
  playerFactory: () => player,
  fileStoreFactory: () => store,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('speakQueued 逐段合成播放并回调段落索引', () async {
    final http = _FakeHttpClient();
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    final started = <int>[];
    final future = engine.speakQueued(<String>[
      '第一段。',
      '第二段。',
    ], onTextStarted: started.add);

    await _settle();
    expect(player.opened, hasLength(1));
    expect(started, <int>[0]);
    expect(engine.isPlaying, isTrue);
    expect(http.ttsCalls.single['text'], '第一段。');

    player.complete();
    await _settle();
    expect(player.opened, hasLength(2));
    expect(started, <int>[0, 1]);
    expect(engine.currentText, '第二段。');

    player.complete();
    await future;
    expect(engine.isPlaying, isFalse);
    expect(engine.isPaused, isFalse);
    expect(http.ttsCalls, hasLength(2));
    expect(store.written, hasLength(2));
    expect(store.deleted, hasLength(2));
  });

  test('speak 单句委托给队列实现', () async {
    final http = _FakeHttpClient();
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    final future = engine.speak('单独一句。');
    await _settle();
    expect(player.opened, hasLength(1));
    expect(http.ttsCalls.single['text'], '单独一句。');
    player.complete();
    await future;
    expect(engine.isPlaying, isFalse);
  });

  test('stop 打断队列，不再合成后续段落', () async {
    final http = _FakeHttpClient();
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    final future = engine.speakQueued(<String>[
      '一。',
      '二。',
      '三。',
    ], onTextStarted: (_) {});

    await _settle();
    expect(player.opened, hasLength(1));

    await engine.stop();
    await future;
    expect(player.opened, hasLength(1));
    expect(http.ttsCalls, hasLength(1));
    expect(player.stopCount, 1);
    expect(engine.isPlaying, isFalse);
  });

  test('合成失败中断队列并向上抛出错误', () async {
    final http = _FakeHttpClient(
      ttsHandler:
          (
            String serverUrl, {
            required String text,
            required String speaker,
          }) async {
            if (text == '坏句。') {
              throw StateError('online_tts_http_500: 合成失败');
            }
            return Uint8List.fromList(const <int>[1]);
          },
    );
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    final future = engine.speakQueued(<String>[
      '好句。',
      '坏句。',
      '后续。',
    ], onTextStarted: (_) {});
    await _settle();
    expect(player.opened, hasLength(1));
    // 第一段播完才会合成第二段（坏句），触发失败路径。
    player.complete();
    await expectLater(future, throwsA(isA<StateError>()));
    expect(engine.isPlaying, isFalse);
    expect(engine.lastError, contains('online_tts_http_500'));
    expect(http.ttsCalls, hasLength(2));
    expect(player.opened, hasLength(1));
  });

  test('pause 与 resume 转发给播放器并更新状态', () async {
    final http = _FakeHttpClient();
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    final future = engine.speak('暂停测试。');
    await _settle();
    expect(engine.isPlaying, isTrue);

    await engine.pause();
    expect(engine.isPaused, isTrue);
    expect(engine.isPlaying, isFalse);
    expect(player.pauseCount, 1);

    await engine.resume();
    expect(engine.isPaused, isFalse);
    expect(engine.isPlaying, isTrue);
    expect(player.resumeCount, 1);

    player.complete();
    await future;
    expect(engine.isPlaying, isFalse);
  });

  test('refreshSpeakers 按 byCategory 解析音色', () async {
    final http = _FakeHttpClient(
      jsonHandler: (String serverUrl, String path) async {
        expect(path, '/speakers');
        return <String, Object?>{
          'speakers': <Object?>['温柔桃子', '磁性俊宇', '腹黑霸总'],
          'byCategory': <String, Object?>{
            'female': <Object?>['温柔桃子'],
            'male': <Object?>['磁性俊宇'],
            'special': <Object?>['腹黑霸总'],
          },
          'default': '温柔桃子',
        };
      },
    );
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    await engine.refreshSpeakers();
    expect(engine.speakers.map((s) => '${s.category}:${s.name}'), <String>[
      'female:温柔桃子',
      'male:磁性俊宇',
      'special:腹黑霸总',
    ]);
    expect(engine.speakerLoadError, isNull);
    expect(engine.isLoadingSpeakers, isFalse);
  });

  test('refreshSpeakers 失败时保留内置音色并记录错误', () async {
    final http = _FakeHttpClient(
      jsonHandler: (String serverUrl, String path) async =>
          throw StateError('online_tts_http_503'),
    );
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    await engine.refreshSpeakers();
    expect(engine.speakers, kBuiltinOnlineSpeakers);
    expect(engine.speakerLoadError, contains('online_tts_http_503'));
  });

  test('testConnection 在 ready=false 时返回就绪提示', () async {
    final http = _FakeHttpClient(
      jsonHandler: (String serverUrl, String path) async {
        if (path == '/status') {
          return <String, Object?>{'ready': false, 'speakers': 44};
        }
        return <String, Object?>{};
      },
    );
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    final result = await engine.testConnection();
    expect(result, contains('未就绪'));
  });

  test('testConnection 成功时返回 null 并拉取音色', () async {
    final http = _FakeHttpClient(
      jsonHandler: (String serverUrl, String path) async {
        if (path == '/status') {
          return <String, Object?>{'ready': true, 'speakers': 44};
        }
        return <String, Object?>{
          'byCategory': <String, Object?>{
            'female': <Object?>['温柔桃子'],
          },
        };
      },
    );
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    final result = await engine.testConnection();
    expect(result, isNull);
    expect(engine.speakers.single.name, '温柔桃子');
  });

  test('serverUrl 规范化：补 http:// 前缀并去尾斜杠', () async {
    final http = _FakeHttpClient();
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    await engine.setServerUrl('192.168.1.74:3456/');
    expect(engine.serverUrl, 'http://192.168.1.74:3456');

    await engine.setServerUrl('http://fn.0324168.xyz:3456///');
    expect(engine.serverUrl, 'http://fn.0324168.xyz:3456');

    await engine.setServerUrl('   ');
    expect(engine.serverUrl, 'http://192.168.1.74:3456');
  });

  test('音色与服务地址持久化到 SharedPreferences', () async {
    final http = _FakeHttpClient();
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;

    await engine.setSpeaker('磁性俊宇');
    await engine.setEnabled(true);
    await engine.setServerUrl('http://192.168.1.99:3456');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('tts_online_speaker'), '磁性俊宇');
    expect(prefs.getBool('tts_online_enabled'), isTrue);
    expect(
      prefs.getString('tts_online_server_url'),
      'http://192.168.1.99:3456',
    );

    // 重新构造引擎后从持久化恢复。
    final restored = _createEngine(http: http, player: player, store: store);
    addTearDown(restored.dispose);
    await restored.whenReady;
    expect(restored.speaker, '磁性俊宇');
    expect(restored.enabled, isTrue);
    expect(restored.serverUrl, 'http://192.168.1.99:3456');
  });

  test('合成请求带上当前音色与服务地址', () async {
    final http = _FakeHttpClient();
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;
    await engine.setServerUrl('http://192.168.1.74:3456');
    await engine.setSpeaker('知性小棠');

    final future = engine.speak('带音色参数。');
    await _settle();
    player.complete();
    await future;

    expect(http.ttsCalls.single['serverUrl'], 'http://192.168.1.74:3456');
    expect(http.ttsCalls.single['speaker'], '知性小棠');
  });

  test('语速映射为播放倍速', () async {
    final http = _FakeHttpClient();
    final player = _FakePlayer();
    final store = _FakeFileStore();
    final engine = _createEngine(http: http, player: player, store: store);
    addTearDown(engine.dispose);
    await engine.whenReady;
    await engine.setSpeechRate(0.5);
    await engine.setVolume(0.8);

    final future = engine.speak('倍速测试。');
    await _settle();
    player.complete();
    await future;

    expect(player.speeds.single, 1.0);
    expect(player.volumes.single, 0.8);
  });
}
