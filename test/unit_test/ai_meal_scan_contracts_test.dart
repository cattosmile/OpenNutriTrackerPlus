import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/edit_meal/domain/ai_meal_scan.dart';

/// The Dart-side enforcement of both tool schemas: unknown keys drop,
/// unreadable and negative numbers drop, a barcode only survives shape
/// checking, and the final result's precedence — label verbatim, then the
/// merged value tagged by what the research actually held — is computed
/// here rather than trusted from the model.
void main() {
  group('aiScanNumber', () {
    test('accepts ints, doubles and comma strings', () {
      expect(aiScanNumber(26), 26);
      expect(aiScanNumber(1.5), 1.5);
      expect(aiScanNumber('1,5'), 1.5);
      expect(aiScanNumber(' 2 '), 2);
    });

    test('drops negatives, NaN, infinity and non-numbers', () {
      expect(aiScanNumber(-1), isNull);
      expect(aiScanNumber(double.nan), isNull);
      expect(aiScanNumber(double.infinity), isNull);
      expect(aiScanNumber('abc'), isNull);
      expect(aiScanNumber(null), isNull);
      expect(aiScanNumber(true), isNull);
    });
  });

  group('AiLabelData.fromToolArguments', () {
    test('keeps known nutrient keys and drops unknown ones', () {
      final label = AiLabelData.fromToolArguments({
        'productName': 'Thunfisch',
        'nutrients': {
          'energyKcal100': 116,
          'selenium100': '20',
          'calories': 999,
          'iron100': -5,
        },
      });
      expect(label.productName, 'Thunfisch');
      expect(label.nutrients['energyKcal100'], 116);
      expect(label.nutrients['selenium100'], 20);
      expect(label.nutrients.containsKey('calories'), isFalse);
      expect(label.nutrients.containsKey('iron100'), isFalse);
    });

    test('a barcode survives only as shape-checked digits', () {
      expect(
        AiLabelData.fromToolArguments({'barcode': '4000417025006'}).barcode,
        '4000417025006',
      );
      // Spaces and separators are stripped; the digits underneath count.
      expect(
        AiLabelData.fromToolArguments({'barcode': '40 0041-7025'}).barcode,
        '4000417 025'.replaceAll(' ', ''),
      );
      // Too short to be a retail code reads as absent.
      expect(
        AiLabelData.fromToolArguments({'barcode': '1234'}).barcode,
        isNull,
      );
    });

    test('blank strings read as null, isDrink only when true', () {
      final label = AiLabelData.fromToolArguments({
        'productName': '  ',
        'brand': 'Kaak',
        'isDrink': true,
      });
      expect(label.productName, isNull);
      expect(label.brand, 'Kaak');
      expect(label.isDrink, isTrue);
      expect(
        AiLabelData.fromToolArguments({'isDrink': 'yes'}).isDrink,
        isFalse,
      );
    });
  });

  group('AiMealScanResult.build', () {
    final label = AiLabelData.fromToolArguments({
      'productName': 'Thunfisch',
      'nutrients': {'energyKcal100': 116, 'proteins100': 26},
    });
    final merged = AiMergedNutrients.fromToolArguments({
      'nutrients': {
        // The model "preferred its own idea" over the photograph — the
        // build must keep the label value.
        'energyKcal100': 200,
        'proteins100': 26,
        'selenium100': 60,
        'iodine100': 25,
      },
      'matchedFoodName': 'Thunfisch in Wasser',
    });

    test('label value wins verbatim over the merged value', () {
      final result = AiMealScanResult.build(
        label: label,
        databaseNutrients: const {},
        merged: merged,
      );
      expect(result.nutrients['energyKcal100'], 116);
      expect(result.sources['energyKcal100'], AiLabelValueSource.label);
    });

    test('a merged value is tagged database when research held the key', () {
      final result = AiMealScanResult.build(
        label: label,
        databaseNutrients: const {'selenium100': 55},
        merged: merged,
      );
      expect(result.nutrients['selenium100'], 60);
      expect(result.sources['selenium100'], AiLabelValueSource.database);
    });

    test('a merged value nobody measured is tagged estimated', () {
      final result = AiMealScanResult.build(
        label: label,
        databaseNutrients: const {},
        merged: merged,
      );
      expect(result.sources['iodine100'], AiLabelValueSource.estimated);
      expect(result.matchedFoodName, 'Thunfisch in Wasser');
      expect(result.name, 'Thunfisch');
    });

    test('a key the merge omitted falls back to the record, in Dart', () {
      // `merged` above carries no chromium; a record measured it. The
      // merge's own precedence says the record beats estimation, so the
      // value still lands — without a second model call.
      final result = AiMealScanResult.build(
        label: label,
        databaseNutrients: const {'chromium100': 2},
        merged: merged,
      );
      expect(result.nutrients['chromium100'], 2);
      expect(result.sources['chromium100'], AiLabelValueSource.database);
    });

    test('the user\'s typed portion is carried through untouched', () {
      final result = AiMealScanResult.build(
        label: label,
        databaseNutrients: const {},
        merged: merged,
        userPortionGrams: 92.5,
      );
      expect(result.userPortionGrams, 92.5);
    });
  });

  group('schema absent-policy', () {
    // The live failure behind this: glm-5.3-flash followed the merge
    // schema's per-key "omit when not readable on the label" wording and
    // returned 42 of 44 nutrients, so folate and choline reached the form
    // as empty fields the user had watched being estimated.
    Map<String, dynamic> nutrientPropertiesOf(Map<String, Object> schema) =>
        ((schema['properties']! as Map<String, Object>)['nutrients']!
                as Map<String, dynamic>)['properties']!
            as Map<String, dynamic>;

    test('the merge schema demands every nutrient key back', () {
      final nutrients =
          (mergeNutrientsToolSchema['properties']!
                  as Map<String, Object>)['nutrients']!
              as Map<String, dynamic>;
      expect(
        nutrients['required'],
        unorderedEquals(aiScanNutrientUnits.keys.toList()),
      );
    });

    test('the merge schema never tells the model to omit a key', () {
      for (final prop in nutrientPropertiesOf(
        mergeNutrientsToolSchema,
      ).values) {
        expect(
          (prop as Map)['description'],
          isNot(contains('Omit when not readable')),
        );
        expect(prop['description'], contains('Always present'));
      }
    });

    test('the OCR schema still permits omission — it is transcription', () {
      expect(
        nutrientPropertiesOf(scanLabelToolSchema)['iron100']['description'],
        contains('Omit when not readable on the label'),
      );
    });
  });
}
