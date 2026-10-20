import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/domain/structured_tool_api.dart';
import 'package:opennutritracker/features/edit_meal/domain/ai_meal_scan.dart';
import 'package:opennutritracker/features/edit_meal/domain/usecase/ai_meal_scan_usecase.dart';

/// The scan pipeline against canned model replies and canned research.
///
/// What is pinned here: the model calls happen in the OCR → merge order
/// with the research in between; the barcode the OCR read drives the
/// barcode lookup and the name drives the text search; the label's values
/// reach the result unchanged; and a missing credential is "unavailable",
/// not a failure. The web search of last resort — one search plus one
/// extraction call when both databases answer nothing — is pinned in its
/// own group below.
void main() {
  final photo = MealPhoto(
    bytes: Uint8List.fromList([1, 2, 3]),
    mediaType: 'image/jpeg',
  );

  AiCredentialStorage configuredStorage() {
    final storage = AiCredentialStorage(_MemorySecureStorage());
    return storage;
  }

  Future<AiCredentialStorage> zaiStorage() async {
    final storage = configuredStorage();
    await storage.setActiveProvider(AiProvider.zai);
    await storage.writeApiKey('test-key');
    await storage.setTermsAccepted(true);
    return storage;
  }

  test('no credential is Unavailable, not a failure', () async {
    final outcome = await AiMealScanUseCase(
      configuredStorage(),
      (_) => throw StateError('must not be called'),
      _FakeResearch(),
      _FakeWebSearch(),
    ).run(backPhoto: photo);

    expect(outcome, isA<AiMealScanUnavailable>());
  });

  test('the full pipeline: OCR, research, merge, precedence', () async {
    final api = _FakeToolApi([
      {
        'productName': 'Thunfisch',
        'brand': 'Kaak',
        'barcode': '4000417025006',
        'packageSizeGrams': 185,
        'servingSizeGrams': 92.5,
        'nutrients': {'energyKcal100': 116, 'proteins100': 26},
      },
      {
        'nutrients': {
          'energyKcal100': 200,
          'proteins100': 26,
          'selenium100': 60,
          'iodine100': 25,
        },
        'matchedFoodName': 'Thunfisch in Wasser',
      },
      // The canned merge covers only four keys, so the pipeline asks for
      // the rest — the reply fills one of them.
      {
        'nutrients': {'vitaminB9100': 20},
      },
    ]);
    final research = _FakeResearch()
      ..barcodeRecords = [
        const AiFoodRecord('Open Food Facts', 'Thunfisch Dose', {
          'selenium100': 55,
        }),
      ];

    final phases = <AiMealScanPhase>[];
    final outcome =
        await AiMealScanUseCase(
          await zaiStorage(),
          (_) => api,
          research,
          _FakeWebSearch(),
        ).run(
          backPhoto: photo,
          frontPhoto: photo,
          supermarket: 'Rewe',
          brand: '',
          productName: '',
          portionGrams: '185',
          onPhase: phases.add,
        );

    expect(outcome, isA<AiMealScanDone>());
    final result = (outcome as AiMealScanDone).result;
    expect(result.name, 'Thunfisch');
    expect(result.packageSizeGrams, 185);
    // The typed portion rides through as the user's own serving.
    expect(result.userPortionGrams, 185);
    // The label's energy survives the merge's different opinion.
    expect(result.nutrients['energyKcal100'], 116);
    expect(result.sources['energyKcal100'], AiLabelValueSource.label);
    expect(result.sources['selenium100'], AiLabelValueSource.database);
    expect(result.sources['iodine100'], AiLabelValueSource.estimated);
    // The gap-filled key counts as the model's own estimate.
    expect(result.sources['vitaminB9100'], AiLabelValueSource.estimated);
    expect(result.matchedFoodName, 'Thunfisch in Wasser');

    // Call order and photo routing: the OCR carries both photos, the merge
    // is text-only, and the gap-fill only happens because the canned
    // merge was partial.
    expect(api.calls.map((c) => c.toolName), [
      scanLabelToolName,
      mergeNutrientsToolName,
      scanGapFillToolName,
    ]);
    expect(api.calls.first.photos, 2);
    expect(api.calls.last.photos, 0);
    // The merge prompt carries the hints and the research record.
    expect(api.calls[1].userPrompt, contains('"supermarket":"Rewe"'));
    expect(api.calls[1].userPrompt, contains('Thunfisch Dose'));

    expect(research.barcodes, ['4000417025006']);
    expect(research.queries, ['Kaak Thunfisch']);
    expect(phases, [
      AiMealScanPhase.reading,
      AiMealScanPhase.researching,
      AiMealScanPhase.completing,
    ]);
  });

  test(
    'a typed brand seeds the name search when the label named none',
    () async {
      final api = _FakeToolApi([
        {'productName': 'Vollkornbrot', 'nutrients': {}},
        {'nutrients': {}},
        {'nutrients': {}},
      ]);
      final research = _FakeResearch();

      await AiMealScanUseCase(
        await zaiStorage(),
        (_) => api,
        research,
        _FakeWebSearch(),
      ).run(backPhoto: photo, brand: 'Gut & Günstig');

      expect(research.queries, ['Gut & Günstig Vollkornbrot']);
    },
  );

  test('a typed product name outranks the OCR reading in the search', () async {
    final api = _FakeToolApi([
      {'productName': 'Thunfisch', 'brand': 'Kaak', 'nutrients': {}},
      {'nutrients': {}},
      {'nutrients': {}},
    ]);
    final research = _FakeResearch();

    await AiMealScanUseCase(
      await zaiStorage(),
      (_) => api,
      research,
      _FakeWebSearch(),
    ).run(backPhoto: photo, productName: 'Thunfischfilets in eigenem Saft');

    expect(research.queries, ['Kaak Thunfischfilets in eigenem Saft']);
    // The typed name rides along as a merge hint too.
    expect(
      api.calls[1].userPrompt,
      contains('Thunfischfilets in eigenem Saft'),
    );
  });

  test('failing research degrades instead of failing the scan', () async {
    final api = _FakeToolApi([
      {'productName': 'Linsen', 'barcode': '4000417025006', 'nutrients': {}},
      {
        'nutrients': {'iron100': 3},
      },
      {'nutrients': {}},
    ]);
    final research = _ThrowingResearch();

    final outcome = await AiMealScanUseCase(
      await zaiStorage(),
      (_) => api,
      research,
      _FakeWebSearch(),
    ).run(backPhoto: photo);

    expect(outcome, isA<AiMealScanDone>());
    expect(
      (outcome as AiMealScanDone).result.sources['iron100'],
      AiLabelValueSource.estimated,
    );
  });

  test('records reach the merge trimmed to the label\'s gaps', () async {
    final api = _FakeToolApi([
      {
        'productName': 'Thunfisch',
        'nutrients': {'energyKcal100': 116, 'proteins100': 26},
      },
      {'nutrients': {}},
      {'nutrients': {}},
    ]);
    final research = _FakeResearch()
      ..nameRecords = [
        const AiFoodRecord('Open Food Facts', 'Thunfisch Dose', {
          'energyKcal100': 999,
          'selenium100': 55,
        }),
        // Every nutrient already covered: a record with nothing to fill.
        const AiFoodRecord('Open Food Facts', 'Vollkopie', {
          'energyKcal100': 111,
          'proteins100': 22,
        }),
      ];

    final outcome = await AiMealScanUseCase(
      await zaiStorage(),
      (_) => api,
      research,
      _FakeWebSearch(),
    ).run(backPhoto: photo);

    expect(outcome, isA<AiMealScanDone>());
    final prompt = api.calls[1].userPrompt;
    // The gap-filling record is there with only its gap nutrient.
    expect(prompt, contains('Thunfisch Dose'));
    expect(prompt, contains('"selenium100":55'));
    expect(prompt, isNot(contains('"energyKcal100":999')));
    // The all-covered record dropped out entirely.
    expect(prompt, isNot(contains('Vollkopie')));
  });

  test('a typed portion parses with a comma decimal separator', () async {
    final api = _FakeToolApi([
      {'productName': 'Butter', 'nutrients': {}},
      {'nutrients': {}},
      {'nutrients': {}},
    ]);

    final outcome = await AiMealScanUseCase(
      await zaiStorage(),
      (_) => api,
      _FakeResearch(),
      _FakeWebSearch(),
    ).run(backPhoto: photo, portionGrams: '92,5');

    expect((outcome as AiMealScanDone).result.userPortionGrams, 92.5);
    expect(api.calls[1].userPrompt, contains('"portionGrams":92.5'));
  });

  test('a complete merge needs no third call', () async {
    final api = _FakeToolApi([
      {'productName': 'Thunfisch', 'nutrients': {}},
      {
        'nutrients': {for (final key in aiScanNutrientUnits.keys) key: 1},
      },
    ]);

    final outcome = await AiMealScanUseCase(
      await zaiStorage(),
      (_) => api,
      _FakeResearch(),
      _FakeWebSearch(),
    ).run(backPhoto: photo);

    expect(outcome, isA<AiMealScanDone>());
    expect(api.calls.map((c) => c.toolName), [
      scanLabelToolName,
      mergeNutrientsToolName,
    ]);
  });

  test('the gap-fill asks for exactly what nobody covered', () async {
    final api = _FakeToolApi([
      {'productName': 'Butter', 'nutrients': {}},
      {
        // Everything except the two the live model dropped on the user.
        'nutrients': {
          for (final key in aiScanNutrientUnits.keys)
            if (key != 'vitaminB9100' && key != 'choline100') key: 1,
        },
      },
      {
        'nutrients': {'vitaminB9100': 20, 'choline100': 10},
      },
    ]);

    final outcome = await AiMealScanUseCase(
      await zaiStorage(),
      (_) => api,
      _FakeResearch(),
      _FakeWebSearch(),
    ).run(backPhoto: photo);

    expect(outcome, isA<AiMealScanDone>());
    final result = (outcome as AiMealScanDone).result;
    expect(result.nutrients['vitaminB9100'], 20);
    expect(result.sources['vitaminB9100'], AiLabelValueSource.estimated);
    expect(result.nutrients['choline100'], 10);
    final gapFill = api.calls.last;
    expect(gapFill.toolName, scanGapFillToolName);
    expect(
      (gapFill.toolSchema['properties']! as Map<String, dynamic>)['nutrients']!
          as Map<String, dynamic>,
      containsPair('required', ['vitaminB9100', 'choline100']),
    );
  });

  group('the web search of last resort', () {
    // Both free databases empty is the store-brand case the step exists
    // for. One search, one extraction call, and the web record joins the
    // pipeline as a record like any other — its values tagged Web, below a
    // database's and above the merge's estimate.
    test('empty database research falls back to one web search', () async {
      final api = _FakeToolApi([
        {'productName': 'Skyr', 'brand': 'Milbona', 'nutrients': {}},
        {
          // The extraction: only what a result stated.
          'nutrients': {'proteins100': 10},
        },
        {
          // A complete merge, so no gap-fill reply is needed.
          'nutrients': {for (final key in aiScanNutrientUnits.keys) key: 5},
        },
      ]);
      final web = _FakeWebSearch()
        ..hits = [
          const AiMealWebHit(
            title: 'Milbona Skyr Nährwerte',
            snippet: '100 g: 63 kcal, 10 g Eiweiß',
            url: 'https://example.org/skyr',
          ),
        ];

      final outcome = await AiMealScanUseCase(
        await zaiStorage(),
        (_) => api,
        _FakeResearch(),
        web,
      ).run(backPhoto: photo);

      // The search ran once, nutrition-worded, and the extraction call
      // carries the hit and asks for stated values only.
      expect(web.queries, ['Milbona Skyr nutrition']);
      expect(api.calls[1].toolName, scanWebExtractToolName);
      expect(api.calls[1].photos, 0);
      expect(api.calls[1].userPrompt, contains('Milbona Skyr Nährwerte'));
      // The web record rides into the merge as a record like any other.
      expect(api.calls[2].toolName, mergeNutrientsToolName);
      expect(api.calls[2].userPrompt, contains('"source":"Web search"'));
      // Its values are tagged Web, not Database and not Estimated.
      final result = (outcome as AiMealScanDone).result;
      expect(result.nutrients['proteins100'], 5);
      expect(result.sources['proteins100'], AiLabelValueSource.web);
      expect(result.sources['iron100'], AiLabelValueSource.estimated);
    });

    test('a German scan searches German pages', () async {
      final api = _FakeToolApi([
        {'productName': 'Sky', 'nutrients': {}},
        {
          'nutrients': {for (final key in aiScanNutrientUnits.keys) key: 1},
        },
      ]);
      final web = _FakeWebSearch();

      await AiMealScanUseCase(
        await zaiStorage(),
        (_) => api,
        _FakeResearch(),
        web,
      ).run(backPhoto: photo, localeCode: 'de');

      expect(web.queries, ['Sky Nährwerte']);
    });

    test('a web instance with nothing costs no model call', () async {
      final api = _FakeToolApi([
        {'productName': 'Skyr', 'nutrients': {}},
        {
          'nutrients': {for (final key in aiScanNutrientUnits.keys) key: 1},
        },
      ]);
      final web = _FakeWebSearch();

      await AiMealScanUseCase(
        await zaiStorage(),
        (_) => api,
        _FakeResearch(),
        web,
      ).run(backPhoto: photo);

      expect(api.calls.map((c) => c.toolName), [
        scanLabelToolName,
        mergeNutrientsToolName,
      ]);
    });

    test('a database answer skips the web entirely', () async {
      final api = _FakeToolApi([
        {'productName': 'Thunfisch', 'nutrients': {}},
        {
          'nutrients': {for (final key in aiScanNutrientUnits.keys) key: 1},
        },
      ]);
      final web = _FakeWebSearch();
      final research = _FakeResearch()
        ..nameRecords = [
          const AiFoodRecord('Open Food Facts', 'Thunfisch Dose', {
            'selenium100': 55,
          }),
        ];

      await AiMealScanUseCase(
        await zaiStorage(),
        (_) => api,
        research,
        web,
      ).run(backPhoto: photo);

      // Below the web in trust and already answering: no search paid.
      expect(web.queries, isEmpty);
    });

    test('an extraction that states nothing falls back to estimates', () async {
      final api = _FakeToolApi([
        {'productName': 'Skyr', 'nutrients': {}},
        // Stated nothing — the expected outcome for most nutrients.
        {'nutrients': {}},
        {
          'nutrients': {for (final key in aiScanNutrientUnits.keys) key: 1},
        },
      ]);
      final web = _FakeWebSearch()
        ..hits = [
          const AiMealWebHit(
            title: 'Unrelated',
            snippet: 'nothing here',
            url: 'https://example.org/x',
          ),
        ];

      final outcome = await AiMealScanUseCase(
        await zaiStorage(),
        (_) => api,
        _FakeResearch(),
        web,
      ).run(backPhoto: photo);

      final result = (outcome as AiMealScanDone).result;
      expect(result.sources['proteins100'], AiLabelValueSource.estimated);
    });
  });
}

class _FakeToolApi implements StructuredToolApi {
  final calls =
      <
        ({
          String toolName,
          int photos,
          String userPrompt,
          Map<String, dynamic> toolSchema,
        })
      >[];
  final List<Map<String, dynamic>> _replies;

  _FakeToolApi(this._replies);

  @override
  Future<Map<String, dynamic>> requestToolJson({
    required String system,
    required String userPrompt,
    required List<MealPhoto> photos,
    required String toolName,
    required String toolDescription,
    required Map<String, dynamic> toolSchema,
  }) async {
    calls.add((
      toolName: toolName,
      photos: photos.length,
      userPrompt: userPrompt,
      toolSchema: toolSchema,
    ));
    return _replies.removeAt(0);
  }
}

class _FakeResearch implements AiMealResearch {
  final barcodes = <String>[];
  final queries = <String>[];
  List<AiFoodRecord> barcodeRecords = const [];
  List<AiFoodRecord> nameRecords = const [];

  @override
  Future<List<AiFoodRecord>> byBarcode(String barcode) async {
    barcodes.add(barcode);
    return barcodeRecords;
  }

  @override
  Future<List<AiFoodRecord>> byName(String query) async {
    queries.add(query);
    return nameRecords;
  }
}

class _ThrowingResearch implements AiMealResearch {
  @override
  Future<List<AiFoodRecord>> byBarcode(String barcode) async {
    throw Exception('network down');
  }

  @override
  Future<List<AiFoodRecord>> byName(String query) async {
    throw Exception('network down');
  }
}

class _FakeWebSearch implements AiMealWebSearch {
  final queries = <String>[];
  List<AiMealWebHit> hits = const [];

  @override
  Future<List<AiMealWebHit>> search(String query) async {
    queries.add(query);
    return hits;
  }
}

/// In-memory keystore, same stand-in `ai_credential_storage_test.dart`
/// uses, reduced to the three calls this store makes on the read path.
class _MemorySecureStorage implements FlutterSecureStorage {
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
