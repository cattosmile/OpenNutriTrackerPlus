import 'package:opennutritracker/core/utils/barcode_validator.dart';

/// Where one nutrient value in a scan result came from.
///
/// Ordered by trust: the label was measured by the manufacturer, a database
/// record was measured by a food authority, a web result was published by
/// whoever published it, and an estimate is the model's best knowledge.
/// Shown per value on the review card so the user knows which numbers to
/// double-check against the can in their hand.
enum AiLabelValueSource { label, database, web, estimated }

/// Every nutrient the scan can fill, keyed by the `MealNutrimentsEntity`
/// field name and valued with the unit the value is expected in.
///
/// One map drives the tool schema, both parsers and the form-fill, so a
/// nutrient cannot exist in one of those and not the others. Units are the
/// entity's own storage units — grams-scale nutrients in g, most minerals
/// in mg, trace elements and the µg vitamins in µg.
const Map<String, String> aiScanNutrientUnits = <String, String>{
  'energyKcal100': 'kcal',
  'carbohydrates100': 'g',
  'fat100': 'g',
  'proteins100': 'g',
  'fiber100': 'g',
  'saturatedFat100': 'g',
  'sugars100': 'g',
  'monounsaturatedFat100': 'g',
  'polyunsaturatedFat100': 'g',
  'transFat100': 'g',
  'cholesterol100': 'mg',
  'sodium100': 'mg',
  'potassium100': 'mg',
  'magnesium100': 'mg',
  'calcium100': 'mg',
  'phosphorus100': 'mg',
  'zinc100': 'mg',
  'iron100': 'mg',
  'chloride100': 'mg',
  'vitaminA100': 'µg',
  'vitaminC100': 'mg',
  'vitaminD100': 'µg',
  'vitaminE100': 'mg',
  'vitaminK100': 'µg',
  'vitaminB1100': 'mg',
  'vitaminB2100': 'mg',
  'niacin100': 'mg',
  'vitaminB5100': 'mg',
  'vitaminB6100': 'mg',
  'vitaminB7100': 'µg',
  'vitaminB9100': 'µg',
  'vitaminB12100': 'µg',
  'choline100': 'mg',
  'copper100': 'µg',
  'manganese100': 'mg',
  'selenium100': 'µg',
  'iodine100': 'µg',
  'fluoride100': 'mg',
  'chromium100': 'µg',
  'molybdenum100': 'µg',
  'ala100': 'g',
  'epa100': 'g',
  'dha100': 'g',
  'caffeine100': 'mg',
};

const scanLabelToolName = 'read_food_label';

const scanLabelToolDescription =
    'Transcribe the packaged food label shown in the photographs.';

/// The per-nutrient schema entries, with the step's own policy on when a
/// key may be absent. The two steps disagree on purpose, and one shared
/// wording shipped a bug: the transcription rule ("omit when not readable
/// on the label") is wrong for the merge step, where every key must come
/// back — a model that followed it there returned 42 of 44 nutrients, and
/// the review card and the form silently showed the two omissions as
/// empty fields the user had watched being estimated.
Map<String, Object> _nutrientProperties(String absentPolicy) =>
    <String, Object>{
      for (final entry in aiScanNutrientUnits.entries)
        entry.key: {
          'type': 'number',
          'description':
              'Per 100 g (or 100 ml), expressed in ${entry.value}. '
              '$absentPolicy',
        },
    };

const _transcribeAbsentPolicy = 'Omit when not readable on the label.';

const _completeAbsentPolicy =
    'Always present: the label value, else a close record\'s, else your '
    'estimate.';

/// The schema of the OCR step. Like [mealItemsToolSchema] it is a hint to
/// the model while enforcement stays in Dart — [AiLabelData.fromToolArguments]
/// drops every key it does not know and every value it cannot read as a
/// non-negative number.
Map<String, Object> get scanLabelToolSchema => <String, Object>{
  'type': 'object',
  'properties': {
    'productName': {
      'type': 'string',
      'description':
          'The product name as printed. Empty string when unreadable.',
    },
    'brand': {
      'type': 'string',
      'description': 'The brand as printed, no supermarket. Empty when absent.',
    },
    'barcode': {
      'type': 'string',
      'description': 'Retail barcode digits if legible, digits only.',
    },
    'isDrink': {
      'type': 'boolean',
      'description': 'True for beverages; false for everything else.',
    },
    'packageSizeGrams': {
      'type': 'number',
      'description':
          'Total content of the package in g (ml for drinks). Omit when '
          'not stated.',
    },
    'servingSizeGrams': {
      'type': 'number',
      'description':
          'One stated portion/serving in g (ml for drinks). Omit when not '
          'stated.',
    },
    'nutrients': {
      'type': 'object',
      'properties': _nutrientProperties(_transcribeAbsentPolicy),
    },
  },
  'required': ['nutrients'],
};

const scanLabelSystemPrompt = '''
You read packaged-food labels from photographs so the values can be
transcribed into a nutrition tracker. You transcribe; you never estimate on
this step.

Rules:
- The photographs show the back of one packaged product (nutrition table)
  first, then optionally its front.
- Read the per-100 g / per-100 ml column when the label prints both
  per-100 and per-portion values (EU labels carry both). When only
  per-serving values are printed (typical US label), convert them to per
  100 g using the stated serving and package sizes.
- Express each nutrient in the unit its schema entry names. Convert printed
  units when they differ (g vs mg vs µg; kJ to kcal with 1 kcal = 4.184 kJ).
- Include a nutrient only when you can actually read it on the label. An
  unreadable cell is omitted, never guessed — a later step fills gaps.
- Sodium: when only salt (g) is printed, sodium (mg) = salt (g) x 400.
- packageSizeGrams / servingSizeGrams: the total content and one stated
  portion, in g (ml for drinks).
- isDrink: true for beverages (water, juice, soda, milk drinks), false
  otherwise.''';

const scanIdentifyToolName = 'identify_food_photo';

const scanIdentifyToolDescription =
    'Identify the unpackaged food shown in the photograph.';

/// The photo-first half of a scan without a nutrition table: a bakery roll,
/// a piece from the display case, anything that never carried printed
/// values. Reuses [scanLabelToolSchema] — every field it carries is one this
/// step can honestly answer, and `nutrients` comes back empty because the
/// prompt forbids estimating here, exactly as the OCR step does.
const scanIdentifySystemPrompt = '''
You look at photographs of food that carries no nutrition table — a bakery
item, food from a display or counter, a home-cooked dish — so a nutrition
tracker can search for it. You identify; you never estimate on this step.

Rules:
- The photograph shows the food itself.
- productName: what the food is, as a shopper would name it in the local
  language ("Laugenbrötchen"). Keep a visible variety or topping in the name
  ("Vollkornbrötchen", "Käsebrötchen").
- brand: only when the photograph itself shows one — a wrapper, a bag, a
  shop sign. Empty when none is visible.
- isDrink: true for beverages, false otherwise.
- nutrients, packageSizeGrams, servingSizeGrams: a food without a printed
  table states none of these. Return them empty — never estimate here;
  later steps research and fill.''';

const mergeNutrientsToolName = 'complete_food_nutrients';

const mergeNutrientsToolDescription =
    'Complete the per-100 g nutrient profile of one packaged food.';

Map<String, Object> get mergeNutrientsToolSchema => <String, Object>{
  'type': 'object',
  'properties': {
    'nutrients': {
      'type': 'object',
      'properties': _nutrientProperties(_completeAbsentPolicy),
      // Every key named required: the merge exists to fill gaps, so an
      // omitted key is a failed answer, not a "not stated" — the same
      // words the OCR schema uses to permit omission are withheld here.
      'required': [...aiScanNutrientUnits.keys],
      'description':
          'Every nutrient, filled from the label first, then the database '
          'records, then estimation.',
    },
    'matchedFoodName': {
      'type': 'string',
      'description':
          'The database product relied on most, when one was. Omit '
          'otherwise.',
    },
  },
  'required': ['nutrients'],
};

const mergeNutrientsSystemPrompt = '''
You complete the nutrition profile of one packaged food for a nutrition
tracker. You receive the label values transcribed from the packaging (per
100 g/ml), optional hints from the user, and database records for the same
or similar products (per 100 g). Return every nutrient in the schema —
omitting one is a failed answer, not a cautious one: when neither the label
nor any record has it, estimate it.

Precedence:
1. Label values were measured by the manufacturer. Copy them unchanged and
   never adjust one, even when a database record disagrees.
2. For nutrients missing from the label, prefer a record of the same product
   or a very close match (same food, same brand). Between records, a
   brand-specific one — database or web — beats a generic category one.
3. Estimate yourself only where neither the label nor any record has the
   nutrient, from food-composition knowledge. Zero is a legitimate value
   only when the food credibly contains none (cholesterol in a plant
   product, vitamin B12 in an unfortified plant product); otherwise give a
   plausible small amount rather than defaulting to 0.
- All values per 100 g/ml, in the unit each schema entry names.
- Derive energyKcal100 from the macros (4 x carbohydrates + 4 x protein +
  9 x fat) within +-5% whenever the label did not state energy. Keep a
  stated label energy as printed even when it deviates — fibre, polyols
  and legal rounding make real labels deviate.
- The supermarket hint disambiguates store brands; the portion hint is the
  user's own serving, not the package.
- The precedence above is mechanical: copy, pick, estimate. Decide each
  nutrient once and move on — deliberating twice only costs the user's
  time.''';

const scanGapFillToolName = 'estimate_missing_nutrients';

const scanGapFillToolDescription =
    'Estimate the few per-100 g nutrients still missing for one food.';

/// The schema of the gap-fill follow-up: exactly the keys the merge step
/// omitted despite its `required` list — measured against the live model,
/// that omission is stochastic (three of four runs complete, one short by
/// one to three keys), so the pipeline asks again for just the stragglers
/// rather than treating a 43-of-44 answer as final.
Map<String, Object> scanGapFillToolSchema(Iterable<String> keys) =>
    <String, Object>{
      'type': 'object',
      'properties': {
        'nutrients': {
          'type': 'object',
          'properties': _nutrientProperties(_completeAbsentPolicy),
          'required': [...keys],
        },
      },
      'required': ['nutrients'],
    };

const scanGapFillSystemPrompt = '''
You estimate the per-100 g nutrient content of one packaged food for a
nutrition tracker. The label has been read and the profile is nearly
complete; the schema lists exactly the nutrients still missing. Estimate
each from food-composition knowledge of this food. Zero is legitimate only
when the food credibly contains none; otherwise give a plausible small
amount. All values per 100 g/ml, in the unit each schema entry names.
Decide each nutrient once — no deliberation, this call should be quick.''';

const scanWebExtractToolName = 'read_web_search_results';

const scanWebExtractToolDescription =
    'Extract the per-100 g nutrient values web-search results actually state '
    'for one packaged food.';

/// The web step's absent policy, third of the three on purpose. The OCR
/// step omits what the label did not print; the merge step must return
/// everything; this step omits what no search result stated — a number the
/// web did not print is worth nothing here, because the whole point of the
/// step is stated values instead of the merge's estimates.
const _webStatedAbsentPolicy =
    'Omit when no result states the nutrient — never estimate it here.';

Map<String, Object> get scanWebExtractToolSchema => <String, Object>{
  'type': 'object',
  'properties': {
    'nutrients': {
      'type': 'object',
      'properties': _nutrientProperties(_webStatedAbsentPolicy),
    },
  },
  'required': ['nutrients'],
};

const scanWebExtractSystemPrompt = '''
You read web-search results about one packaged food so that values someone
actually published can be transcribed into a nutrition tracker. You
transcribe; you never estimate on this step.

Rules:
- Each result carries a title, a snippet and its URL. Snippets are short:
  use exactly what a result states, and never infer a number none of them
  printed.
- Per-100 g / per-100 ml values only. Skip per-serving and per-package
  numbers unless the result also states the serving or package size the
  conversion needs.
- Express each nutrient in the unit its schema entry names, converting when
  a result prints another (g vs mg vs µg; kJ to kcal with 1 kcal = 4.184
  kJ).
- Include a nutrient only when a result states it. Omitting most nutrients
  is the expected outcome, not a failed answer — a later step fills gaps.
- Ignore results about a different product than the one named.''';

/// A number a model handed back, or null when it is not one worth keeping.
///
/// Lenient on purpose — models emit ints for whole numbers and occasionally
/// strings with a comma — and refuses negatives and non-finite values,
/// which no food label carries and a model only produces when it has
/// confused itself.
double? aiScanNumber(Object? raw) {
  final value = switch (raw) {
    num n => n.toDouble(),
    String s => double.tryParse(s.trim().replaceAll(',', '.')),
    _ => null,
  };
  if (value == null || !value.isFinite || value < 0) return null;
  return value;
}

/// The nutrients out of a tool reply, dropping every key the scan does not
/// know and every value [aiScanNumber] refuses — the same enforcement for
/// all three steps that answer nutrients: OCR, merge/gap-fill and the web
/// extraction between them.
Map<String, double> aiScanNutrientsFrom(Object? raw) {
  if (raw is! Map) return const {};
  return {
    for (final entry in raw.entries)
      if (aiScanNutrientUnits.containsKey(entry.key))
        entry.key as String: ?aiScanNumber(entry.value),
  };
}

/// What the OCR step read off the label. The consumer-facing fields are
/// separate from [nutrients] so a label that prints no name still carries
/// its table, and vice versa.
class AiLabelData {
  final String? productName;
  final String? brand;

  /// Digits only, and only when they pass the shape check the edit-meal
  /// barcode field applies — a misread digit should not reach the form.
  final String? barcode;
  final bool isDrink;
  final double? packageSizeGrams;
  final double? servingSizeGrams;
  final Map<String, double> nutrients;

  const AiLabelData({
    this.productName,
    this.brand,
    this.barcode,
    this.isDrink = false,
    this.packageSizeGrams,
    this.servingSizeGrams,
    this.nutrients = const {},
  });

  factory AiLabelData.fromToolArguments(Map<String, dynamic> raw) {
    final barcode = _sanitizeBarcode(raw['barcode']);
    return AiLabelData(
      productName: _nonEmptyString(raw['productName']),
      brand: _nonEmptyString(raw['brand']),
      barcode: barcode,
      isDrink: raw['isDrink'] == true,
      packageSizeGrams: aiScanNumber(raw['packageSizeGrams']),
      servingSizeGrams: aiScanNumber(raw['servingSizeGrams']),
      nutrients: aiScanNutrientsFrom(raw['nutrients']),
    );
  }
}

String? _nonEmptyString(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _sanitizeBarcode(Object? raw) {
  if (raw is! String) return null;
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  return isBarcodeFormatValid(digits) ? digits : null;
}

/// What the merge step concluded, and what it leaned on.
class AiMergedNutrients {
  final Map<String, double> nutrients;
  final String? matchedFoodName;

  const AiMergedNutrients({this.nutrients = const {}, this.matchedFoodName});

  factory AiMergedNutrients.fromToolArguments(Map<String, dynamic> raw) =>
      AiMergedNutrients(
        nutrients: aiScanNutrientsFrom(raw['nutrients']),
        matchedFoodName: _nonEmptyString(raw['matchedFoodName']),
      );
}

/// The finished scan, ready to prefill the edit-meal form.
///
/// [nutrients] holds the final per-100 value per entity key; [sources]
/// records where each came from. Both are computed in Dart from the three
/// inputs rather than asked of the model, because the model's own account
/// of its precedence is not checkable: the label map and the research map
/// are facts this side of the wire, so the tag is derived from them.
class AiMealScanResult {
  final String? name;
  final String? brand;
  final String? barcode;
  final bool isDrink;
  final double? packageSizeGrams;
  final double? servingSizeGrams;

  /// The portion the user typed on the scan screen, if any. It is not a
  /// nutrient and no model produced it — it is carried through untouched so
  /// the form can honour it: the user's own serving outranks whatever
  /// serving the label happened to print.
  final double? userPortionGrams;
  final Map<String, double> nutrients;
  final Map<String, AiLabelValueSource> sources;
  final String? matchedFoodName;

  const AiMealScanResult({
    this.name,
    this.brand,
    this.barcode,
    this.isDrink = false,
    this.packageSizeGrams,
    this.servingSizeGrams,
    this.userPortionGrams,
    this.nutrients = const {},
    this.sources = const {},
    this.matchedFoodName,
  });

  /// Label value verbatim, else the merged value; source tagged from what
  /// each side actually contained. A web value sits below a database one —
  /// a food authority measured the one, somebody's shop page published the
  /// other — and above the merge's own estimate.
  ///
  /// A label value is kept as read even when the merge returned a
  /// different number, because "the model preferred its own idea over the
  /// photograph" is exactly the failure this ordering exists to prevent.
  static AiMealScanResult build({
    required AiLabelData label,
    required Map<String, double> databaseNutrients,
    required Map<String, double> webNutrients,
    required AiMergedNutrients merged,
    double? userPortionGrams,
  }) {
    final nutrients = <String, double>{};
    final sources = <String, AiLabelValueSource>{};
    for (final key in aiScanNutrientUnits.keys) {
      final double? value;
      final AiLabelValueSource source;
      if (label.nutrients[key] case final fromLabel?) {
        value = fromLabel;
        source = AiLabelValueSource.label;
      } else if (merged.nutrients[key] case final fromMerge?) {
        value = fromMerge;
        source = databaseNutrients.containsKey(key)
            ? AiLabelValueSource.database
            : webNutrients.containsKey(key)
            ? AiLabelValueSource.web
            : AiLabelValueSource.estimated;
      } else if (databaseNutrients[key] case final fromRecords?) {
        // The merge omitted a key a record measured. Its own precedence
        // says a record beats estimation, and applying that rule needs no
        // model — so Dart applies it. Without this, an omission the model
        // makes despite the schema's `required` list reaches the form as
        // an empty field next to numbers a record actually measured.
        value = fromRecords;
        source = AiLabelValueSource.database;
      } else if (webNutrients[key] case final fromWeb?) {
        value = fromWeb;
        source = AiLabelValueSource.web;
      } else {
        continue;
      }
      nutrients[key] = value;
      sources[key] = source;
    }
    return AiMealScanResult(
      name: label.productName,
      brand: label.brand,
      barcode: label.barcode,
      isDrink: label.isDrink,
      packageSizeGrams: label.packageSizeGrams,
      servingSizeGrams: label.servingSizeGrams,
      userPortionGrams: userPortionGrams,
      nutrients: nutrients,
      sources: sources,
      matchedFoodName: merged.matchedFoodName,
    );
  }
}
