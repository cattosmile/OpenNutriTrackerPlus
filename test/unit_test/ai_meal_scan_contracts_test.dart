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
        AiLabelData.fromToolArguments({
          'barcode': '4000417025006',
        }).barcode,
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
  });
}
