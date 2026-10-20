import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/edit_meal/data/searxng_web_search.dart';

/// The web-search last resort against a canned instance.
///
/// What is pinned here: the request is one JSON `GET /search` against the
/// stored base with the query, the format and the locale hint; the stored
/// token travels as a bearer; and every way the instance can disappoint —
/// wrong status, not JSON, nothing configured — answers empty rather than
/// raising, because the scan continues without this step.
void main() {
  /// In-memory keystore stand-in, the same shape the storage test uses.
  _MemoryStorage backing() => _MemoryStorage();

  http.Response json(Map<String, dynamic> body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  test('one JSON search against the stored base', () async {
    Uri? asked;
    final client = MockClient((request) async {
      asked = request.url;
      return json({
        'results': [
          for (var i = 0; i < 8; i++)
            {
              'title': 'Hit $i',
              'url': 'https://example.org/$i',
              'content': 'Snippet $i',
            },
        ],
      });
    });
    final storage = AiCredentialStorage(backing());
    await storage.writeSearxngUrl('http://127.0.0.1:8888');
    final search = SearxngWebSearch(client, storage);

    final hits = await search.search('Milbona Skyr nutrition');

    expect(asked!.host, '127.0.0.1');
    expect(asked!.path, '/search');
    expect(asked!.queryParameters, {
      'q': 'Milbona Skyr nutrition',
      'format': 'json',
    });
    // Six hits ride into the prompt, not eight.
    expect(hits.length, 6);
    expect(hits.first.title, 'Hit 0');
    expect(hits.first.snippet, 'Snippet 0');
    expect(hits.first.url, 'https://example.org/0');
  });

  test('the token rides as a bearer', () async {
    String? authorization;
    final client = MockClient((request) async {
      authorization = request.headers['authorization'];
      return json({'results': const []});
    });
    final storage = AiCredentialStorage(backing());
    await storage.writeSearxngUrl('http://127.0.0.1:8888');
    await storage.writeSearxngToken('proxy-secret');
    final search = SearxngWebSearch(client, storage);

    await search.search('Sky Nährwerte');

    expect(authorization, 'Bearer proxy-secret');
  });

  test('a result without a URL is skipped, not half-kept', () async {
    final client = MockClient(
      (request) async => json({
        'results': [
          {'title': 'No URL', 'content': 'nothing to cite'},
          {
            'title': 'Has one',
            'url': 'https://example.org/1',
            'content': 'usable',
          },
        ],
      }),
    );
    final storage = AiCredentialStorage(backing());
    await storage.writeSearxngUrl('http://127.0.0.1:8888');

    final hits = await SearxngWebSearch(client, storage).search('x');

    expect(hits.map((hit) => hit.url), ['https://example.org/1']);
  });

  test('nothing configured sends nothing at all', () async {
    final client = MockClient(
      (request) async => throw StateError('must not be called'),
    );
    final search = SearxngWebSearch(client, AiCredentialStorage(backing()));

    expect(await search.search('Milbona Skyr'), isEmpty);
  });

  test('every disappointment answers empty', () async {
    final storage = AiCredentialStorage(backing());
    await storage.writeSearxngUrl('http://127.0.0.1:8888');
    for (final reply in [
      json({}, 403), // JSON format disabled — the common misconfiguration.
      http.Response('not json', 200),
      json({'results': 'no list here'}),
    ]) {
      final search = SearxngWebSearch(
        MockClient((request) async => reply),
        storage,
      );
      expect(await search.search('x'), isEmpty);
    }
  });

  group('reachable', () {
    test('a 200 JSON object passes', () async {
      final client = MockClient((request) async => json({'results': const []}));

      expect(
        await SearxngWebSearch.reachable(client, 'http://127.0.0.1:8888', null),
        isTrue,
      );
    });

    test('a 403 — JSON disabled — fails', () async {
      final client = MockClient((request) async => json({}, 403));

      expect(
        await SearxngWebSearch.reachable(client, 'http://127.0.0.1:8888', null),
        isFalse,
      );
    });

    test('an address that is not one fails without a request', () async {
      final client = MockClient(
        (request) async => throw StateError('must not be called'),
      );

      expect(
        await SearxngWebSearch.reachable(client, 'searx.example.org', null),
        isFalse,
      );
    });
  });
}

class _MemoryStorage implements FlutterSecureStorage {
  final store = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => store.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
