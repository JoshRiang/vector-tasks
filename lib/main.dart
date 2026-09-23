// ignore_for_file: use_build_context_synchronously
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// Pseudo list for dated tasks that belong to no goal.
///
/// A task created by an instruction has no goal_id, so without this grouping it
/// would be invisible in the app. Declared at file scope because both the home
/// page and the task detail page need it, and the detail page must never send
/// this value to the server as a real goal_id.
const String kNoListId = '__none__';

void main() {
  // The app renders white on the user's device and reports nothing, so every
  // failure class is both SURFACED on screen and REPORTED to the server. The
  // beacons are the only way to learn where startup stops when the screen
  // itself is the thing that is broken.
  runZonedGuarded(() {
    ErrorWidget.builder = (FlutterErrorDetails d) {
      Api.beacon('errorwidget', '${d.exception}\n${d.stack}');
      return _CrashReport(d);
    };
    FlutterError.onError = (FlutterErrorDetails d) {
      Api.beacon('fluttererror', '${d.exception}\n${d.stack}');
      FlutterError.presentError(d);
    };
    Api.beacon('main', 'entered main()');
    runApp(const VectorTasksApp());
  }, (Object error, StackTrace stack) {
    // Uncaught async errors never reach ErrorWidget.builder, so they are
    // exactly the class that produces a blank screen with no message.
    Api.beacon('uncaught', '$error\n$stack');
  });
}

class AppColors {
  static const bgBase = Color(0xFFF5F5F7);
  static const bgTop = Color(0xFFEEF1FF);
  static const glass = Color(0xCCFFFFFF);
  static const accent = Color(0xFF6366F1);
  static const accentSoft = Color(0xFF8B5CF6);
  static const success = Color(0xFF10B981);
  static const danger = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);
  static const textPrimary = Color(0xFF1C1C1E);
  static const textSecondary = Color(0xFF6B7280);
  static const textTertiary = Color(0xFF9CA3AF);
}

/// Frosted card shared by every surface in the app.
Widget glassBox({required Widget child}) => Container(
      decoration: BoxDecoration(
        color: AppColors.glass,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x14000000)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0F000000), blurRadius: 20, offset: Offset(0, 6)),
        ],
      ),
      child: child,
    );

class VectorTasksApp extends StatelessWidget {
  const VectorTasksApp({super.key});

  @override
  Widget build(BuildContext context) => const CupertinoApp(
        title: 'Vector Tasks',
        debugShowCheckedModeBanner: false,
        theme: CupertinoThemeData(
          primaryColor: AppColors.accent,
          scaffoldBackgroundColor: AppColors.bgBase,
        ),
        home: HomePage(),
      );
}

/// Google Tasks-like home: lists from goals, an "All tasks" view, rows grouped
/// by date, a bottom quick-add field, and a Hermes command bar.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _commandController = TextEditingController();
  final _quickAddController = TextEditingController();
  final _quickNotesController = TextEditingController();
  final _newListController = TextEditingController();

  // NOT `late final`: _boot() re-creates the client once it has read the stored
  // owner id from prefs, so the field is assigned twice. `late final` throws
  // LateInitializationError on the second assignment, asynchronously, which
  // used to leave _loading true forever - a blank white screen with no message.
  late Api _api;

  bool _loading = true;
  bool _sendingCommand = false;
  bool _adding = false;
  bool _creatingList = false;
  String? _error;

  List<Map<String, dynamic>> _goals = [];
  Map<String, List<Map<String, dynamic>>> _tasksByGoal = {};
  Map<String, String> _goalTitles = {};
  int _doneToday = 0;

  String _selectedListId = 'all';
  bool _hideCompleted = false;

  /// Local date as YYYY-MM-DD, built by hand because the date-range endpoint
  /// takes a plain date and this avoids any locale/UTC surprise.
  String _dayStr(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_pad2(d.month)}-${_pad2(d.day)}';

  List<Map<String, String>> _exchanges = [];
  List<Map<String, dynamic>> _history = [];

  DateTime? _quickDue;
  int _quickPriority = 3;
  bool _showQuickMore = false;

  @override
  void initState() {
    super.initState();
    _api = Api(userId: Api.defaultUserId);
    Future.microtask(_boot);
  }

  @override
  void dispose() {
    _commandController.dispose();
    _quickAddController.dispose();
    _quickNotesController.dispose();
    _newListController.dispose();
    super.dispose();
  }

  // GET /goals keys the identifier as `goal_id`, not `id`. Fall back to `id`
  // for goal maps that came from POST /goals (a raw goals-table row).
  String _goalId(Map<String, dynamic> g) =>
      (g['goal_id'] ?? g['id'] ?? '').toString();

  String _goalTitleOf(String goalId) => _goalTitles[goalId] ?? 'List';

  Future<void> _boot() async {
    Api.beacon('boot', 'start');
    String id = Api.defaultUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      id = prefs.getString('vector.user_id') ?? Api.defaultUserId;
    } catch (_) {
      // Prefs are an optimisation here, not a requirement.
    }
    Api.beacon('boot', 'prefs ok, id=$id');
    _api = Api(userId: id);
    await _reload();
  }

  Future<void> _reload() async {
    var stage = 'goals';
    Api.beacon('reload', 'start');
    try {
      final goals = await _api.goals();
      Api.beacon('reload', 'goals ok n=${goals.length}');
      stage = 'tasks';
      final Map<String, List<Map<String, dynamic>>> byGoal = {};
      final Map<String, String> titles = {};
      for (final g in goals) {
        final gid = _goalId(g);
        if (gid.isEmpty) continue;
        final title = (g['title'] ?? 'Untitled list').toString();
        titles[gid] = title;
        try {
          final data = await _api.goalTasks(gid);
          final parsed = GoalTasks.fromJson(data);
          final stamped = <Map<String, dynamic>>[];
          for (final t in parsed.tasks) {
            final copy = Map<String, dynamic>.from(t);
            copy['_goal_id'] = gid;
            copy['_goal_title'] = title;
            stamped.add(copy);
          }
          byGoal[gid] = stamped;
        } catch (_) {
          // One failing list must not blank the rest; show what loaded.
          byGoal[gid] = [];
        }
      }
      Api.beacon('reload', 'tasks ok lists=${byGoal.length}');
      stage = 'today';
      int doneToday = 0;
      try {
        final today = await _api.today();
        final rawDone = today['done_today'];
        doneToday = rawDone is List ? rawDone.length : 0;
      } catch (_) {
        doneToday = 0;
      }

      // Dated tasks, including ones with NO list.
      //
      // The loop above only reaches tasks through their goal, so a task created
      // by an instruction ("add a dentist appointment tomorrow at 2pm") belongs
      // to no goal and would never appear in the app at all. Fetching the
      // calendar window as well is what makes those visible, and gives the
      // Overdue/Today/Tomorrow grouping its real dates.
      stage = 'calendar';
      final seen = <String>{};
      for (final list in byGoal.values) {
        for (final t in list) {
          seen.add((t['id'] ?? '').toString());
        }
      }
      final dated = <Map<String, dynamic>>[];
      try {
        final now = DateTime.now();
        final start = now.subtract(const Duration(days: 60));
        final end = now.add(const Duration(days: 120));
        final res = await _api.calendarRange(start: _dayStr(start), end: _dayStr(end));
        final raw = res['items'];
        if (raw is List) {
          for (final item in raw) {
            if (item is! Map) continue;
            final m = Map<String, dynamic>.from(item);
            final id = (m['id'] ?? '').toString();
            if (id.isEmpty || seen.contains(id)) continue;
            seen.add(id);
            final gid = (m['goal_id'] ?? '').toString();
            if (gid.isNotEmpty && titles.containsKey(gid)) {
              m['_goal_id'] = gid;
              m['_goal_title'] = titles[gid];
            } else {
              // No list. Grouping these under a real list keeps one code path
              // for rendering; they are NOT written back to the server.
              m['_goal_id'] = kNoListId;
              m['_goal_title'] = 'No list';
            }
            dated.add(m);
          }
        }
      } catch (_) {
        // A calendar failure must not hide the goal tasks that did load.
      }
      if (dated.isNotEmpty) {
        byGoal[kNoListId] = dated;
        titles[kNoListId] = 'No list';
      }
      Api.beacon('reload', 'calendar ok extra=${dated.length}');

      stage = 'history';
      List<Map<String, dynamic>> history = [];
      try {
        history = await _api.commandHistory();
      } catch (_) {
        history = [];
      }
      Api.beacon('reload', 'history ok n=${history.length}');
      if (!mounted) return;
      Api.beacon('reload', 'about to setState with data');
      setState(() {
        _goals = goals;
        _tasksByGoal = byGoal;
        _goalTitles = titles;
        _doneToday = doneToday;
        _history = history.length > 5 ? history.sublist(0, 5) : history;
        if (_selectedListId != 'all' && !titles.containsKey(_selectedListId)) {
          _selectedListId = 'all';
        }
        _loading = false;
        _error = null;
      });
      Api.beacon('reload', 'setState done, data on screen');
    } on ApiException catch (e) {
      Api.beacon('reload', 'ApiException at $stage: ${e.message}');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e, st) {
      Api.beacon('reload', 'unexpected at $stage: $e\n$st');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed at $stage: $e';
      });
    }
  }

  // ------------------------------------------------------------------
  // Grouping + formatting helpers (pure, no `as` casts anywhere).
  // ------------------------------------------------------------------

  DateTime? _parseWhen(Map<String, dynamic> t) {
    final raw = (t['scheduled_at'] ?? '').toString();
    if (raw.isEmpty) return null;
    try {
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  bool _isAllDay(Map<String, dynamic> t) {
    final v = t['all_day'];
    if (v is num) return v.toInt() == 1;
    if (v is bool) return v;
    return false;
  }

  int _minutesOf(Map<String, dynamic> t) {
    final v = t['minutes'];
    return v is num ? v.toInt() : 30;
  }

  int _priorityOf(Map<String, dynamic> t) {
    final v = t['priority'];
    if (v is num) {
      final p = v.toInt();
      if (p >= 1 && p <= 4) return p;
    }
    return 3;
  }

  String _bucketFor(Map<String, dynamic> t, DateTime now) {
    final w = _parseWhen(t);
    if (w == null) return 'No date';
    final d = DateTime(w.year, w.month, w.day);
    final td = DateTime(now.year, now.month, now.day);
    final diff = d.difference(td).inDays;
    if (diff < 0) return 'Overdue';
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return 'Later';
  }

  String _monthName(int m) {
    const names = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    if (m < 1 || m > 12) return '';
    return names[m - 1];
  }

  String _fmtTime(DateTime d) {
    var h = d.hour;
    final m = d.minute;
    final suffix = h >= 12 ? 'PM' : 'AM';
    var hh = h % 12;
    if (hh == 0) hh = 12;
    final mm = m < 10 ? '0$m' : '$m';
    return '$hh:$mm $suffix';
  }

  String _fmtDue(Map<String, dynamic> t, DateTime now) {
    final w = _parseWhen(t);
    if (w == null) return '';
    final allDay = _isAllDay(t);
    final d = DateTime(w.year, w.month, w.day);
    final td = DateTime(now.year, now.month, now.day);
    final diff = d.difference(td).inDays;
    String day;
    if (diff == 0) {
      day = 'Today';
    } else if (diff == 1) {
      day = 'Tomorrow';
    } else if (diff == -1) {
      day = 'Yesterday';
    } else {
      day = '${w.day} ${_monthName(w.month)}';
      if (w.year != now.year) day = '$day ${w.year}';
    }
    if (allDay) return day;
    // Tasks without a meaningful time still carry midnight; showing
    // "12:00 AM" would be noise, so only show the clock past 00:00.
    if (w.hour == 0 && w.minute == 0) return day;
    return '$day ${_fmtTime(w)}';
  }

  String _subtitle(Map<String, dynamic> t, DateTime now) {
    final parts = <String>[];
    final due = _fmtDue(t, now);
    if (due.isNotEmpty) parts.add(due);
    parts.add('${_minutesOf(t)} min');
    if (_selectedListId == 'all') {
      final g = (t['_goal_title'] ?? '').toString();
      if (g.isNotEmpty) parts.add(g);
    } else {
      final why = (t['why'] ?? t['blocked_by_title'] ?? '').toString();
      if (why.isNotEmpty) parts.add(why);
    }
    return parts.join('  ·  ');
  }

  List<Map<String, dynamic>> _visibleTasks() {
    final out = <Map<String, dynamic>>[];
    if (_selectedListId == 'all') {
      for (final entry in _tasksByGoal.entries) {
        out.addAll(entry.value);
      }
    } else {
      final list = _tasksByGoal[_selectedListId];
      if (list != null) out.addAll(list);
    }
    if (_hideCompleted) {
      out.removeWhere((t) => (t['status'] ?? '').toString() == 'done');
    }
    return out;
  }

  Map<String, List<Map<String, dynamic>>> _grouped(
      List<Map<String, dynamic>> tasks, DateTime now) {
    const order = ['Overdue', 'Today', 'Tomorrow', 'Later', 'No date'];
    final groups = <String, List<Map<String, dynamic>>>{
      for (final k in order) k: <Map<String, dynamic>>[],
    };
    for (final t in tasks) {
      groups[_bucketFor(t, now)]!.add(t);
    }
    for (final k in order) {
      groups[k]!.sort((a, b) {
        final da = _parseWhen(a);
        final db = _parseWhen(b);
        if (da == null && db == null) {
          final pa = _priorityOf(a);
          final pb = _priorityOf(b);
          if (pa != pb) return pa.compareTo(pb);
          return (a['title'] ?? '')
              .toString()
              .compareTo((b['title'] ?? '').toString());
        }
        if (da == null) return 1;
        if (db == null) return -1;
        final c = da.compareTo(db);
        if (c != 0) return c;
        return _priorityOf(a).compareTo(_priorityOf(b));
      });
    }
    return groups;
  }

  // ------------------------------------------------------------------
  // Mutations.
  // ------------------------------------------------------------------

  Future<void> _toggleTask(Map<String, dynamic> task) async {
    final id = (task['id'] ?? '').toString();
    if (id.isEmpty) {
      if (!mounted) return;
      setState(() => _error = 'This task has no id, so it cannot be saved.');
      return;
    }
    final wasDone = (task['status'] ?? '').toString() == 'done';
    final gid = (task['_goal_id'] ?? _selectedListId).toString();
    setState(() {
      final list = _tasksByGoal[gid];
      if (list != null) {
        for (final t in list) {
          if ((t['id'] ?? '').toString() == id) {
            t['status'] = wasDone ? 'todo' : 'done';
          }
        }
      }
    });
    try {
      if (wasDone) {
        await _api.reopenTask(id);
      } else {
        await _api.completeTask(id);
      }
      await _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not save: ${e.message}');
      await _reload();
    }
  }

  String _pad2(int n) => n < 10 ? '0$n' : '$n';

  String _toScheduledAt(DateTime d) =>
      '${d.year}-${_pad2(d.month)}-${_pad2(d.day)}T${_pad2(d.hour)}:${_pad2(d.minute)}:00';

  Future<void> _pickQuickDue() async {
    DateTime temp = _quickDue ?? DateTime.now();
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
        height: 340,
        color: CupertinoColors.white,
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            CupertinoButton(
              child: const Text('Clear'),
              onPressed: () {
                setState(() => _quickDue = null);
                Navigator.pop(ctx);
              },
            ),
            CupertinoButton(
              child: const Text('Done',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onPressed: () {
                setState(() => _quickDue = temp);
                Navigator.pop(ctx);
              },
            ),
          ]),
          Expanded(
            child: CupertinoDatePicker(
              mode: CupertinoDatePickerMode.dateAndTime,
              initialDateTime: temp,
              onDateTimeChanged: (d) => temp = d,
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _pickQuickGoal() async {
    if (_goals.isEmpty) return;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Add to list'),
        actions: [
          for (final g in _goals)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                if (!mounted) return;
                final gid = _goalId(g);
                setState(() => _selectedListId = gid);
              },
              child: Text((g['title'] ?? 'Untitled').toString()),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  String _quickTargetGoalId() {
    // Never return the pseudo list: it is a display-only grouping, not a real
    // goal, and sending it would store a goal_id that does not exist.
    if (_selectedListId != 'all' &&
        _selectedListId != kNoListId &&
        _goalTitles.containsKey(_selectedListId)) {
      return _selectedListId;
    }
    if (_goals.isNotEmpty) return _goalId(_goals.first);
    return '';
  }

  Future<void> _quickAdd() async {
    final title = _quickAddController.text.trim();
    if (title.isEmpty || _adding) return;
    final goalId = _quickTargetGoalId();
    if (goalId.isEmpty) {
      if (!mounted) return;
      setState(() => _error = 'Create a list first, then add tasks to it.');
      return;
    }
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final notes = _quickNotesController.text.trim();
      if (_quickDue != null) {
        await _api.upsertTask(
          title: title,
          scheduledAt: _toScheduledAt(_quickDue!),
          minutes: 30,
          notes: notes.isEmpty ? null : notes,
          goalId: goalId,
          priority: _quickPriority,
        );
      } else {
        await _api.addTask(
          goalId,
          title,
          why: notes.isEmpty ? null : notes,
          priority: _quickPriority,
        );
      }
      _quickAddController.clear();
      _quickNotesController.clear();
      if (!mounted) return;
      setState(() {
        _quickDue = null;
        _quickPriority = 3;
        _showQuickMore = false;
      });
      await _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _createList() async {
    final title = _newListController.text.trim();
    if (title.isEmpty || _creatingList) return;
    setState(() {
      _creatingList = true;
      _error = null;
    });
    try {
      await _api.createGoal(title);
      _newListController.clear();
      await _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _creatingList = false);
    }
  }

  Future<void> _sendCommand() async {
    final text = _commandController.text.trim();
    if (text.isEmpty || _sendingCommand) return;
    setState(() {
      _sendingCommand = true;
      _error = null;
    });
    try {
      final res = await _api.command(text);
      final reply = (res['reply'] ?? '').toString();
      final problems = <String>[];
      final applied = res['applied'];
      if (applied is List) {
        for (final e in applied) {
          if (e is Map) {
            final m = Map<String, dynamic>.from(e);
            final err = (m['error'] ?? '').toString();
            if (err.isNotEmpty) {
              final what =
                  (m['title'] ?? m['action'] ?? 'change').toString();
              problems.add('$what: $err');
            }
          }
        }
      }
      _commandController.clear();
      if (!mounted) return;
      setState(() {
        final shown = reply.isEmpty ? 'Done.' : reply;
        if (problems.isNotEmpty) {
          _exchanges.insert(0, {
            'q': text,
            'a': '$shown\nPartial failure: ${problems.join('; ')}',
          });
        } else {
          _exchanges.insert(0, {'q': text, 'a': shown});
        }
        if (_exchanges.length > 5) {
          _exchanges = _exchanges.sublist(0, 5);
        }
      });
      await _reload();
      if (!mounted) return;
      if (problems.isNotEmpty) {
        setState(() =>
            _error = 'Hermes applied some changes, but: ${problems.join('; ')}');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sendingCommand = false);
    }
  }

  void _openDetail(Map<String, dynamic> task) {
    final gid = (task['_goal_id'] ?? '').toString();
    Navigator.of(context)
        .push(CupertinoPageRoute(
          builder: (_) => TaskDetailPage(
            api: _api,
            task: task,
            goalId: gid,
            goalTitle: (task['_goal_title'] ?? _goalTitleOf(gid)).toString(),
            goals: _goals,
          ),
        ))
        .then((_) => _reload());
  }

  // ------------------------------------------------------------------
  // Build.
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    Api.beacon('build', 'loading=$_loading err=$_error');
    return CupertinoPageScaffold(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgTop, AppColors.bgBase],
          ),
        ),
        child: SafeArea(
          child: _loading
              ? const Center(child: CupertinoActivityIndicator())
              // Pull-to-refresh is CupertinoSliverRefreshControl:
              // RefreshIndicator is a Material widget and this app never
              // imports Material.
              : CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    CupertinoSliverRefreshControl(onRefresh: _reload),
                    SliverToBoxAdapter(child: _header()),
                    if (_error != null)
                      SliverToBoxAdapter(child: _errorBanner(_error!)),
                    SliverToBoxAdapter(child: _commandCard()),
                    SliverToBoxAdapter(child: _listSelector()),
                    SliverToBoxAdapter(child: _filterRow()),
                    ..._sectionSlivers(),
                    SliverToBoxAdapter(child: _quickAddCard()),
                    SliverToBoxAdapter(child: _newListCard()),
                    if (_history.isNotEmpty)
                      SliverToBoxAdapter(child: _historyCard()),
                    const SliverToBoxAdapter(child: SizedBox(height: 40)),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('VECTOR',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.accent,
                    letterSpacing: 1.6)),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Expanded(
                  child: Text('Tasks',
                      style: TextStyle(
                          fontSize: 32,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                ),
                if (_doneToday > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('$_doneToday done today',
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.success)),
                  ),
              ],
            ),
          ],
        ),
      );

  Widget _errorBanner(String msg) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0x1AEF4444),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            const Icon(CupertinoIcons.exclamationmark_circle,
                size: 16, color: AppColors.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(msg,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textPrimary)),
            ),
          ]),
        ),
      );

  /// Hermes command bar: type an instruction, read the reply, see what changed.
  Widget _commandCard() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
        child: glassBox(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ASK HERMES',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textTertiary,
                        letterSpacing: 1.2)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: CupertinoTextField(
                      controller: _commandController,
                      placeholder:
                          'e.g. move groceries to tomorrow morning',
                      placeholderStyle:
                          const TextStyle(color: AppColors.textTertiary),
                      padding: const EdgeInsets.all(12),
                      style: const TextStyle(
                          fontSize: 14, color: AppColors.textPrimary),
                      decoration: BoxDecoration(
                        color: const Color(0x0F000000),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      onSubmitted: (_) => _sendCommand(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _sendingCommand ? null : _sendCommand,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _sendingCommand
                            ? AppColors.textTertiary
                            : AppColors.accent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: _sendingCommand
                          ? const CupertinoActivityIndicator(
                              color: CupertinoColors.white)
                          : const Icon(CupertinoIcons.arrow_up,
                              size: 18, color: CupertinoColors.white),
                    ),
                  ),
                ]),
                for (final ex in _exchanges) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0x0A6366F1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ex['q'] ?? '',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary)),
                        const SizedBox(height: 4),
                        Text(ex['a'] ?? '',
                            style: const TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  /// Lists = goals, plus an "All tasks" view. A horizontal chip row works as
  /// the segmented control for an arbitrary number of lists.
  Widget _listSelector() {
    final chips = <Widget>[];
    chips.add(_listChip('all', 'All tasks', _visibleCountAll()));
    for (final g in _goals) {
      final gid = _goalId(g);
      if (gid.isEmpty) continue;
      final list = _tasksByGoal[gid];
      var open = 0;
      if (list != null) {
        for (final t in list) {
          if ((t['status'] ?? '').toString() != 'done') open++;
        }
      }
      chips.add(_listChip(gid, (g['title'] ?? 'Untitled').toString(), open));
    }
    // Dated tasks with no goal get their own chip, otherwise the only way to
    // reach something created by an instruction is the catch-all "All" view.
    final noList = _tasksByGoal[kNoListId];
    if (noList != null && noList.isNotEmpty) {
      var open = 0;
      for (final t in noList) {
        if ((t['status'] ?? '').toString() != 'done') open++;
      }
      chips.add(_listChip(kNoListId, 'No list', open));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 24),
            child: Text('LISTS',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textTertiary,
                    letterSpacing: 1.2)),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < chips.length; i++) ...[
                chips[i],
                if (i < chips.length - 1) const SizedBox(width: 8),
              ],
              const SizedBox(width: 24),
            ]),
          ),
        ],
      ),
    );
  }

  int _visibleCountAll() {
    var open = 0;
    for (final entry in _tasksByGoal.entries) {
      for (final t in entry.value) {
        if ((t['status'] ?? '').toString() != 'done') open++;
      }
    }
    return open;
  }

  Widget _listChip(String id, String title, int open) {
    final selected = _selectedListId == id;
    return GestureDetector(
      onTap: () => setState(() => _selectedListId = id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [AppColors.accent, AppColors.accentSoft])
              : null,
          color: selected ? null : AppColors.glass,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected
                  ? const Color(0x00000000)
                  : const Color(0x14000000)),
        ),
        child: Text(
          open > 0 ? '$title · $open' : title,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected
                  ? CupertinoColors.white
                  : AppColors.textPrimary),
        ),
      ),
    );
  }

  Widget _filterRow() {
    final visible = _visibleTasks();
    var done = 0;
    for (final t in visible) {
      if ((t['status'] ?? '').toString() == 'done') done++;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(children: [
        Expanded(
          child: Text(
            visible.isEmpty
                ? 'Nothing here'
                : done > 0
                    ? '${visible.length} tasks · $done done'
                    : '${visible.length} tasks',
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
        const Text('Hide completed',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(width: 8),
        CupertinoSwitch(
          value: _hideCompleted,
          activeColor: AppColors.accent,
          onChanged: (v) => setState(() => _hideCompleted = v),
        ),
      ]),
    );
  }

  List<Widget> _sectionSlivers() {
    final now = DateTime.now();
    final visible = _visibleTasks();
    if (visible.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
            child: glassBox(
              child: const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'Nothing scheduled. Add a task below or ask Hermes above.',
                  style: TextStyle(
                      fontSize: 14, color: AppColors.textSecondary)),
              ),
            ),
          ),
        ),
      ];
    }
    const order = ['Overdue', 'Today', 'Tomorrow', 'Later', 'No date'];
    final groups = _grouped(visible, now);
    final out = <Widget>[];
    for (final key in order) {
      final list = groups[key]!;
      if (list.isEmpty) continue;
      out.add(SliverToBoxAdapter(child: _sectionHeading(key, list.length)));
      out.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          sliver: SliverList.builder(
            itemCount: list.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: _taskRow(list[i], now),
            ),
          ),
        ),
      );
    }
    return out;
  }

  Widget _sectionHeading(String title, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title.toUpperCase(),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: title == 'Overdue'
                        ? AppColors.danger
                        : AppColors.textTertiary,
                    letterSpacing: 1.1)),
            Text('$count',
                style:
                    const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
          ],
        ),
      );

  Color _priorityColor(int p) {
    if (p == 1) return AppColors.danger;
    if (p == 2) return AppColors.warning;
    if (p == 4) return AppColors.textTertiary;
    return AppColors.accent;
  }

  Widget _taskRow(Map<String, dynamic> t, DateTime now) {
    final id = (t['id'] ?? '').toString();
    final title = (t['title'] ?? '').toString();
    final isDone = (t['status'] ?? '').toString() == 'done';
    final priority = _priorityOf(t);
    final startable = t['startable'] == true;
    return GestureDetector(
      onTap: () => _openDetail(t),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.glass,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: startable && !isDone
                ? const Color(0x336366F1)
                : const Color(0x14000000),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => _toggleTask(t),
              child: Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      isDone ? AppColors.success : const Color(0x0F000000),
                  border: Border.all(
                    color: isDone
                        ? AppColors.success
                        : const Color(0x33000000),
                  ),
                ),
                child: isDone
                    ? const Icon(CupertinoIcons.checkmark_alt,
                        size: 15, color: CupertinoColors.white)
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title.isEmpty ? '(untitled)' : title,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.3,
                        fontWeight: startable && !isDone
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: isDone
                            ? AppColors.textTertiary
                            : AppColors.textPrimary,
                        decoration:
                            isDone ? TextDecoration.lineThrough : null,
                      )),
                  const SizedBox(height: 4),
                  Text(_subtitle(t, now),
                      style: TextStyle(
                          fontSize: 12,
                          color: isDone
                              ? AppColors.success
                              : AppColors.textSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDone
                    ? const Color(0x20000000)
                    : _priorityColor(priority),
              ),
            ),
            // Keep the id out of the visuals, but keep it reachable: a row
            // without an id cannot be saved, and tapping it must explain that.
            if (id.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4, left: 4),
                child: Icon(CupertinoIcons.exclamationmark_circle,
                    size: 14, color: AppColors.danger),
              ),
          ],
        ),
      ),
    );
  }

  /// Google Tasks-style bottom field: quick title entry plus optional
  /// date/time, notes and priority.
  Widget _quickAddCard() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ADD A TASK',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textTertiary,
                    letterSpacing: 1.1)),
            const SizedBox(height: 8),
            glassBox(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: CupertinoTextField(
                        controller: _quickAddController,
                        placeholder: 'Add a task to ${_addTargetName()}',
                        placeholderStyle:
                            const TextStyle(color: AppColors.textTertiary),
                        padding: const EdgeInsets.all(12),
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textPrimary),
                        decoration: BoxDecoration(
                          color: const Color(0x0F000000),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        onSubmitted: (_) => _quickAdd(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _adding ? null : _quickAdd,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _adding
                              ? AppColors.textTertiary
                              : AppColors.accent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: _adding
                            ? const CupertinoActivityIndicator(
                                color: CupertinoColors.white)
                            : const Icon(CupertinoIcons.add,
                                size: 19, color: CupertinoColors.white),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    _optionChip(
                      icon: CupertinoIcons.calendar,
                      label: _quickDue == null
                          ? 'Date'
                          : '${_quickDue!.day} ${_monthName(_quickDue!.month)} ${_fmtTime(_quickDue!)}',
                      active: _quickDue != null,
                      onTap: _pickQuickDue,
                    ),
                    const SizedBox(width: 8),
                    _optionChip(
                      icon: CupertinoIcons.flag,
                      label: 'P${_quickPriority}',
                      active: _quickPriority != 3,
                      onTap: () => setState(() {
                        _quickPriority = _quickPriority >= 4 ? 1 : _quickPriority + 1;
                      }),
                    ),
                    const SizedBox(width: 8),
                    _optionChip(
                      icon: CupertinoIcons.square_list,
                      label: _addTargetName(),
                      active: false,
                      onTap: _pickQuickGoal,
                    ),
                    const SizedBox(width: 8),
                    _optionChip(
                      icon: CupertinoIcons.ellipsis,
                      label: 'More',
                      active: _showQuickMore,
                      onTap: () => setState(
                          () => _showQuickMore = !_showQuickMore),
                    ),
                  ]),
                  if (_showQuickMore) ...[
                    const SizedBox(height: 8),
                    CupertinoTextField(
                      controller: _quickNotesController,
                      placeholder: 'Notes (optional)',
                      placeholderStyle:
                          const TextStyle(color: AppColors.textTertiary),
                      padding: const EdgeInsets.all(12),
                      maxLines: 3,
                      style: const TextStyle(
                          fontSize: 14, color: AppColors.textPrimary),
                      decoration: BoxDecoration(
                        color: const Color(0x0F000000),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ],
                ]),
              ),
            ),
          ],
        ),
      );

  String _addTargetName() {
    if (_selectedListId != 'all') return _goalTitleOf(_selectedListId);
    final gid = _quickTargetGoalId();
    if (gid.isEmpty) return 'a list';
    return _goalTitleOf(gid);
  }

  Widget _optionChip(
      {required IconData icon,
      required String label,
      required bool active,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: active ? AppColors.accent : const Color(0x0F000000),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 13,
              color:
                  active ? CupertinoColors.white : AppColors.textSecondary),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active
                      ? CupertinoColors.white
                      : AppColors.textSecondary)),
        ]),
      ),
    );
  }

  Widget _newListCard() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        child: Row(children: [
          Expanded(
            child: CupertinoTextField(
              controller: _newListController,
              placeholder: 'New list name',
              placeholderStyle:
                  const TextStyle(color: AppColors.textTertiary),
              padding: const EdgeInsets.all(12),
              style: const TextStyle(
                  fontSize: 14, color: AppColors.textPrimary),
              decoration: BoxDecoration(
                color: AppColors.glass,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x14000000)),
              ),
              onSubmitted: (_) => _createList(),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _creatingList ? null : _createList,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _creatingList
                    ? AppColors.textTertiary
                    : AppColors.textPrimary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _creatingList ? 'Adding…' : 'Add list',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.white),
              ),
            ),
          ),
        ]),
      );

  Widget _historyCard() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
        child: glassBox(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('RECENT HERMS CHANGES',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textTertiary,
                        letterSpacing: 1.2)),
                const SizedBox(height: 8),
                for (final h in _history) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(_historyLine(h),
                        style: const TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: AppColors.textSecondary)),
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  /// One line of the command history.
  ///
  /// GET /commands returns chat rows keyed {id, role, content, created_at} —
  /// NOT instruction/reply. Reading the wrong keys made every history entry
  /// fall through to the placeholder, so real past instructions were invisible.
  /// The other key names are still tried for older servers.
  String _historyLine(Map<String, dynamic> h) {
    final role = (h['role'] ?? '').toString();
    final content = (h['content'] ??
            h['instruction'] ??
            h['reply'] ??
            h['text'] ??
            h['result'] ??
            '')
        .toString();
    if (content.isEmpty) return 'Change applied.';
    if (role == 'user') return 'You: $content';
    if (role == 'assistant') return content;
    return content;
  }
}

/// Task detail: edit title, date, time, all-day, notes, priority, minutes and
/// the list it belongs to. Saves with `upsertTask` (id passed).
class TaskDetailPage extends StatefulWidget {
  const TaskDetailPage(
      {super.key,
      required this.api,
      required this.task,
      required this.goalId,
      required this.goalTitle,
      required this.goals});

  final Api api;
  final Map<String, dynamic> task;
  final String goalId;
  final String goalTitle;
  final List<Map<String, dynamic>> goals;

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();

  DateTime? _due;
  bool _allDay = false;
  int _priority = 3;
  int _minutes = 30;
  String _listId = '';
  bool _saving = false;
  bool _deleting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titleController.text = (widget.task['title'] ?? '').toString();
    _notesController.text = (widget.task['notes'] ?? '').toString();
    final rawDue = (widget.task['scheduled_at'] ?? '').toString();
    if (rawDue.isNotEmpty) {
      try {
        _due = DateTime.parse(rawDue);
      } catch (_) {
        _due = null;
      }
    }
    final ad = widget.task['all_day'];
    if (ad is num) {
      _allDay = ad.toInt() == 1;
    } else if (ad is bool) {
      _allDay = ad;
    }
    final p = widget.task['priority'];
    if (p is num) {
      final v = p.toInt();
      if (v >= 1 && v <= 4) _priority = v;
    }
    final m = widget.task['minutes'];
    if (m is num) _minutes = m.toInt();
    final gid = (widget.task['_goal_id'] ?? widget.goalId).toString();
    // A task with no list arrives grouped under the pseudo list; keep the
    // picker on "no list" rather than pretending it belongs to one.
    _listId = gid == kNoListId ? '' : gid;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  String get _taskId => (widget.task['id'] ?? '').toString();

  bool get _isDone => (widget.task['status'] ?? '').toString() == 'done';

  String _goalIdOf(Map<String, dynamic> g) =>
      (g['goal_id'] ?? g['id'] ?? '').toString();

  String _pad2(int n) => n < 10 ? '0$n' : '$n';

  String _fmtDay(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final mon = (d.month >= 1 && d.month <= 12) ? months[d.month - 1] : '';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final wd = days[d.weekday - 1];
    return '$wd ${d.day} $mon ${d.year}';
  }

  String _fmtClock(DateTime d) {
    var h = d.hour;
    final suffix = h >= 12 ? 'PM' : 'AM';
    var hh = h % 12;
    if (hh == 0) hh = 12;
    return '$hh:${_pad2(d.minute)} $suffix';
  }

  Future<void> _pickDate() async {
    DateTime temp = _due ?? DateTime.now();
    temp = DateTime(temp.year, temp.month, temp.day,
        _due != null ? _due!.hour : 9, _due != null ? _due!.minute : 0);
    DateTime picked = temp;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
        height: 320,
        color: CupertinoColors.white,
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            CupertinoButton(
              child: const Text('No date'),
              onPressed: () {
                setState(() => _due = null);
                Navigator.pop(ctx);
              },
            ),
            CupertinoButton(
              child: const Text('Done',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onPressed: () {
                setState(() {
                  final keep = _due;
                  if (keep != null) {
                    _due = DateTime(picked.year, picked.month, picked.day,
                        keep.hour, keep.minute);
                  } else {
                    _due = DateTime(
                        picked.year, picked.month, picked.day, 9, 0);
                  }
                });
                Navigator.pop(ctx);
              },
            ),
          ]),
          Expanded(
            child: CupertinoDatePicker(
              mode: CupertinoDatePickerMode.date,
              initialDateTime: temp,
              onDateTimeChanged: (d) => picked = d,
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _pickTime() async {
    if (_due == null || _allDay) return;
    DateTime temp = _due!;
    DateTime picked = temp;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
        height: 320,
        color: CupertinoColors.white,
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            CupertinoButton(
              child: const Text('Done',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onPressed: () {
                setState(() {
                  final keep = _due;
                  if (keep != null) {
                    _due = DateTime(keep.year, keep.month, keep.day,
                        picked.hour, picked.minute);
                  }
                });
                Navigator.pop(ctx);
              },
            ),
          ]),
          Expanded(
            child: CupertinoDatePicker(
              mode: CupertinoDatePickerMode.time,
              initialDateTime: temp,
              onDateTimeChanged: (d) => picked = d,
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _pickList() async {
    if (widget.goals.isEmpty) return;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Move to list'),
        actions: [
          for (final g in widget.goals)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                if (!mounted) return;
                setState(() => _listId = _goalIdOf(g));
              },
              child: Text((g['title'] ?? 'Untitled').toString()),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  String _listName(String id) {
    for (final g in widget.goals) {
      if (_goalIdOf(g) == id) return (g['title'] ?? 'Untitled').toString();
    }
    if (id == widget.goalId) return widget.goalTitle;
    return 'List';
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty || _saving) return;
    if (_taskId.isEmpty) {
      if (!mounted) return;
      setState(() => _error = 'This task has no id, so it cannot be saved.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      String? scheduled;
      if (_due != null) {
        final d = _allDay
            ? DateTime(_due!.year, _due!.month, _due!.day, 0, 0)
            : _due!;
        scheduled =
            '${d.year}-${_pad2(d.month)}-${_pad2(d.day)}T${_pad2(d.hour)}:${_pad2(d.minute)}:00';
      }
      final notes = _notesController.text.trim();
      await widget.api.upsertTask(
        id: _taskId,
        title: title,
        scheduledAt: scheduled,
        minutes: _minutes,
        allDay: _due == null ? null : _allDay,
        notes: notes.isEmpty ? null : notes,
        goalId: (_listId.isEmpty || _listId == kNoListId) ? null : _listId,
        priority: _priority,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleDone() async {
    if (_taskId.isEmpty) return;
    try {
      if (_isDone) {
        await widget.api.reopenTask(_taskId);
      } else {
        await widget.api.completeTask(_taskId);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _remove() async {
    if (_taskId.isEmpty) return;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete this task?'),
        content: Text('“${_titleController.text.trim()}” will be removed.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deleting = true);
    try {
      await widget.api.deleteTask(_taskId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _deleting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Task'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          minSize: 0,
          onPressed: _deleting ? null : _remove,
          child: const Icon(CupertinoIcons.trash,
              size: 20, color: AppColors.danger),
        ),
      ),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgTop, AppColors.bgBase],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                glassBox(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('TITLE',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textTertiary,
                                letterSpacing: 1.1)),
                        const SizedBox(height: 6),
                        CupertinoTextField(
                          controller: _titleController,
                          placeholder: 'Task title',
                          placeholderStyle: const TextStyle(
                              color: AppColors.textTertiary),
                          padding: const EdgeInsets.all(12),
                          maxLines: 3,
                          style: const TextStyle(
                              fontSize: 16, color: AppColors.textPrimary),
                          decoration: BoxDecoration(
                            color: const Color(0x0F000000),
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        const SizedBox(height: 14),
                        const Text('NOTES',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textTertiary,
                                letterSpacing: 1.1)),
                        const SizedBox(height: 6),
                        CupertinoTextField(
                          controller: _notesController,
                          placeholder: 'Add notes',
                          placeholderStyle: const TextStyle(
                              color: AppColors.textTertiary),
                          padding: const EdgeInsets.all(12),
                          maxLines: 4,
                          style: const TextStyle(
                              fontSize: 14, color: AppColors.textPrimary),
                          decoration: BoxDecoration(
                            color: const Color(0x0F000000),
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                glassBox(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: [
                      Row(children: [
                        const Expanded(
                          child: Text('Date',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textPrimary)),
                        ),
                        GestureDetector(
                          onTap: _pickDate,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0x0F000000),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              _due == null ? 'No date' : _fmtDay(_due!),
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.accent),
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        const Expanded(
                          child: Text('All-day',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textPrimary)),
                        ),
                        CupertinoSwitch(
                          value: _allDay,
                          activeColor: AppColors.accent,
                          onChanged: _due == null
                              ? null
                              : (v) => setState(() => _allDay = v),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        const Expanded(
                          child: Text('Time',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textPrimary)),
                        ),
                        GestureDetector(
                          onTap:
                              (_due == null || _allDay) ? null : _pickTime,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0x0F000000),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              _due == null
                                  ? '—'
                                  : _allDay
                                      ? 'All day'
                                      : _fmtClock(_due!),
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: (_due == null || _allDay)
                                      ? AppColors.textTertiary
                                      : AppColors.accent),
                            ),
                          ),
                        ),
                      ]),
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                glassBox(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: [
                      Row(children: [
                        const Expanded(
                          child: Text('List',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textPrimary)),
                        ),
                        GestureDetector(
                          onTap: _pickList,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0x0F000000),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              _listName(_listId),
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.accent),
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        const Expanded(
                          child: Text('Priority',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textPrimary)),
                        ),
                        Row(children: [
                          for (var p = 1; p <= 4; p++) ...[
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _priority = p),
                              child: Container(
                                width: 34,
                                height: 34,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _priority == p
                                      ? AppColors.accent
                                      : const Color(0x0F000000),
                                ),
                                child: Text('P$p',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: _priority == p
                                            ? CupertinoColors.white
                                            : AppColors.textSecondary)),
                              ),
                            ),
                            if (p < 4) const SizedBox(width: 6),
                          ],
                        ]),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        const Expanded(
                          child: Text('Minutes',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textPrimary)),
                        ),
                        GestureDetector(
                          onTap: () => setState(() {
                            if (_minutes > 5) _minutes -= 5;
                          }),
                          child: Container(
                            width: 34,
                            height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: const Color(0x0F000000),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(CupertinoIcons.minus,
                                size: 15, color: AppColors.textPrimary),
                          ),
                        ),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          child: Text('$_minutes',
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary)),
                        ),
                        GestureDetector(
                          onTap: () => setState(() => _minutes += 5),
                          child: Container(
                            width: 34,
                            height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: const Color(0x0F000000),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(CupertinoIcons.add,
                                size: 15, color: AppColors.textPrimary),
                          ),
                        ),
                      ]),
                    ]),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.danger)),
                ],
                const SizedBox(height: 18),
                GestureDetector(
                  onTap: _saving ? null : _save,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    decoration: BoxDecoration(
                      gradient: _saving
                          ? null
                          : const LinearGradient(colors: [
                              AppColors.accent,
                              AppColors.accentSoft
                            ]),
                      color: _saving ? AppColors.textTertiary : null,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Text(_saving ? 'Saving…' : 'Save changes',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.white)),
                  ),
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: _toggleDone,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.glass,
                      borderRadius: BorderRadius.circular(15),
                      border:
                          Border.all(color: const Color(0x14000000)),
                    ),
                    child: Text(
                        _isDone ? 'Mark as not done' : 'Mark as done',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.success)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of Flutter's default ErrorWidget when a widget's build throws.
///
/// In release builds that default is a blank grey box that prints nothing, so a
/// crash looks exactly like a hung request. This renders the message and stack
/// on screen, which is the only way a failure on a real device is reportable.
class _CrashReport extends StatelessWidget {
  const _CrashReport(this.details);

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final msg = details.exception.toString();
    final stack = details.stack?.toString() ?? '';
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: const Color(0xFF111827),
        padding: const EdgeInsets.all(14),
        child: SingleChildScrollView(
          child: Text(
            'VECTOR crashed\n\n$msg\n\n$stack',
            style: const TextStyle(color: Color(0xFFF9FAFB), fontSize: 11),
          ),
        ),
      ),
    );
  }
}
