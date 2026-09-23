/// VECTOR Tasks — many goals, each with a checklist Hermes manages.
///
/// DESIGN PREMISE
/// --------------
/// A flat list of everything produces paralysis, so this app never shows the
/// whole backlog at once. It shows:
///   1. the ONE thing to start right now (the hero card), and
///   2. the goals, each opened into its own checklist on demand.
///
/// The app PLANS NOTHING. Ordering, dependencies and "what is startable" are
/// decided server-side, so the same plan drives this screen, the home-screen
/// widget and Hermes's own view of the work. Adding a task here writes to that
/// same shared list.
///
/// Ticking a task is optimistic: the row flips immediately, then the server is
/// told, then the list is reloaded so a newly unlocked task appears. A network
/// blip must not make the app feel broken, but it must also not lie — a failed
/// write rolls the row back and says so.
library;

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

void main() => runApp(const VectorTasksApp());

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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _goalController = TextEditingController();
  late final Api _api;

  bool _busy = false;
  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> _goals = [];
  List<Map<String, dynamic>> _startable = [];
  int _doneToday = 0;

  @override
  void initState() {
    super.initState();
    _api = Api(userId: Api.defaultUserId);
    Future.microtask(_boot);
  }

  @override
  void dispose() {
    _goalController.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    // Read the stored owner id, but never let a prefs failure strand the app on
    // a blank screen: fall back to the default id and keep going.
    String id = Api.defaultUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      id = prefs.getString('vector.user_id') ?? Api.defaultUserId;
    } catch (_) {
      // Prefs are an optimisation here, not a requirement.
    }
    _api = Api(userId: id);
    await _reload();
  }

  Future<void> _reload() async {
    try {
      final goals = await _api.goals();
      final startable = await _api.startable();
      final today = await _api.today();
      if (!mounted) return;
      setState(() {
        _goals = goals;
        _startable = startable;
        final rawDone = today['done_today'];
        _doneToday = rawDone is List ? rawDone.length : 0;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      // A non-ApiException here used to escape and leave _loading true forever.
      // Whatever went wrong, the user gets a message and a retry button.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Something went wrong: $e';
      });
    }
  }

  Future<void> _submit() async {
    final goal = _goalController.text.trim();
    if (goal.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.createGoal(goal);
      _goalController.clear();
      await _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Tick a task from the home list, then refresh so an unlocked task appears.
  Future<void> _complete(String taskId) async {
    if (taskId.isEmpty) {
      if (!mounted) return;
      setState(() => _error = 'This task has no id, so it cannot be saved.');
      return;
    }
    final before = List<Map<String, dynamic>>.from(_startable);
    setState(() =>
        _startable.removeWhere((t) => (t['id'] ?? '').toString() == taskId));
    try {
      await _api.completeTask(taskId);
      await _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      // Roll back: showing the task as done when the server disagrees would
      // hide real work.
      setState(() {
        _startable = before;
        _error = 'Could not save: ${e.message}';
      });
    }
  }

  void _openGoal(Map<String, dynamic> goal) {
    Navigator.of(context)
        .push(CupertinoPageRoute(
          builder: (_) => GoalDetailPage(api: _api, goal: goal),
        ))
        .then((_) => _reload());
  }

  @override
  Widget build(BuildContext context) {
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
              // Pull-to-refresh is CupertinoSliverRefreshControl: RefreshIndicator
              // is a Material widget and this app never imports Material.
              : CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    CupertinoSliverRefreshControl(onRefresh: _reload),
                    SliverToBoxAdapter(child: _header()),
                    if (_error != null)
                      SliverToBoxAdapter(child: _errorBanner(_error!)),
                    SliverToBoxAdapter(child: _nextActionCard()),
                    SliverToBoxAdapter(child: _goalsHeading()),
                    _goalsList(),
                    SliverToBoxAdapter(child: _newGoalCard()),
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
                  child: Text('Your goals',
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

  /// The one thing to do now. This is the whole point of the product, so it
  /// gets the most prominent surface on the screen.
  Widget _nextActionCard() {
    if (_startable.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
        child: _glass(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              const Icon(CupertinoIcons.checkmark_circle_fill,
                  size: 26, color: AppColors.success),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('All clear',
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary)),
                    SizedBox(height: 3),
                    Text('Nothing is startable right now. Add a goal below.',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      );
    }

    final task = _startable.first;
    // `id` is the tasks-table primary key so it is always present, but a
    // missing key must degrade to '' (which surfaces a save error) rather than
    // throw on null.toString() and kill the home screen.
    final id = (task['id'] ?? '').toString();
    final extra = _startable.length - 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [AppColors.accent, AppColors.accentSoft]),
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [
            BoxShadow(
                color: Color(0x336366F1),
                blurRadius: 26,
                offset: Offset(0, 12)),
          ],
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('START HERE',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xCCFFFFFF),
                    letterSpacing: 1.4)),
            const SizedBox(height: 10),
            Text(task['title']?.toString() ?? '',
                style: const TextStyle(
                    fontSize: 20,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                    color: CupertinoColors.white)),
            if ((task['why'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(task['why'].toString(),
                  style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: Color(0xCCFFFFFF))),
            ],
            const SizedBox(height: 14),
            Row(children: [
              const Icon(CupertinoIcons.time,
                  size: 15, color: Color(0xCCFFFFFF)),
              const SizedBox(width: 5),
              Text('${task['minutes']} min',
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xCCFFFFFF))),
              if (extra > 0) ...[
                const SizedBox(width: 14),
                Text('$extra more unlocked',
                    style: const TextStyle(
                        fontSize: 13, color: Color(0x99FFFFFF))),
              ],
              const Spacer(),
              GestureDetector(
                onTap: () => _complete(id),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    color: CupertinoColors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('Done',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accent)),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _goalsHeading() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 30, 24, 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('All goals',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textTertiary,
                    letterSpacing: 1.2)),
            Text('${_goals.length}',
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textTertiary)),
          ],
        ),
      );

  Widget _goalsList() {
    if (_goals.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text('No goals yet. Add one below.',
              style: TextStyle(
                  fontSize: 14, color: AppColors.textSecondary.withOpacity(1))),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      sliver: SliverList.builder(
        itemCount: _goals.length,
        itemBuilder: (_, i) {
          final g = _goals[i];
          // `is` checks, not `as` casts: a wrong-typed value degrades to 0
          // instead of throwing inside the build and blanking the screen.
          final pct = g['pct_done'] is num ? (g['pct_done'] as num).toInt() : 0;
          final total =
              g['total_tasks'] is num ? (g['total_tasks'] as num).toInt() : 0;
          final done =
              g['done_tasks'] is num ? (g['done_tasks'] as num).toInt() : 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GestureDetector(
              onTap: () => _openGoal(g),
              child: _glass(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(g['title']?.toString() ?? '',
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary)),
                        ),
                        const Icon(CupertinoIcons.chevron_right,
                            size: 15, color: AppColors.textTertiary),
                      ]),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Container(
                          height: 4,
                          color: const Color(0x14000000),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: pct / 100,
                            child: Container(
                              color: pct == 100
                                  ? AppColors.success
                                  : AppColors.accent,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text('$done of $total done  ·  $pct%',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _newGoalCard() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('NEW GOAL',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textTertiary,
                    letterSpacing: 1.2)),
            const SizedBox(height: 8),
            const Text(
              'Type the outcome you want, not the steps. Hermes builds the '
              'task list and keeps it ordered.',
              style: TextStyle(
                  fontSize: 13, height: 1.4, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            _glass(
              child: CupertinoTextField(
                controller: _goalController,
                placeholder: 'e.g. Get a quant internship in Germany',
                placeholderStyle:
                    const TextStyle(color: AppColors.textTertiary),
                padding: const EdgeInsets.all(15),
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(
                    fontSize: 15, color: AppColors.textPrimary),
                decoration: null,
              ),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _busy ? null : _submit,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 15),
                decoration: BoxDecoration(
                  gradient: _busy
                      ? null
                      : const LinearGradient(
                          colors: [AppColors.accent, AppColors.accentSoft]),
                  color: _busy ? AppColors.textTertiary : null,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Text(_busy ? 'Hermes is planning…' : 'Build my plan',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.white)),
              ),
            ),
          ],
        ),
      );

  Widget _glass({required Widget child}) => Container(
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
}

/// One goal, opened: the full checklist with tickable rows.
///
/// This is where the dependency model becomes visible. A blocked task is shown
/// greyed with the name of what it is waiting on, so the user can see WHY it
/// cannot be started instead of assuming the app is broken.
class GoalDetailPage extends StatefulWidget {
  const GoalDetailPage({super.key, required this.api, required this.goal});

  final Api api;
  final Map<String, dynamic> goal;

  @override
  State<GoalDetailPage> createState() => _GoalDetailPageState();
}

class _GoalDetailPageState extends State<GoalDetailPage> {
  final _taskController = TextEditingController();

  bool _loading = true;
  bool _adding = false;
  String? _error;
  GoalTasks? _goal;
  List<Map<String, dynamic>> _tasks = [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _taskController.dispose();
    super.dispose();
  }

  // GET /goals (goal_progress view) keys the identifier as `goal_id`, not
  // `id`. Fall back to `id` for goal maps that came from POST /goals (a raw
  // goals-table row). A missing key degrades to '' and the loader below shows
  // an error instead of requesting /goals/null/tasks or throwing.
  String get _goalId =>
      (widget.goal['goal_id'] ?? widget.goal['id'] ?? '').toString();

  Future<void> _load() async {
    final goalId = _goalId;
    if (goalId.isEmpty) {
      // No identifier arrived with the goal map: say so instead of requesting
      // /goals//tasks and showing a confusing server error.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'This goal has no id, so its tasks cannot be loaded.';
      });
      return;
    }
    try {
      final data = await widget.api.goalTasks(goalId);
      final parsed = GoalTasks.fromJson(data);
      if (!mounted) return;
      setState(() {
        _goal = parsed;
        _tasks = parsed.tasks;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      // GoalTasks.fromJson must never throw, but if it ever does the page
      // shows a message and a retry instead of a blank screen.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Something went wrong: $e';
      });
    }
  }

  Future<void> _toggle(Map<String, dynamic> task) async {
    final id = (task['id'] ?? '').toString();
    if (id.isEmpty) {
      if (!mounted) return;
      setState(() => _error = 'This task has no id, so it cannot be saved.');
      return;
    }
    final wasDone = task['status'] == 'done';
    // Optimistic flip so the tap feels instant.
    setState(() {
      for (final t in _tasks) {
        if ((t['id'] ?? '').toString() == id && id.isNotEmpty) {
          t['status'] = wasDone ? 'todo' : 'done';
        }
      }
    });
    try {
      if (wasDone) {
        await widget.api.reopenTask(id);
      } else {
        await widget.api.completeTask(id);
      }
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not save: ${e.message}');
      await _load();
    }
  }

  Future<void> _addTask() async {
    final title = _taskController.text.trim();
    if (title.isEmpty || _adding) return;
    setState(() => _adding = true);
    try {
      await widget.api.addTask(_goalId, title);
      _taskController.clear();
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _confirmDelete() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete this goal?'),
        content: Text('“${widget.goal['title']}” and its '
            '${_tasks.length} tasks will be removed.'),
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
    try {
      await widget.api.deleteGoal(_goalId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pct = _goal?.pctDone ?? 0;
    final done = _goal?.done ?? 0;
    final total = _goal?.total ?? 0;

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Goal'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          minSize: 0,
          onPressed: _confirmDelete,
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
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            // CustomScrollView + SliverList, not ListView: this is the same
            // pattern the other two apps use and that CI has already verified
            // compiles with a Cupertino-only import set.
            : CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        Text(widget.goal['title']?.toString() ?? '',
                            style: const TextStyle(
                                fontSize: 24,
                                height: 1.25,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                        const SizedBox(height: 14),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            height: 6,
                            color: const Color(0x14000000),
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: pct / 100,
                              child: Container(
                                color: pct == 100
                                    ? AppColors.success
                                    : AppColors.accent,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('$done of $total done  ·  $pct%',
                            style: const TextStyle(
                                fontSize: 13, color: AppColors.textSecondary)),
                        if (_error != null) ...[
                          const SizedBox(height: 14),
                          Text(_error!,
                              style: const TextStyle(
                                  fontSize: 13, color: AppColors.danger)),
                        ],
                        const SizedBox(height: 22),
                        for (final t in _tasks) _taskRow(t),
                        const SizedBox(height: 20),
                        _addTaskField(),
                      ]),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _taskRow(Map<String, dynamic> raw) {
    final task = TaskState.fromJson(raw);
    final isDone = task.isDone;
    final isSkipped = task.isSkipped;
    final startable = task.startable;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
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
              onTap: () => _toggle(raw),
              child: Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone ? AppColors.success : const Color(0x0F000000),
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
                  Text(task.title,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.3,
                        fontWeight:
                            startable && !isDone ? FontWeight.w600 : FontWeight.w400,
                        color: isDone || isSkipped
                            ? AppColors.textTertiary
                            : AppColors.textPrimary,
                        decoration:
                            isDone ? TextDecoration.lineThrough : null,
                      )),
                  const SizedBox(height: 4),
                  // Say WHY a task cannot start. A greyed row with no
                  // explanation reads as a bug.
                  Text(task.subtitle,
                      style: TextStyle(
                          fontSize: 12,
                          color: isDone
                              ? AppColors.success
                              : startable
                                  ? AppColors.accent
                                  : AppColors.textTertiary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addTaskField() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ADD A TASK',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textTertiary,
                  letterSpacing: 1.1)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.glass,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0x14000000)),
                ),
                child: CupertinoTextField(
                  controller: _taskController,
                  placeholder: 'What needs doing?',
                  placeholderStyle:
                      const TextStyle(color: AppColors.textTertiary),
                  padding: const EdgeInsets.all(13),
                  style: const TextStyle(
                      fontSize: 14, color: AppColors.textPrimary),
                  decoration: null,
                  onSubmitted: (_) => _addTask(),
                ),
              ),
            ),
            const SizedBox(width: 9),
            GestureDetector(
              onTap: _adding ? null : _addTask,
              child: Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: _adding ? AppColors.textTertiary : AppColors.accent,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(CupertinoIcons.add,
                    size: 19, color: CupertinoColors.white),
              ),
            ),
          ]),
        ],
      );
}
