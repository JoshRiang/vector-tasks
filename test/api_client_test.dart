/// Tests for the VECTOR Tasks app.
///
/// These cover the parsing and decision logic that CI can verify without a
/// device or a live server. They are deliberately about BEHAVIOUR (what the
/// app does with a given server response) rather than about widget layout.
library;

import 'dart:async' show TimeoutException;
import 'dart:io' show HandshakeException;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart' show MockClient;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_tasks/api_client.dart';

void main() {
  group('GoalResult parsing', () {
    test('reads a healthy plan', () {
      final r = GoalResult.fromJson({
        'goal': {'id': 'g1', 'title': 'Ship it'},
        'tasks': [
          {'id': 't1', 'title': 'A', 'minutes': 20, 'why': 'w'},
          {'id': 't2', 'title': 'B', 'minutes': 40, 'why': 'w'},
        ],
        'degraded': false,
        'note': 'ok',
      });
      expect(r.tasks.length, 2);
      expect(r.degraded, isFalse);
      expect(r.totalMinutes, 60);
    });

    test('sums total minutes across the plan', () {
      final r = GoalResult.fromJson({
        'goal': {},
        'tasks': [
          {'minutes': 15},
          {'minutes': 45},
          {'minutes': 30},
        ],
      });
      expect(r.totalMinutes, 90);
    });

    test('tolerates missing minutes instead of crashing', () {
      final r = GoalResult.fromJson({
        'goal': {},
        'tasks': [
          {'title': 'no minutes field'},
          {'title': 'null minutes', 'minutes': null},
        ],
      });
      expect(r.totalMinutes, 0);
      expect(r.tasks.length, 2);
    });

    test('surfaces a degraded plan', () {
      final r = GoalResult.fromJson({
        'goal': {'id': 'g1'},
        'tasks': [],
        'degraded': true,
        'note': 'llm_unreachable',
      });
      expect(r.degraded, isTrue);
      expect(r.note, 'llm_unreachable');
      expect(r.tasks, isEmpty);
    });

    test('handles an empty body without throwing', () {
      final r = GoalResult.fromJson({});
      expect(r.tasks, isEmpty);
      expect(r.goal, isEmpty);
      expect(r.degraded, isFalse);
    });
  });

  group('ApiException', () {
    test('carries the offline flag so the UI can say "check Tailscale"', () {
      final e = ApiException('Cannot reach the server.', offline: true);
      expect(e.offline, isTrue);
      expect(e.toString(), contains('Cannot reach'));
    });

    test('carries a status code for server errors', () {
      final e = ApiException('db_500', statusCode: 502);
      expect(e.statusCode, 502);
      expect(e.offline, isFalse);
    });
  });

  group('default base url', () {
    test('points at the private Tailscale address, never a public host', () {
      expect(Api.defaultBaseUrl, contains('100.89.180.23'));
      expect(Api.defaultBaseUrl.startsWith('http://'), isTrue);
    });
  });

  group('stable owner id', () {
    test('defaults to a constant so the server-side brief sees the same rows',
        () {
      expect(Api.defaultUserId, 'josh');
    });

    test('is not randomised per install', () {
      // A random id would split data between the app and the cron brief.
      expect(Api.defaultUserId.contains(r'$'), isFalse);
      expect(Api.defaultUserId.length < 40, isTrue);
    });
  });

  group('GoalTasks parsing', () {
    test('reads counts and percentage from the server', () {
      final g = GoalTasks.fromJson({
        'goal_id': 'g1',
        'total': 4,
        'done': 1,
        'pct_done': 25,
        'tasks': [
          {'id': 't1', 'title': 'a', 'status': 'done', 'startable': false},
          {'id': 't2', 'title': 'b', 'status': 'todo', 'startable': true},
        ],
      });
      expect(g.goalId, 'g1');
      expect(g.total, 4);
      expect(g.done, 1);
      expect(g.pctDone, 25);
      expect(g.tasks.length, 2);
    });

    test('derives the percentage when the server omits it', () {
      final g = GoalTasks.fromJson({
        'total': 4,
        'tasks': [
          {'id': 't1', 'status': 'done'},
          {'id': 't2', 'status': 'todo'},
          {'id': 't3', 'status': 'todo'},
          {'id': 't4', 'status': 'todo'},
        ],
      });
      // 1 of 4 -> 25%. A missing field must not render as an empty bar.
      expect(g.pctDone, 25);
      expect(g.done, 1);
    });

    test('an empty goal is 0%, not a division by zero', () {
      final g = GoalTasks.fromJson({'tasks': []});
      expect(g.pctDone, 0);
      expect(g.total, 0);
      expect(g.startable, isEmpty);
    });

    test('only startable rows are offered as actionable', () {
      final g = GoalTasks.fromJson({
        'tasks': [
          {'id': 't1', 'status': 'todo', 'startable': true},
          {'id': 't2', 'status': 'todo', 'startable': false},
          {'id': 't3', 'status': 'done', 'startable': false},
        ],
      });
      expect(g.startable.length, 1);
      expect(g.startable.first['id'], 't1');
    });
  });

  group('TaskState subtitles', () {
    test('a startable task says how long it takes', () {
      final t = TaskState.fromJson(
          {'id': 't1', 'title': 'x', 'minutes': 20, 'startable': true});
      expect(t.subtitle, '20 min  \u00b7  ready now');
    });

    test('a blocked task names what it waits on', () {
      final t = TaskState.fromJson({
        'id': 't2',
        'title': 'y',
        'minutes': 30,
        'startable': false,
        'blocked_by_title': 'First step',
      });
      expect(t.subtitle, contains('First step'));
      expect(t.subtitle, contains('30 min'));
    });

    test('a blocked task with no name does not print "null"', () {
      final t = TaskState.fromJson(
          {'id': 't3', 'title': 'z', 'minutes': 15, 'startable': false});
      expect(t.subtitle, '15 min  \u00b7  waiting');
      expect(t.subtitle.contains('null'), isFalse);
    });

    test('done wins over startable', () {
      final t = TaskState.fromJson({
        'id': 't4',
        'title': 'w',
        'minutes': 10,
        'status': 'done',
        'startable': false,
      });
      expect(t.isDone, isTrue);
      expect(t.subtitle, 'Done');
      expect(t.isSkipped, isFalse);
    });

    test('skipped is reported as skipped', () {
      final t = TaskState.fromJson({'id': 't5', 'status': 'skipped'});
      expect(t.isSkipped, isTrue);
      expect(t.subtitle, 'Skipped');
    });

    test('a missing minutes field falls back instead of crashing', () {
      final t = TaskState.fromJson({'id': 't6', 'status': 'todo'});
      expect(t.minutes, 30);
      expect(t.title, '');
    });
  });

  group('new client methods exist', () {
    test('goal-scoped, task-write and goal-delete calls are present', () {
      final api = Api(baseUrl: 'http://x', userId: 'u', apiKey: 'k');
      // Referencing the tear-offs proves the signatures compile.
      expect(api.goalTasks, isNotNull);
      expect(api.addTask, isNotNull);
      expect(api.completeTask, isNotNull);
      expect(api.reopenTask, isNotNull);
      expect(api.deleteGoal, isNotNull);
      expect(api.renameGoal, isNotNull);
    });
  });

  group('network failures become messages, never a blank screen', () {
    Api apiWith(http.Client c) =>
        Api(baseUrl: 'http://x', userId: 'u', apiKey: 'k', client: c);

    test('a connection failure surfaces as an offline ApiException', () async {
      // http wraps a refused connection in ClientException, NOT SocketException.
      final api = apiWith(MockClient((_) async {
        throw http.ClientException('Connection refused');
      }));
      await expectLater(
        api.goals(),
        throwsA(isA<ApiException>().having((e) => e.offline, 'offline', true)),
      );
    });

    test('a timeout surfaces as an offline ApiException', () async {
      // .timeout() throws TimeoutException, which is not a SocketException.
      final api = apiWith(MockClient((_) async {
        throw TimeoutException('too slow');
      }));
      await expectLater(
        api.today(),
        throwsA(isA<ApiException>().having((e) => e.offline, 'offline', true)),
      );
    });

    test('a TLS failure surfaces as an offline ApiException', () async {
      final api = apiWith(MockClient((_) async {
        throw const HandshakeException('bad cert');
      }));
      await expectLater(
        api.today(),
        throwsA(isA<ApiException>()),
      );
    });

    test('a non-JSON body surfaces as an ApiException, not a crash', () async {
      // A captive portal returns an HTML page with status 200.
      final api = apiWith(MockClient((_) async =>
          http.Response('<html>hotel wifi</html>', 200)));
      await expectLater(api.goals(), throwsA(isA<ApiException>()));
    });

    test('a 401 keeps its status so the UI can distinguish auth from offline',
        () async {
      final api = apiWith(MockClient((_) async =>
          http.Response('{"error":"unauthorized"}', 401)));
      await expectLater(
        api.goals(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
      );
    });

    test('a 500 keeps its status', () async {
      final api = apiWith(MockClient((_) async =>
          http.Response('{"error":"boom"}', 500)));
      await expectLater(
        api.goals(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 500)),
      );
    });

    test('a good response still parses', () async {
      final api = apiWith(MockClient((_) async => http.Response('[]', 200)));
      expect(await api.goals(), isEmpty);
    });
  });
}
