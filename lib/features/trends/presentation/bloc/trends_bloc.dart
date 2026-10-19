import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/core/domain/entity/body_weight_unit_entity.dart';
import 'package:opennutritracker/core/domain/entity/tracked_day_entity.dart';
import 'package:opennutritracker/core/domain/entity/weight_log_entity.dart';
import 'package:opennutritracker/core/domain/usecase/get_config_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_tracked_day_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_user_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_water_intake_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_weight_log_usecase.dart';
import 'package:opennutritracker/core/utils/calc/day_boundary_calc.dart';

part 'trends_event.dart';
part 'trends_state.dart';

class TrendsBloc extends Bloc<TrendsEvent, TrendsState> {
  final GetTrackedDayUsecase _getTrackedDayUsecase;
  final GetWeightLogUsecase _getWeightLogUsecase;
  final GetUserUsecase _getUserUsecase;
  final GetConfigUsecase _getConfigUsecase;
  final GetWaterIntakeUsecase _getWaterIntakeUsecase;

  TrendsBloc(
    this._getTrackedDayUsecase,
    this._getWeightLogUsecase,
    this._getUserUsecase,
    this._getConfigUsecase,
    this._getWaterIntakeUsecase,
  ) : super(const TrendsInitial()) {
    on<LoadTrendsEvent>((event, emit) async {
      emit(const TrendsLoading());
      try {
        final config = await _getConfigUsecase.getConfig();
        // Tracked-day rows are keyed by the configured day boundary, so
        // the range anchors on the logical today — between midnight and
        // the boundary that is the previous wall-clock day.
        final today = DayBoundaryCalc.currentLogicalDayMinutes(
          config.dayStartOffsetTotalMinutes,
        );
        // Today's tracked day is stamped with the time it was created, so the
        // range end must cover the whole day or today drops out of the result
        // (the range filter is inclusive but compares against this instant).
        final endOfToday = DateTime(
          today.year,
          today.month,
          today.day,
          23,
          59,
          59,
        );
        // rangeDays 0 is the "All" chip: pull a wide window and let the actual
        // span fall out of the earliest data point below.
        final isAll = event.rangeDays == 0;
        final fetchDays = isAll ? 3650 : event.rangeDays;
        final days = await _getTrackedDayUsecase.getTrackedDaysByRange(
          today.subtract(Duration(days: fetchDays - 1)),
          endOfToday,
        );
        // The full weight history; the chart windows it for display. This
        // mirrors the weight-history screen, so a reading from weeks ago
        // still shows once the range is wide enough to include it.
        final weight = await _getWeightLogUsecase.getAllEntries();
        weight.sort((a, b) => a.date.compareTo(b.date));
        // The 7 days before this week, for a week-over-week consistency delta.
        final priorWeek = await _getTrackedDayUsecase.getTrackedDaysByRange(
          today.subtract(const Duration(days: 13)),
          DateTime(today.year, today.month, today.day - 7, 23, 59, 59),
        );
        final user = await _getUserUsecase.getUserData();

        // Water totalled per logical day (same boundary as the tracked-day
        // rows, so a glass logged at 00:30 lands on the day the diary
        // shows it under); the card fills missing days with 0.
        final waterEntries = await _getWaterIntakeUsecase.getAllEntries();
        final waterByDay = <DateTime, int>{};
        for (final e in waterEntries) {
          final d = DayBoundaryCalc.dayKeyFor(
            e.dateTime,
            config.dayStartOffsetTotalMinutes,
          );
          waterByDay[d] = (waterByDay[d] ?? 0) + e.amountMl;
        }

        // For a fixed chip the window is the chip; for "All" it stretches back
        // to exactly the earliest data point (across days, weight, and water)
        // so the charts begin at the first entry rather than padding empty
        // days in front of it. A 2-day floor keeps a single entry renderable.
        int windowDays;
        if (!isAll) {
          windowDays = event.rangeDays;
        } else {
          DateTime? earliest;
          void consider(DateTime d) {
            if (earliest == null || d.isBefore(earliest!)) earliest = d;
          }

          for (final d in days) {
            consider(DateTime(d.day.year, d.day.month, d.day.day));
          }
          for (final w in weight) {
            consider(DateTime(w.date.year, w.date.month, w.date.day));
          }
          for (final k in waterByDay.keys) {
            consider(k);
          }
          windowDays = earliest == null
              ? 30 // no data yet: a sensible empty-chart width
              : (today.difference(earliest!).inDays + 1).clamp(2, 3650);
        }

        emit(
          TrendsLoaded(
            rangeDays: event.rangeDays,
            windowDays: windowDays,
            days: days,
            priorWeek: priorWeek,
            weight: weight,
            bodyWeightUnit: config.bodyWeightUnit,
            targetWeightKg: user.targetWeightKg,
            waterByDay: waterByDay,
            waterGoalMl: config.effectiveDailyWaterGoalMl(
              user.gender,
              caloriesProfile: user.caloriesProfile,
            ),
          ),
        );
      } catch (e) {
        emit(TrendsFailed(e.toString()));
      }
    });
  }
}
