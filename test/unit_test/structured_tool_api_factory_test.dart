import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/data/meal_items_api_factory.dart';
import 'package:opennutritracker/features/add_meal/data/openai_compatible_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/structured_tool_api.dart';
import 'package:opennutritracker/features/edit_meal/domain/ai_meal_scan.dart';

import 'openrouter_meal_items_api_test.dart' show FakeClient;

/// The structured-tool seam: one client per provider, built by the same
/// factory the items path uses, and the wire shape of its call on the one
/// provider this fork runs (Z.ai's coding endpoint).
void main() {
  MealPhoto photo(int seed) => MealPhoto(
    bytes: Uint8List.fromList([seed, seed + 1, seed + 2]),
    mediaType: 'image/jpeg',
  );

  group('structuredToolApiFor', () {
    test('every provider a selection can name speaks the seam', () {
      const selections = [
        AiSelection(provider: AiProvider.anthropic, apiKey: 'k'),
        AiSelection(provider: AiProvider.openrouter, apiKey: 'k'),
        AiSelection(provider: AiProvider.openai, apiKey: 'k'),
        AiSelection(provider: AiProvider.zai, apiKey: 'k'),
        AiSelection(
          provider: AiProvider.ownServer,
          endpoint: 'http://192.168.1.5:11434',
          modelId: 'gemma3:4b',
        ),
      ];
      for (final selection in selections) {
        expect(
          () => structuredToolApiFor(http.Client(), selection),
          returnsNormally,
          reason:
              '${selection.provider.name} has no StructuredToolApi client, '
              'so the label scan cannot run against it',
        );
      }
    });
  });

  group('the Z.ai call on the coding endpoint', () {
    String reply() => jsonEncode({
      'choices': [
        {
          'message': {
            'tool_calls': [
              {
                'function': {
                  'name': scanLabelToolName,
                  'arguments': jsonEncode({
                    'productName': 'Test',
                    'nutrients': {'energyKcal100': 100},
                  }),
                },
              },
            ],
          },
        },
      ],
    });

    test('carries both photos, the thinking fields and the forced tool',
        () async {
      final client = FakeClient(body: reply());
      final api = structuredToolApiFor(
        client,
        const AiSelection(
          provider: AiProvider.zai,
          apiKey: 'k',
          reasoningEffort: AiReasoningEffort.high,
        ),
      );

      final arguments = await api.requestToolJson(
        system: 'system prompt',
        userPrompt: 'Transcribe this product\'s label.',
        photos: [photo(1), photo(4)],
        toolName: scanLabelToolName,
        toolDescription: scanLabelToolDescription,
        toolSchema: scanLabelToolSchema,
      );

      expect(client.sentUrl, OpenAiCompatibleMealItemsApi.zaiEndpoint);
      expect(arguments['productName'], 'Test');

      final body = client.sentBody!;
      // The reasoning pair the coding endpoint documents.
      expect(body['thinking'], {'type': 'enabled'});
      expect(body['reasoning_effort'], 'high');
      // A label transcription needs a bigger budget than a food list.
      expect(body['max_tokens'] as int, greaterThanOrEqualTo(4096));
      // The user turn is text first, then both photos as data URIs.
      final content = (body['messages'] as List).last['content'] as List;
      expect(content, hasLength(3));
      expect(content.first['type'], 'text');
      expect(content[1]['type'], 'image_url');
      expect(content[2]['type'], 'image_url');
      expect(
        (content[1]['image_url'] as Map)['url'] as String,
        startsWith('data:image/jpeg;base64,'),
      );
      // One tool, forced by name.
      final tool = (body['tools'] as List).first['function'] as Map;
      expect(tool['name'], scanLabelToolName);
      expect((body['tool_choice'] as Map)['function']['name'],
          scanLabelToolName);
    });

    test('arguments arriving as an object are accepted too', () async {
      final client = FakeClient(
        body: jsonEncode({
          'choices': [
            {
              'message': {
                'tool_calls': [
                  {
                    'function': {
                      'name': scanLabelToolName,
                      // An object rather than the documented JSON string.
                      'arguments': {
                        'productName': 'Test',
                        'nutrients': {},
                      },
                    },
                  },
                ],
              },
            },
          ],
        }),
      );
      final api = structuredToolApiFor(
        client,
        const AiSelection(provider: AiProvider.zai, apiKey: 'k'),
      );

      final arguments = await api.requestToolJson(
        system: 's',
        userPrompt: 'p',
        photos: const [],
        toolName: scanLabelToolName,
        toolDescription: scanLabelToolDescription,
        toolSchema: scanLabelToolSchema,
      );

      expect(arguments['productName'], 'Test');
    });
  });
}
