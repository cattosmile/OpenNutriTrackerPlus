import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/data/repository/products_repository.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/structured_tool_api.dart';
import 'package:opennutritracker/features/edit_meal/domain/ai_meal_scan.dart';

/// What a scan produced. Sealed for the same reason [MealPhotoReadResult]
/// is: "the feature is off" and "the call failed" want opposite words in
/// front of the user.
sealed class AiMealScanOutcome {
  const AiMealScanOutcome();
}

final class AiMealScanDone extends AiMealScanOutcome {
  final AiMealScanResult result;

  const AiMealScanDone(this.result);
}

final class AiMealScanUnavailable extends AiMealScanOutcome {
  const AiMealScanUnavailable();
}

final class AiMealScanFailed extends AiMealScanOutcome {
  final MealInterpreterFailure failure;

  const AiMealScanFailed(this.failure);
}

/// One product record found by the free research step: where it came from
/// (for the disclosure on the review card) and what it measured.
class AiFoodRecord {
  final String sourceLabel;
  final String name;
  final Map<String, double> nutrients;

  const AiFoodRecord(this.sourceLabel, this.name, this.nutrients);
}

/// The research half of a scan, as the use case sees it.
///
/// An interface so the pipeline is testable against canned records, and so
/// the sources stay swappable: today Open Food Facts (free, keyless, the
/// corpus strongest on EU packaged goods) plus the project's own Supabase
/// mirror of USDA FDC and the German BLS. Both answer in structured
/// per-100 g numbers rather than prose a second model would have to
/// re-read — and both are free, which is what a research step bolted onto
/// an optional feature has to be.
abstract interface class AiMealResearch {
  Future<List<AiFoodRecord>> byBarcode(String barcode);
  Future<List<AiFoodRecord>> byName(String query);
}

/// One result the web-search fallback found: what its title and snippet
/// said, and where it was published.
class AiMealWebHit {
  final String title;
  final String snippet;
  final String url;

  const AiMealWebHit({
    required this.title,
    required this.snippet,
    required this.url,
  });
}

/// The web-search half of a scan's research, as the use case sees it.
///
/// An interface for the same two reasons [AiMealResearch] is one: canned
/// results in tests, and a source that stays swappable. The implementation
/// the app ships asks a SearXNG instance **the user runs** — no key of the
/// app's, no vendor's metered quota, and no dependence on a credential for
/// a provider the user never chose, which is the trap every hosted
/// web-search API measured here falls into: Gemini's grounding answers
/// 429 on a free key before thinking, and Z.ai's `web_search` tool needs
/// the Z.ai key whatever model the scan is otherwise using.
///
/// The search returns raw results; the extraction into numbers is a call
/// on the scan's own model, so this step stays provider-neutral end to end.
abstract interface class AiMealWebSearch {
  /// Hits for [query], or empty when no instance is configured, none
  /// answered, or nothing came back. Never throws: research is an
  /// enhancement, and a network that cannot reach the instance still gets
  /// a scan whose gaps the merge step estimates.
  Future<List<AiMealWebHit>> search(String query);
}

/// Where a scan currently is, for the progress surface. The research step
/// has no failure state of its own — it degrades to estimation — so this is
/// narration, not state.
enum AiMealScanPhase { reading, identifying, researching, completing }

/// Reads a packaged-food label, researches the product, and completes the
/// nutrient profile.
///
/// Three steps, the outer two of them model calls through
/// [StructuredToolApi]:
///
/// 1. **OCR / identify** — with a back photo the label is transcribed (front
///    optional); the prompt forbids estimation on this step. Without one —
///    the bakery roll, the display case — a front photo is *identified*
///    instead ([scanIdentifySystemPrompt], same schema, nutrients empty),
///    and a scan with neither photo starts from the typed name and brand.
///    Every mode produces the same [AiLabelData]; only how much of it is
///    filled differs.
/// 2. **Research** — no model involved. The barcode and the name the first
///    step read are looked up in Open Food Facts and the Supabase food
///    backend, free of charge, through the same [ProductsRepository] the
///    search tab uses. When both answer nothing and the user runs a SearXNG
///    instance, one web search runs through it and the scan's own model
///    extracts the values the results state ([_webRecord]) — provider-neutral,
///    and the only part of a scan that touches the open web. A scan without
///    a back photo always runs that web search, generic database records
///    notwithstanding: without a printed table, a brand's own published
///    values are the closest thing to a label this scan will ever see.
/// 3. **Merge** — a text-only call that receives the label JSON, the
///    database records and the user's hints, and fills every nutrient by
///    the precedence in its prompt. A **gap-fill** call follows only when
///    the merge omitted nutrients nobody else covered — a small, rare
///    second asking rather than a 43-of-44 answer.
///
/// The source tag on every final value is computed here from what each
/// side actually contained (see [AiMealScanResult.build]) rather than
/// asked of the model.
class AiMealScanUseCase {
  static final _log = Logger('AiMealScanUseCase');

  /// Records handed to the merge step. Two per source keeps the prompt
  /// small and the choice legible; more than that measured as noise the
  /// model averages across rather than a better pick.
  static const _recordsPerSource = 2;

  final AiCredentialStorage _credentials;
  final StructuredToolApi Function(AiSelection selection) _apiFactory;
  final AiMealResearch _research;
  final AiMealWebSearch _webSearch;

  AiMealScanUseCase(
    this._credentials,
    this._apiFactory,
    this._research,
    this._webSearch,
  );

  Future<AiMealScanOutcome> run({
    MealPhoto? backPhoto,
    MealPhoto? frontPhoto,
    String supermarket = '',
    String brand = '',
    String productName = '',
    String portionGrams = '',
    String? localeCode,
    void Function(AiMealScanPhase phase)? onPhase,
  }) async {
    final selection = await _credentials.readSelection();
    if (selection == null) return const AiMealScanUnavailable();
    final api = _apiFactory(selection);

    // Parsed once, used twice: as a merge hint (it disambiguates nothing
    // about per-100 values, but tells the model what the user is eating)
    // and carried into the result so the form can prefill the serving
    // field with it — the portion the user typed is their serving.
    final userPortion = aiScanNumber(portionGrams);

    try {
      final label = await _readLabel(
        api: api,
        backPhoto: backPhoto,
        frontPhoto: frontPhoto,
        typedBrand: brand,
        typedProductName: productName,
        localeCode: localeCode,
        onPhase: onPhase,
      );

      final records = await _researchRecords(
        label: label,
        typedBrand: brand,
        typedProductName: productName,
      );
      onPhase?.call(AiMealScanPhase.researching);
      // The last resort — with an exception. Both free databases empty is
      // the store-brand case this step exists for, and there it runs only
      // then: a web result sits below a database record in trust, so paying
      // its latency when a record already answered would buy nothing. But a
      // scan without a printed table has no record of *this* product to be
      // outranked — its database hits are generic category matches — so it
      // searches the web whatever they said: the brand's own published
      // values are the closest thing to a label it will ever see.
      if (records.isEmpty || backPhoto == null) {
        final webRecord = await _webRecord(
          api: api,
          label: label,
          typedBrand: brand,
          typedProductName: productName,
          localeCode: localeCode,
        );
        if (webRecord != null) records.add(webRecord);
      }
      final databaseNutrients = <String, double>{};
      final webNutrients = <String, double>{};
      for (final record in records) {
        // The web record carries its own label, so the source tags below
        // can tell a food authority's number from a shop page's — the same
        // split this loop already does between label and merge.
        final target = record.sourceLabel == webSearchSourceLabel
            ? webNutrients
            : databaseNutrients;
        target.addEntries(
          record.nutrients.entries.where(
            (entry) => !target.containsKey(entry.key),
          ),
        );
      }

      // A record's value for a nutrient the label already printed can
      // never win (precedence 1), so only the gap keys ride along — fewer
      // numbers for the model to read past, and a record that fills no gap
      // drops out entirely. The full maps above still drive the source
      // tags, which is why they are kept separately.
      final mergeRecords = <Map<String, Object>>[];
      for (final record in records) {
        final gapNutrients = <String, double>{
          for (final entry in record.nutrients.entries)
            if (!label.nutrients.containsKey(entry.key)) entry.key: entry.value,
        };
        if (gapNutrients.isEmpty) continue;
        mergeRecords.add({
          'source': record.sourceLabel,
          'name': record.name,
          'nutrients': gapNutrients,
        });
      }

      onPhase?.call(AiMealScanPhase.completing);
      var merged = AiMergedNutrients.fromToolArguments(
        await api.requestToolJson(
          system: mergeNutrientsSystemPrompt,
          userPrompt: jsonEncode({
            'label': {
              'name': label.productName,
              'brand': label.brand,
              'nutrients': label.nutrients,
            },
            'hints': {
              'productName': productName.trim().isEmpty
                  ? null
                  : productName.trim(),
              'brand': brand.trim().isEmpty ? null : brand.trim(),
              'supermarket': supermarket.trim().isEmpty
                  ? null
                  : supermarket.trim(),
              'portionGrams': userPortion,
            },
            'databaseRecords': mergeRecords,
          }),
          photos: const [],
          toolName: mergeNutrientsToolName,
          toolDescription: mergeNutrientsToolDescription,
          toolSchema: mergeNutrientsToolSchema,
        ),
      );

      // Completeness is asked for, not guaranteed: live runs of the merge
      // at high reasoning effort dropped one to three of the 44 keys at
      // random, and no schema `required` list stopped it. Everything a
      // record measured is already covered — [AiMealScanResult.build]
      // applies the record-preference rule itself — so only what nobody
      // covered is asked for again, and only when such a gap exists.
      final stillMissing = <String>[
        for (final key in aiScanNutrientUnits.keys)
          if (!label.nutrients.containsKey(key) &&
              !merged.nutrients.containsKey(key) &&
              !databaseNutrients.containsKey(key))
            key,
      ];
      if (stillMissing.isNotEmpty) {
        final fill = AiMergedNutrients.fromToolArguments(
          await api.requestToolJson(
            system: scanGapFillSystemPrompt,
            userPrompt: jsonEncode({
              'name': label.productName,
              'brand': label.brand,
              'isDrink': label.isDrink,
              'knownNutrients': {...label.nutrients, ...merged.nutrients},
            }),
            photos: const [],
            toolName: scanGapFillToolName,
            toolDescription: scanGapFillToolDescription,
            toolSchema: scanGapFillToolSchema(stillMissing),
          ),
        );
        merged = AiMergedNutrients(
          nutrients: {...merged.nutrients, ...fill.nutrients},
          matchedFoodName: merged.matchedFoodName,
        );
      }

      return AiMealScanDone(
        AiMealScanResult.build(
          label: label,
          databaseNutrients: databaseNutrients,
          webNutrients: webNutrients,
          merged: merged,
          userPortionGrams: userPortion,
        ),
      );
    } on MealInterpreterException catch (e) {
      _log.info('Meal scan failed: ${e.reason}');
      return AiMealScanFailed(e.failure);
    } catch (e, stackTrace) {
      // An unexpected throw is a bug; report it as transient rather than
      // sending the user to fix a credential that is fine.
      _log.severe('Meal scan failed unexpectedly', e, stackTrace);
      return const AiMealScanFailed(MealInterpreterFailure.transient);
    }
  }

  /// The identity half of a scan: what the first model call, if any, read.
  ///
  /// A back photo is transcribed as a label; a front photo alone is
  /// identified as a food — no table exists to transcribe, so the reply
  /// carries a name at most; and a scan with neither photo starts from what
  /// the user typed, with no model call at all. All three modes land in the
  /// same [AiLabelData]; nothing after this method can tell them apart.
  Future<AiLabelData> _readLabel({
    required StructuredToolApi api,
    required MealPhoto? backPhoto,
    required MealPhoto? frontPhoto,
    required String typedBrand,
    required String typedProductName,
    required String? localeCode,
    required void Function(AiMealScanPhase phase)? onPhase,
  }) async {
    if (backPhoto == null && frontPhoto == null) {
      return AiLabelData(
        productName: _trimOrNull(typedProductName),
        brand: _trimOrNull(typedBrand),
      );
    }
    final identify = backPhoto == null;
    onPhase?.call(
      identify ? AiMealScanPhase.identifying : AiMealScanPhase.reading,
    );
    final system = identify ? scanIdentifySystemPrompt : scanLabelSystemPrompt;
    return AiLabelData.fromToolArguments(
      await api.requestToolJson(
        system: localeCode == null
            ? system
            : '$system\nThe user\'s app language is "$localeCode".',
        userPrompt: identify
            ? 'Identify this food.'
            : 'Transcribe this product\'s label.',
        photos: [?backPhoto, ?frontPhoto],
        toolName: identify ? scanIdentifyToolName : scanLabelToolName,
        toolDescription: identify
            ? scanIdentifyToolDescription
            : scanLabelToolDescription,
        toolSchema: scanLabelToolSchema,
      ),
    );
  }

  static String? _trimOrNull(String raw) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Barcode lookup first — an exact product beats any text search — then a
  /// name search seeded with whatever identity exists.
  ///
  /// Every lookup failure is logged and swallowed: research is an
  /// enhancement, and a network that cannot reach OFF still gets a scan
  /// whose gaps the merge step estimates, rather than a dead end.
  Future<List<AiFoodRecord>> _researchRecords({
    required AiLabelData label,
    required String typedBrand,
    required String typedProductName,
  }) async {
    final records = <AiFoodRecord>[];
    if (label.barcode case final code?) {
      try {
        records.addAll(await _research.byBarcode(code));
      } catch (e, stackTrace) {
        _log.info('Barcode research failed', e, stackTrace);
      }
    }
    final query = _researchQuery(
      label: label,
      typedBrand: typedBrand,
      typedProductName: typedProductName,
    );
    if (query.isEmpty) return records;
    try {
      records.addAll(await _research.byName(query));
    } catch (e, stackTrace) {
      _log.info('Name research failed', e, stackTrace);
    }
    return records;
  }

  /// The product identity every research path searches with: brand first,
  /// then the name — and a typed product name outranks the OCR's reading of
  /// it, because the user bought the thing and is looking at the can while
  /// typing.
  String _researchQuery({
    required AiLabelData label,
    required String typedBrand,
    required String typedProductName,
  }) {
    final productName = typedProductName.trim().isNotEmpty
        ? typedProductName.trim()
        : label.productName;
    return [
      ?label.brand,
      if (label.brand == null && typedBrand.trim().isNotEmpty)
        typedBrand.trim(),
      ?productName,
    ].join(' ').trim();
  }

  /// The label every web-sourced record carries — and how the record split
  /// above recognises its own record.
  static const webSearchSourceLabel = 'Web search';

  /// One web lookup, one extraction call over what it found.
  ///
  /// The search itself never throws ([AiMealWebSearch]); the extraction is
  /// a model call and can, so it is caught here — the web step is an
  /// enhancement stacked on an enhancement, and losing it must cost a scan
  /// nothing. A null record (nothing configured, nothing found, nothing
  /// stated) drops the scan straight back onto the merge's estimates.
  Future<AiFoodRecord?> _webRecord({
    required StructuredToolApi api,
    required AiLabelData label,
    required String typedBrand,
    required String typedProductName,
    required String? localeCode,
  }) async {
    final query = _researchQuery(
      label: label,
      typedBrand: typedBrand,
      typedProductName: typedProductName,
    );
    if (query.isEmpty) return null;
    // The nutrition word keeps results on nutrition pages rather than the
    // brand's marketing, in the language the user scans under — a German
    // product answers to German pages, and the word is the only locale
    // hint this sends. A `language` parameter was tried and dropped: it
    // made the instance's bing engine answer zero results for a query the
    // same engine answered well without it.
    final nutritionWord = localeCode == 'de' ? 'Nährwerte' : 'nutrition';
    final hits = await _webSearch.search('$query $nutritionWord');
    if (hits.isEmpty) return null;
    try {
      final extracted = aiScanNutrientsFrom(
        (await api.requestToolJson(
          system: localeCode == null
              ? scanWebExtractSystemPrompt
              : '$scanWebExtractSystemPrompt\nThe user\'s app language is '
                    '"$localeCode".',
          userPrompt: jsonEncode({
            'product': {'name': label.productName, 'brand': label.brand},
            'results': [
              for (final hit in hits)
                {'title': hit.title, 'snippet': hit.snippet, 'url': hit.url},
            ],
          }),
          photos: const [],
          toolName: scanWebExtractToolName,
          toolDescription: scanWebExtractToolDescription,
          toolSchema: scanWebExtractToolSchema,
        ))['nutrients'],
      );
      if (extracted.isEmpty) return null;
      return AiFoodRecord(webSearchSourceLabel, query, extracted);
    } catch (e, stackTrace) {
      _log.info('Web research failed', e, stackTrace);
      return null;
    }
  }
}

/// [AiMealResearch] over the app's own [ProductsRepository].
class ProductsRepositoryAiMealResearch implements AiMealResearch {
  final ProductsRepository _repository;

  ProductsRepositoryAiMealResearch(this._repository);

  @override
  Future<List<AiFoodRecord>> byBarcode(String barcode) async {
    try {
      final meal = await _repository.getOFFProductByBarcode(barcode);
      final record = _record('Open Food Facts (barcode match)', meal);
      return record == null ? const [] : [record];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<AiFoodRecord>> byName(String query) async {
    // Both sources in flight together: they answer the same question of
    // different corpora and neither depends on the other.
    final (off, sp) = await (
      _repository
          .getOFFProductsByString(query)
          .catchError((_) => <MealEntity>[]),
      _repository
          .getSupabaseFoodsByString(query)
          .catchError((_) => <MealEntity>[]),
    ).wait;
    return [
      for (final meal in off.take(AiMealScanUseCase._recordsPerSource))
        ?_record('Open Food Facts', meal),
      for (final meal in sp.take(AiMealScanUseCase._recordsPerSource))
        ?_record('USDA FDC / BLS', meal),
    ];
  }

  /// A record only counts when it measured something — a name alone would
  /// just be a distractor in the merge prompt.
  ///
  /// The macros are named fields on the entity; every other key goes
  /// through the same `micronutrientByKey` the edit form writes through.
  static const _macroKeys = {
    'energyKcal100',
    'carbohydrates100',
    'fat100',
    'proteins100',
  };

  static AiFoodRecord? _record(String sourceLabel, MealEntity meal) {
    final nutrients = <String, double>{
      'energyKcal100': ?meal.nutriments.energyKcal100,
      'carbohydrates100': ?meal.nutriments.carbohydrates100,
      'fat100': ?meal.nutriments.fat100,
      'proteins100': ?meal.nutriments.proteins100,
      for (final key in aiScanNutrientUnits.keys)
        if (!_macroKeys.contains(key))
          key: ?meal.nutriments.micronutrientByKey(key),
    };
    if (nutrients.isEmpty) return null;
    return AiFoodRecord(sourceLabel, meal.name ?? '', nutrients);
  }
}
