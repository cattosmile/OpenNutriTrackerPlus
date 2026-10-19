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
/// mirror of USDA FDC and the German BLS. That pair *is* the "search the
/// internet for the product" step — chosen over a scraping or web-search
/// API because both databases are already wired into the app, cost nothing,
/// and answer in structured per-100 g numbers rather than prose a second
/// model would have to re-read.
abstract interface class AiMealResearch {
  Future<List<AiFoodRecord>> byBarcode(String barcode);
  Future<List<AiFoodRecord>> byName(String query);
}

/// Where a scan currently is, for the progress surface. The research step
/// has no failure state of its own — it degrades to estimation — so this is
/// narration, not state.
enum AiMealScanPhase { reading, researching, completing }

/// Reads a packaged-food label, researches the product, and completes the
/// nutrient profile.
///
/// Three steps, two of them model calls through [StructuredToolApi]:
///
/// 1. **OCR** — the back photo (front optional) is transcribed. The prompt
///    forbids estimation on this step; what the label printed is the only
///    thing that comes back.
/// 2. **Research** — no model involved. The barcode and the name the OCR
///    read are looked up in Open Food Facts and the Supabase food backend,
///    free of charge, through the same [ProductsRepository] the search tab
///    uses.
/// 3. **Merge** — a text-only call that receives the label JSON, the
///    database records and the user's hints, and fills every nutrient by
///    the precedence in its prompt.
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

  AiMealScanUseCase(this._credentials, this._apiFactory, this._research);

  Future<AiMealScanOutcome> run({
    required MealPhoto backPhoto,
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

    try {
      onPhase?.call(AiMealScanPhase.reading);
      final label = AiLabelData.fromToolArguments(
        await api.requestToolJson(
          system: localeCode == null
              ? scanLabelSystemPrompt
              : '$scanLabelSystemPrompt\nThe user\'s app language is '
                    '"$localeCode".',
          userPrompt: 'Transcribe this product\'s label.',
          photos: [backPhoto, ?frontPhoto],
          toolName: scanLabelToolName,
          toolDescription: scanLabelToolDescription,
          toolSchema: scanLabelToolSchema,
        ),
      );

      final records = await _researchRecords(
        label: label,
        typedBrand: brand,
        typedProductName: productName,
      );
      onPhase?.call(AiMealScanPhase.researching);
      final databaseNutrients = <String, double>{};
      for (final record in records) {
        databaseNutrients.addEntries(
          record.nutrients.entries.where(
            (entry) => !databaseNutrients.containsKey(entry.key),
          ),
        );
      }

      onPhase?.call(AiMealScanPhase.completing);
      final merged = AiMergedNutrients.fromToolArguments(
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
              'portionGrams': double.tryParse(
                portionGrams.replaceAll(',', '.'),
              ),
            },
            'databaseRecords': [
              for (final record in records)
                {
                  'source': record.sourceLabel,
                  'name': record.name,
                  'nutrients': record.nutrients,
                },
            ],
          }),
          photos: const [],
          toolName: mergeNutrientsToolName,
          toolDescription: mergeNutrientsToolDescription,
          toolSchema: mergeNutrientsToolSchema,
        ),
      );

      return AiMealScanDone(
        AiMealScanResult.build(
          label: label,
          databaseNutrients: databaseNutrients,
          merged: merged,
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
    // A typed product name outranks the OCR's reading of it — the user
    // bought the thing and is looking at the can while typing.
    final productName = typedProductName.trim().isNotEmpty
        ? typedProductName.trim()
        : label.productName;
    final query = [
      ?label.brand,
      if (label.brand == null && typedBrand.trim().isNotEmpty)
        typedBrand.trim(),
      ?productName,
    ].join(' ').trim();
    if (query.isEmpty) return records;
    try {
      records.addAll(await _research.byName(query));
    } catch (e, stackTrace) {
      _log.info('Name research failed', e, stackTrace);
    }
    return records;
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
