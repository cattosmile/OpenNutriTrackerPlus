import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/core/data/dbo/intake_dbo.dart';
import 'package:opennutritracker/core/data/dbo/intake_type_dbo.dart';
import 'package:opennutritracker/core/data/dbo/meal_dbo.dart';
import 'package:opennutritracker/core/data/dbo/meal_nutriments_dbo.dart';
import 'package:opennutritracker/core/data/dbo/tracked_day_dbo.dart';
import 'package:opennutritracker/core/domain/entity/intake_entity.dart';
import 'package:opennutritracker/core/utils/tracked_day_boundary_repair.dart';

MealDBO _meal({
  double kcal = 100,
  double carbs = 10,
  double fat = 2,
  double protein = 5,
}) => MealDBO(
  code: 'repair-meal',
  name: 'Repair Meal',
  brands: null,
  thumbnailImageUrl: null,
  mainImageUrl: null,
  url: null,
  mealQuantity: '100',
  mealUnit: 'g',
  servingQuantity: null,
  servingUnit: 'g',
  servingSize: null,
  nutriments: MealNutrimentsDBO(
    energyKcal100: kcal,
    carbohydrates100: carbs,
    fat100: fat,
    proteins100: protein,
    sugars100: null,
    saturatedFat100: null,
    fiber100: null,
  ),
  source: MealSourceDBO.custom,
);

IntakeEntity _intake(DateTime at, {double kcal = 100}) =>
    IntakeEntity.fromIntakeDBO(
      IntakeDBO(
        id: 'i-${at.millisecondsSinceEpoch}-${kcal.toInt()}',
        unit: 'g',
        amount: 100,
        type: IntakeTypeDBO.snack,
        meal: _meal(kcal: kcal),
        dateTime: at,
      ),
    );

TrackedDayDBO _row(
  DateTime day, {
  double kcalTracked = 0,
  double calorieGoal = 2000,
}) => TrackedDayDBO(
  day: day,
  calorieGoal: calorieGoal,
  caloriesTracked: kcalTracked,
);

void main() {
  const fiveAm = 5 * 60;

  test(
    're-keys a wall-keyed row to the logical day and rebuilds totals',
    () async {
      final intakes = [
        // Logged at 00:30 on the 20th: wall row "20th", logical day 19th.
        _intake(DateTime(2026, 10, 20, 0, 30), kcal: 210),
        // Daytime log on the 20th: stays on the 20th.
        _intake(DateTime(2026, 10, 20, 13, 0), kcal: 500),
      ];
      // What the pre-fix write path produced: totals on wall keys.
      final rows = [
        _row(DateTime(2026, 10, 20), kcalTracked: 710), // both meals, wrong
      ];

      final saved = <TrackedDayDBO>[];
      await TrackedDayBoundaryRepair.repair(
        intakes: intakes,
        rows: rows,
        offsetTotalMinutes: fiveAm,
        saveRow: (row) async { saved.add(row); },
      );

      // The single row's day had intakes (the 00:30 one belongs to the
      // 19th, the 13:00 one to the 20th): only 500 remains on the 20th.
      final row20 = rows.single;
      expect(row20.caloriesTracked, 500);

      // A new row appears for the 19th carrying the 00:30 meal, with the
      // donor's goal.
      final row19 = saved.firstWhere(
        (r) => r.day.year == 2026 && r.day.month == 10 && r.day.day == 19,
      );
      expect(row19.caloriesTracked, 210);
      expect(row19.calorieGoal, 2000);
    },
  );

  test('a row whose day has no intakes is zeroed, goals untouched', () async {
    final rows = [
      _row(DateTime(2026, 10, 20), kcalTracked: 710, calorieGoal: 1800),
    ];
    final saved = <TrackedDayDBO>[];

    await TrackedDayBoundaryRepair.repair(
      intakes: const [],
      rows: rows,
      offsetTotalMinutes: fiveAm,
      saveRow: (row) async { saved.add(row); },
    );

    expect(rows.single.caloriesTracked, 0);
    expect(rows.single.calorieGoal, 1800);
    // The zeroed row itself is the only write.
    expect(saved, hasLength(1));
    expect(identical(saved.single, rows.single), isTrue);
  });

  test('idempotent: a second run changes nothing', () async {
    final intakes = [_intake(DateTime(2026, 10, 20, 0, 30), kcal: 210)];
    final rows = [_row(DateTime(2026, 10, 20))];
    final saved = <TrackedDayDBO>[];

    await TrackedDayBoundaryRepair.repair(
      intakes: intakes,
      rows: rows,
      offsetTotalMinutes: fiveAm,
      saveRow: (row) async { saved.add(row); },
    );
    expect(saved.length, 2); // zeroed 20th + created 19th

    // A second pass sees the post-repair state, as the box would now
    // hold it: nothing may change.
    final saved2 = <TrackedDayDBO>[];
    await TrackedDayBoundaryRepair.repair(
      intakes: intakes,
      rows: [...rows, ...saved],
      offsetTotalMinutes: fiveAm,
      saveRow: (row) async { saved2.add(row); },
    );

    expect(saved2, isEmpty);
    // And the created row still carries its totals.
    final row19 = saved.last;
    expect(row19.caloriesTracked, 210);
  });

  test('zero offset: totals equal the wall-day sums', () async {
    final intakes = [
      _intake(DateTime(2026, 10, 20, 0, 30), kcal: 210),
      _intake(DateTime(2026, 10, 20, 13, 0), kcal: 500),
    ];
    final rows = [_row(DateTime(2026, 10, 20), kcalTracked: 710)];
    final saved = <TrackedDayDBO>[];

    await TrackedDayBoundaryRepair.repair(
      intakes: intakes,
      rows: rows,
      offsetTotalMinutes: 0,
      saveRow: (row) async { saved.add(row); },
    );

    expect(rows.single.caloriesTracked, 710);
    // No new day appears; the only write refreshes macros from sums.
    expect(saved, hasLength(1));
    expect(identical(saved.single, rows.single), isTrue);
  });

  test('back-dated label intakes keep their own day', () async {
    final intakes = [
      // A diary back-date: bare midnight is a label, not a moment.
      _intake(DateTime(2026, 10, 15), kcal: 300),
    ];
    final rows = [_row(DateTime(2026, 10, 15), kcalTracked: 300)];
    final saved = <TrackedDayDBO>[];

    await TrackedDayBoundaryRepair.repair(
      intakes: intakes,
      rows: rows,
      offsetTotalMinutes: fiveAm,
      saveRow: (row) async { saved.add(row); },
    );

    expect(rows.single.caloriesTracked, 300);
    // Label day keeps its totals — only the macro refresh writes.
    expect(saved.where((r) => !identical(r, rows.single)), isEmpty);
  });

  test('macros are rebuilt alongside calories', () async {
    final intakes = [_intake(DateTime(2026, 10, 20, 0, 30))];
    final rows = [
      _row(DateTime(2026, 10, 20))
        ..carbsTracked = 10
        ..fatTracked = 2
        ..proteinTracked = 5,
    ];
    final saved = <TrackedDayDBO>[];

    await TrackedDayBoundaryRepair.repair(
      intakes: intakes,
      rows: rows,
      offsetTotalMinutes: fiveAm,
      saveRow: (row) async { saved.add(row); },
    );

    // Day 20 now has no intakes: macros zeroed there …
    expect(rows.single.carbsTracked, 0);
    expect(rows.single.proteinTracked, 0);
    // … and moved onto the newly created 19th.
    final row19 = saved.firstWhere(
      (r) =>
          r.day.year == 2026 &&
          r.day.month == 10 &&
          r.day.day == 19,
    );
    expect(row19.carbsTracked, 10);
    expect(row19.fatTracked, 2);
    expect(row19.proteinTracked, 5);
  });
}
