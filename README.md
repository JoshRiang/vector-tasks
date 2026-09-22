# Vector Tasks

**Type one end goal. Get back a plan you can actually start.**

Part of the **VECTOR Suite** — three apps, one private database.

---

## The problem this solves

> "I'm not productive, why? Because I have too many to-do lists, and I don't
> know where to start, so it leads to nothing started."

The problem is **not** a missing to-do list. A list of twenty undifferentiated
items is what *causes* the paralysis. So this app inverts the normal model:

**You never write a task.** You type an outcome — *"get a quant internship in
Germany"*, *"finish my thesis chapter 3"* — and the assistant returns a
dependency-ordered plan whose **first step is always something you can start in
under 30 minutes**.

## The one design decision that matters

The app shows **exactly one task at a time**.

Blocking is enforced in the database, not the UI:

```sql
where t.status in ('todo','doing')
  and (t.blocked_by is null or b.status = 'done')
```

A task whose blocker is unfinished is *never* returned to the app. A UI that
merely hides the rest still leaves the whole list in your head — so the filter
lives in the data layer, where it cannot be bypassed.

Finish the current task → the next one unlocks. That's the whole loop.

## Home-screen widget

A native Android widget (`NextActionWidget`) shows the single next action
without opening the app. It fetches the API directly on a background thread, so
it stays current rather than showing a stale snapshot.

## Screens

- **Goal input** — one text field. Nothing else.
- **The plan** — one task, its rationale, and its time estimate. A progress bar
  shows how far along you are without showing everything left to do.
- **Completion** — when the plan is finished it says so, and offers a new goal.

## Architecture

```
Flutter app  ──HTTP──▶  VECTOR Suite API  ──▶  private database
  (this repo)             (decompose + store)
```

The app never calls a language model directly. The model key lives server-side
only: anything embedded in an APK is extractable with `unzip` and `strings`.

## Build

```bash
flutter pub get
flutter test
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

Point it at your own server:

```bash
flutter build apk --dart-define=API_BASE=https://your-host
```

CI builds the APK on every push and injects `API_BASE` from the repository
variable of the same name, so the endpoint can change without touching code.

## Widget endpoint

The widget reads `vector_api_base` from
`android/app/src/main/res/values/strings.xml`. The CI build rewrites that value
from the same `API_BASE` variable, so the widget and the app can never point at
different servers.

## The VECTOR Suite

| App | Question it answers |
|---|---|
| **Vector Tasks** (this) | What is the one thing to start right now? |
| [Vector Calendar](https://github.com/JoshRiang/vector-calendar) | How is today going? |
| [Vector Finance](https://github.com/JoshRiang/vector-finance) | How much runway is left? |

All three share one private database, so a task created here appears on the
calendar and informs the day's cost.

## Privacy

Every table is row-level-security gated on the authenticated user. The backend
runs on the owner's own server.

## Licence

MIT
