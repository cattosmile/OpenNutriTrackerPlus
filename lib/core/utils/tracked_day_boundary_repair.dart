import 'package:logging/logging.dart';
import 'package:opennutritracker/core/data/dbo/tracked_day_dbo.dart';
import 'package:opennutritracker/core/domain/entity/intake_entity.dart';
import 'package:opennutritracker/core/utils/calc/day_boundary_calc.dart';

/// Re-aggregates the per-day tracked totals under the currently configured
/// day boundary.
///
/// #139 made the diary's *reads* boundary-aware, but the tracked-day rows
/// were keyed by the wall-clock date of the logging moment. With a 05:00
/// day start, a meal logged at 00:30 raised the *next* wall-clock day's
/// row while every reader filed it under the previous logical day —
/// diary and trends disagreed with home. The write path now resolves the
/// key through [DayBoundaryCalc.dayKeyFor]; this pass brings rows that
/// were written before that fix (or under a since-changed boundary) back
/// in line.
///
/// It is safe to run on every app start:
///  * tracked totals come only from intake add/remove, so they are
///    rebuilt exactly from the intake list — an empty day means a true 0,
///    and goals are never touched;
///  * rows are never deleted, so activity-reduced or goal-only days keep
///    their data — at worst an old row becomes a harmless empty cell;
///  * a day whose bucket has no row yet gets one, inheriting its goals
///    from the nearest existing row (goals barely vary day to day).
class TrackedDayBoundaryRepair {
  TrackedDayBoundaryRepair._();

  static final _log = Logger('TrackedDayBoundaryRepair');

  /// Runs the repair over the full intake and tracked-day collections.
  /// [saveRow] persists a mutated row (the Hive box put).
  static Future<void> repair({
    required List<IntakeEntity> intakes,
    required List<TrackedDayDBO> rows,
    required int offsetTotalMinutes,
    required Future<void> Function(TrackedDayDBO row) saveRow,
  }) async {
    final buckets = <DateTime, _DayTotals>{};
    for (final intake in intakes) {
      final day = DayBoundaryCalc.dayKeyFor(
        intake.dateTime,
        offsetTotalMinutes,
      );
      final bucket = buckets.putIfAbsent(
        day,
        () => _DayTotals(kcal: 0, carbs: 0, fat: 0, protein: 0),
      );
      bucket.kcal += intake.totalKcal;
      bucket.carbs += intake.totalCarbsGram;
      bucket.fat += intake.totalFatsGram;
      bucket.protein += intake.totalProteinsGram;
    }

    final rowsByDay = {
      for (final row in rows)
        DateTime(row.day.year, row.day.month, row.day.day): row,
    };

    var changed = 0;

    // Every existing row gets its totals straight from the intake sums —
    // exact for correct rows, the fix for mis-keyed ones. A row whose day
    // has no intakes carries a true 0 (tracked totals only ever move with
    // intake add/remove); its goals are left alone.
    for (final entry in rowsByDay.entries) {
      final row = entry.value;
      final bucket = buckets.remove(entry.key);
      final kcal = bucket?.kcal ?? 0.0;
      final carbs = bucket?.carbs ?? 0.0;
      final fat = bucket?.fat ?? 0.0;
      final protein = bucket?.protein ?? 0.0;
      if (row.caloriesTracked != kcal ||
          row.carbsTracked != carbs ||
          row.fatTracked != fat ||
          row.proteinTracked != protein) {
        row
          ..caloriesTracked = kcal
          ..carbsTracked = carbs
          ..fatTracked = fat
          ..proteinTracked = protein;
        await saveRow(row);
        changed++;
      }
    }

    // Days with intakes but no row yet (all their logs were filed under a
    // neighbouring key before the fix, or the boundary moved). Inherit
    // goals from the nearest row — the wall row the late-night logs
    // created is usually the day after — so the calendar keeps a goal.
    for (final entry in buckets.entries) {
      final donor = _nearestRow(rowsByDay.values, entry.key);
      final row = TrackedDayDBO(
        day: entry.key,
        calorieGoal: donor?.calorieGoal ?? 0,
        carbsGoal: donor?.carbsGoal,
        fatGoal: donor?.fatGoal,
        proteinGoal: donor?.proteinGoal,
        caloriesTracked: entry.value.kcal,
        carbsTracked: entry.value.carbs,
        fatTracked: entry.value.fat,
        proteinTracked: entry.value.protein,
      );
      await saveRow(row);
      changed++;
    }

    if (changed > 0) {
      _log.info(
        'Re-aggregated $changed tracked-day rows under the '
        '${offsetTotalMinutes ~/ 60}h${offsetTotalMinutes % 60}m day boundary',
      );
    }
  }

  static TrackedDayDBO? _nearestRow(
    Iterable<TrackedDayDBO> rows,
    DateTime day,
  ) {
    TrackedDayDBO? best;
    int? bestDistance;
    for (final row in rows) {
      final distance = DateTime(
        row.day.year,
        row.day.month,
        row.day.day,
      ).difference(DateTime(day.year, day.month, day.day)).inDays.abs();
      if (bestDistance == null || distance < bestDistance) {
        best = row;
        bestDistance = distance;
      }
    }
    return best;
  }
}

class _DayTotals {
  double kcal;
  double carbs;
  double fat;
  double protein;

  _DayTotals({
    required this.kcal,
    required this.carbs,
    required this.fat,
    required this.protein,
  });
}
