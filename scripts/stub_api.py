#!/usr/bin/env python3
"""Stub API server for vector-tasks screenshots.
Uses only Python stdlib (http.server).
Served on port 9473 with realistic sample data matching the app's expectations.
"""
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime, timedelta

# Realistic sample data matching UI expectations
GOALS = [
    {"goal_id": "g1", "id": "g1", "title": "Ship vector-tasks v2"},
    {"goal_id": "g2", "id": "g2", "title": "Get quant internship Germany"},
    {"goal_id": "g3", "id": "g3", "title": "Finish thesis chapter 3"},
]

TASKS = {
    "g1": [
        {"id": "t1", "title": "Write Liquid Glass widget tests", "minutes": 30, "status": "todo", "startable": True, "scheduled_at": (datetime.now() + timedelta(hours=2)).isoformat(), "priority": 2, "all_day": False, "blocked_by_title": ""},
        {"id": "t2", "title": "Fix overflow on priority badge", "minutes": 15, "status": "done", "startable": False, "scheduled_at": (datetime.now() - timedelta(days=1)).isoformat(), "priority": 1, "all_day": False},
        {"id": "t3", "title": "Add task detail notes field", "minutes": 45, "status": "todo", "startable": False, "blocked_by_title": "Fix overflow on priority badge", "scheduled_at": (datetime.now() + timedelta(days=1)).isoformat(), "priority": 3, "all_day": False},
    ],
    "g2": [
        {"id": "t4", "title": "Draft cover letter for Deutsche Bank", "minutes": 40, "status": "todo", "startable": True, "scheduled_at": datetime.now().isoformat(), "priority": 1, "all_day": False},
        {"id": "t5", "title": "Schedule mock interview", "minutes": 20, "status": "todo", "startable": False, "blocked_by_title": "Draft cover letter", "scheduled_at": (datetime.now() + timedelta(days=2)).isoformat(), "priority": 2, "all_day": True},
        {"id": "t6", "title": "Update LinkedIn headline", "minutes": 10, "status": "done", "startable": False, "scheduled_at": (datetime.now() - timedelta(days=2)).isoformat(), "priority": 3, "all_day": False},
    ],
    "g3": [
        {"id": "t7", "title": "Run Monte Carlo backtest", "minutes": 60, "status": "todo", "startable": True, "scheduled_at": (datetime.now() + timedelta(days=1)).isoformat(), "priority": 1, "all_day": False},
        {"id": "t8", "title": "Write literature review section", "minutes": 90, "status": "todo", "startable": False, "blocked_by_title": "Run Monte Carlo backtest", "scheduled_at": (datetime.now() + timedelta(days=3)).isoformat(), "priority": 2, "all_day": False},
    ],
}

def get_startable_tasks():
    """Return tasks where startable is True"""
    out = []
    for goal_tasks in TASKS.values():
        for t in goal_tasks:
            if t.get("startable"):
                out.append({**t, "goal_id": None})  # Will be filled by client
    # Add some dated tasks with no goal
    out.append({
        "id": "t9", "title": "Dentist appointment", "minutes": 30, "status": "todo",
        "startable": True, "scheduled_at": (datetime.now() + timedelta(days=1, hours=14)).isoformat(),
        "priority": 2, "all_day": False, "goal_id": "__none__"
    })
    return out

def compute_goal_stats(goal_id):
    tasks = TASKS.get(goal_id, [])
    total = len(tasks)
    done = sum(1 for t in tasks if t.get("status") == "done")
    pct = round((100 * done / total) if total else 0)
    return total, done, pct

class Handler(BaseHTTPRequestHandler):
    # CORS: the page is served from :9474 and talks to this stub on :9473,
    # a cross-origin fetch. Without these headers the browser blocks every
    # response and the app renders its "cannot reach server" state instead of
    # the task list, so the screenshots would be meaningless.
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-User-Id, X-Api-Key")

    def do_OPTIONS(self):
        # Preflight: answer 204 with the CORS headers so the browser lets the
        # real request through. No body.
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _parse_path(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        return path, query

    def do_GET(self):
        path, query = self._parse_path()
        
        if path == "/goals":
            self._json(GOALS)
        elif path.startswith("/goals/") and path.endswith("/tasks"):
            goal_id = path.split("/")[2]
            tasks = TASKS.get(goal_id, [])
            total, done, pct = compute_goal_stats(goal_id)
            self._json({
                "goal_id": goal_id,
                "tasks": tasks,
                "total": total,
                "done": done,
                "pct_done": pct
            })
        elif path == "/tasks/startable":
            self._json(get_startable_tasks())
        elif path == "/today":
            # done_today should be a list per main.dart line 249
            done_today_ids = ["t2", "t6"]
            self._json({
                "done_today": [{"id": id} for id in done_today_ids],
                "scheduled": 5
            })
        elif path == "/productivity":
            self._json({
                "focus_hours": 4.5,
                "deep_work_minutes": 270,
                "tasks_done": 12,
                "streak_days": 7,
                "weekly_goal": 15
            })
        elif path == "/finance":
            self._json({
                "budget_month": 2500,
                "spent_month": 1834,
                "remaining": 666,
                "runway_months": 3.2
            })
        elif path == "/calendar/range":
            # Return dated items across the range
            start = query.get("start", [""])[0]
            end = query.get("end", [""])[0]
            items = []
            # Flatten tasks with scheduled_at
            for goal_id, goal_tasks in TASKS.items():
                for t in goal_tasks:
                    if t.get("scheduled_at"):
                        items.append({
                            "id": t["id"],
                            "goal_id": goal_id,
                            "title": t["title"],
                            "scheduled_at": t["scheduled_at"],
                            "all_day": t.get("all_day", False),
                            "minutes": t.get("minutes", 30),
                            "status": t.get("status", "todo")
                        })
            self._json({"items": items})
        elif path == "/commands":
            self._json([
                {"id": "c1", "role": "user", "content": "add dentist appointment tomorrow", "created_at": (datetime.now() - timedelta(hours=5)).isoformat()},
                {"id": "c2", "role": "assistant", "content": "Added dentist appointment", "created_at": (datetime.now() - timedelta(hours=5)).isoformat()},
            ])
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path, _ = self._parse_path()
        # Read body
        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len) if content_len else b""

        if path == "/diag":
            self._json({})
        elif path == "/tasks":
            # Echo back a created task
            data = json.loads(body or b"{}")
            data["id"] = f"t_new_{datetime.now().timestamp()}"
            self._json(data)
        elif "/done" in path or "/reopen" in path:
            self._json({})
        elif path == "/goals":
            data = json.loads(body or b"{}")
            new_id = f"g_new_{datetime.now().timestamp()}"
            self._json({"goal_id": new_id, "id": new_id, "title": data.get("title", "New Goal")})
        else:
            self._json({}, status=200)

    def log_message(self, format, *args):
        # Silence default logging
        pass

def main():
    server = HTTPServer(("localhost", 9473), Handler)
    print("Stub API listening on http://localhost:9473")
    server.serve_forever()

if __name__ == "__main__":
    main()
