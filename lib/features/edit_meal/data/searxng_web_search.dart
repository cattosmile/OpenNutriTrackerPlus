import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/plaintext_destination_guard.dart';
import 'package:opennutritracker/features/edit_meal/domain/usecase/ai_meal_scan_usecase.dart';

/// How long one SearXNG request is given.
///
/// The instance fans a query out to several engines and answers with the
/// merge, which is the whole point of it and also why it is slower than a
/// plain search API: a healthy instance answers in 2–8 s, and a ceiling
/// much below 15 s cuts off engines that were still about to answer.
const searxngTimeout = Duration(seconds: 15);

/// How many hits ride into the extraction prompt. Snippets are short, so
/// six of them is a page of text for the model — beyond that the later hits
/// stopped adding coverage in the runs this number was picked from.
const _maxHits = 6;

/// [AiMealWebSearch] against a SearXNG instance the user runs.
///
/// SearXNG is a metasearch engine the user hosts: it sends one query to the
/// search engines it is configured with and returns the merged results as
/// JSON. That makes the web step keyless for this app, billed to nobody's
/// API meter, and provider-neutral — it works whichever model answers the
/// scan's other calls. The instance must allow the JSON output format
/// (`search.formats` containing `json` in its `settings.yml`); without it
/// every request answers 403 and the settings dialog's check says so.
///
/// Every failure answers empty rather than raising: this is the last
/// resort behind two free databases, and the scan continues without it.
class SearxngWebSearch implements AiMealWebSearch {
  final http.Client _client;
  final AiCredentialStorage _credentials;

  SearxngWebSearch(this._client, this._credentials);

  @override
  Future<List<AiMealWebHit>> search(String query) async {
    final base = await _credentials.readSearxngUrl();
    if (base == null) return const [];
    final decoded = await _jsonSearch(
      _client,
      base,
      await _credentials.readSearxngToken(),
      query,
    );
    if (decoded == null) return const [];
    return _hitsFrom(decoded);
  }

  /// Whether [url] names an instance that answers a JSON search — the
  /// check the settings dialog offers next to the field.
  ///
  /// Static, and asked with a typed address rather than the stored one,
  /// for the same reason the model list is: the moment to find out an
  /// address is wrong is before it is saved. A 200 whose body is a JSON
  /// object proves both halves this feature needs — the instance is up,
  /// and it serves `format=json` — where the most common misconfiguration
  /// (JSON disabled) answers 403 exactly like an unreachable host, which
  /// is why the failure message names both.
  static Future<bool> reachable(
    http.Client client,
    String url,
    String? token,
  ) async {
    final base = AiCredentialStorage.resolveSearxngUrl(url);
    if (base == null) return false;
    return await _jsonSearch(client, base, token, 'water') != null;
  }

  /// One guarded GET against `/search`, decoded, or null for every way it
  /// can come back unusable — wrong status, not JSON, slow, refused by the
  /// plaintext guard. Null is the caller's "no results here", not an
  /// error: no caller of this can do anything with a failure but continue.
  ///
  /// No `language` parameter, on purpose: it was tried and the instance's
  /// bing engine answered zero results for a query the same engine
  /// answered well without it, so the query's own nutrition word carries
  /// the locale instead.
  static Future<Map<String, dynamic>?> _jsonSearch(
    http.Client client,
    Uri base,
    String? token,
    String query,
  ) async {
    final search = base.replace(
      path: base.path.isEmpty ? '/search' : '${base.path}/search',
      queryParameters: {'q': query, 'format': 'json'},
    );
    try {
      // The same guard the own-server provider gets: the address is typed
      // by the user, so plaintext is allowed to private destinations and
      // refused — here, before the query leaves the phone — to anything
      // public. The decorator is not closed: closing it would close the
      // shared client inside it.
      final response = await GuardedPlaintextClient(client)
          .get(
            search,
            headers: {if (token != null) 'authorization': 'Bearer $token'},
          )
          .timeout(searxngTimeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// The first [_maxHits] results with a URL — a hit without one cannot be
  /// cited and is skipped; title and snippet degrade to empty strings,
  /// which the extraction prompt tolerates better than a dropped result.
  static List<AiMealWebHit> _hitsFrom(Map<String, dynamic> decoded) {
    final results = decoded['results'];
    if (results is! List) return const [];
    return [
      for (final result in results.take(_maxHits))
        if (result is Map && result['url'] is String && result['url'] != '')
          AiMealWebHit(
            title: result['title'] is String ? result['title'] as String : '',
            snippet: result['content'] is String
                ? result['content'] as String
                : '',
            url: result['url'] as String,
          ),
    ];
  }
}
