import 'package:opennutritracker/core/data/repository/tracked_day_repository.dart';
import 'package:opennutritracker/core/domain/usecase/get_config_usecase.dart';
import 'package:opennutritracker/core/utils/calc/day_boundary_calc.dart';

/// Every write to a per-day aggregate row goes through this use case, and
/// every caller passes the moment the entry was logged (an intake's
/// dateTime) or a picked calendar date. #139 made the reads
/// boundary-aware but the writes keyed rows by the wall-clock date of that
/// moment, so a meal logged at 00:30 under a 05:00 day start landed on the
/// next day's row while every reader filed it under the previous logical
/// day — diary and trends disagreed with home. Resolving the key here
/// fixes all writers at once; a bare-midnight date label (a picked day,
/// see [DayBoundaryCalc.dayKeyFor]) passes through untouched.
class AddTrackedDayUsecase {
  final TrackedDayRepository _trackedDayRepository;
  final GetConfigUsecase? _getConfigUsecase;

  /// [getConfigUsecase] is optional only so test doubles and legacy
  /// constructions keep compiling; without it the boundary offset reads
  /// as 0 (wall-clock days). Production wiring always passes it.
  AddTrackedDayUsecase(this._trackedDayRepository, [this._getConfigUsecase]);

  Future<DateTime> _keyFor(DateTime day) async {
    final getConfig = _getConfigUsecase;
    if (getConfig == null) return DayBoundaryCalc.dayKeyFor(day, 0);
    final config = await getConfig.getConfig();
    return DayBoundaryCalc.dayKeyFor(day, config.dayStartOffsetTotalMinutes);
  }

  Future<void> updateDayCalorieGoal(DateTime day, double calorieGoal) async {
    await _trackedDayRepository.updateDayCalorieGoal(
      await _keyFor(day),
      calorieGoal,
    );
  }

  Future<void> increaseDayCalorieGoal(DateTime day, double amount) async {
    await _trackedDayRepository.increaseDayCalorieGoal(
      await _keyFor(day),
      amount,
    );
  }

  Future<void> reduceDayCalorieGoal(DateTime day, double amount) async {
    await _trackedDayRepository.reduceDayCalorieGoal(
      await _keyFor(day),
      amount,
    );
  }

  Future<bool> hasTrackedDay(DateTime day) async {
    return await _trackedDayRepository.hasTrackedDay(await _keyFor(day));
  }

  Future<void> addNewTrackedDay(
    DateTime day,
    double totalKcalGoal,
    double totalCarbsGoal,
    double totalFatGoal,
    double totalProteinGoal,
  ) async {
    return await _trackedDayRepository.addNewTrackedDay(
      await _keyFor(day),
      totalKcalGoal,
      totalCarbsGoal,
      totalFatGoal,
      totalProteinGoal,
    );
  }

  Future<void> addDayCaloriesTracked(
    DateTime day,
    double caloriesTracked,
  ) async {
    await _trackedDayRepository.addDayTrackedCalories(
      await _keyFor(day),
      caloriesTracked,
    );
  }

  Future<void> removeDayCaloriesTracked(
    DateTime day,
    double caloriesTracked,
  ) async {
    await _trackedDayRepository.removeDayTrackedCalories(
      await _keyFor(day),
      caloriesTracked,
    );
  }

  Future<void> updateDayMacroGoals(
    DateTime day, {
    double? carbsGoal,
    double? fatGoal,
    double? proteinGoal,
  }) async {
    await _trackedDayRepository.updateDayMacroGoal(
      await _keyFor(day),
      carbGoal: carbsGoal,
      fatGoal: fatGoal,
      proteinGoal: proteinGoal,
    );
  }

  Future<void> increaseDayMacroGoals(
    DateTime day, {
    double? carbsAmount,
    double? fatAmount,
    double? proteinAmount,
  }) async {
    await _trackedDayRepository.increaseDayMacroGoal(
      await _keyFor(day),
      carbGoal: carbsAmount,
      fatGoal: fatAmount,
      proteinGoal: proteinAmount,
    );
  }

  Future<void> reduceDayMacroGoals(
    DateTime day, {
    double? carbsAmount,
    double? fatAmount,
    double? proteinAmount,
  }) async {
    await _trackedDayRepository.reduceDayMacroGoal(
      await _keyFor(day),
      carbGoal: carbsAmount,
      fatGoal: fatAmount,
      proteinGoal: proteinAmount,
    );
  }

  Future<void> addDayMacrosTracked(
    DateTime day, {
    double? carbsTracked,
    double? fatTracked,
    double? proteinTracked,
  }) async {
    await _trackedDayRepository.addDayMacrosTracked(
      await _keyFor(day),
      carbsTracked: carbsTracked,
      fatTracked: fatTracked,
      proteinTracked: proteinTracked,
    );
  }

  Future<void> removeDayMacrosTracked(
    DateTime day, {
    double? carbsTracked,
    double? fatTracked,
    double? proteinTracked,
  }) async {
    await _trackedDayRepository.removeDayMacrosTracked(
      await _keyFor(day),
      carbsTracked: carbsTracked,
      fatTracked: fatTracked,
      proteinTracked: proteinTracked,
    );
  }

  /// #173 (+follow-up): persist user-configured per-nutrient goals for
  /// the day. Each argument is optional; passing null leaves that
  /// nutrient's stored goal alone. Null on disk means "use the default
  /// reference". Covers the original three (fibre / sat fat / sugars)
  /// plus the seven follow-up nutrients (sodium, calcium, iron,
  /// potassium, vitamin D, vitamin B12, magnesium).
  Future<void> updateDayNutrientGoals(
    DateTime day, {
    double? fibreGoal,
    double? satFatGoal,
    double? sugarsGoal,
    double? sodiumGoal,
    double? calciumGoal,
    double? ironGoal,
    double? potassiumGoal,
    double? vitaminDGoal,
    double? vitaminB12Goal,
    double? magnesiumGoal,
  }) async {
    await _trackedDayRepository.updateDayNutrientGoals(
      await _keyFor(day),
      fibreGoal: fibreGoal,
      satFatGoal: satFatGoal,
      sugarsGoal: sugarsGoal,
      sodiumGoal: sodiumGoal,
      calciumGoal: calciumGoal,
      ironGoal: ironGoal,
      potassiumGoal: potassiumGoal,
      vitaminDGoal: vitaminDGoal,
      vitaminB12Goal: vitaminB12Goal,
      magnesiumGoal: magnesiumGoal,
    );
  }

  /// Overwrite cached tracked values with actual sums to fix stale data (#182)
  Future<void> reconcileDayTracked(
    DateTime day,
    double calories,
    double carbs,
    double fat,
    double protein,
  ) async {
    await _trackedDayRepository.reconcileDayTracked(
      await _keyFor(day),
      calories,
      carbs,
      fat,
      protein,
    );
  }
}
