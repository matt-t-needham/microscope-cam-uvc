# Agent Instructions — MicroscopeCam

You are building a small Flutter app called MicroscopeCam. It is a toy project. Keep everything simple and boring.

Read PRD.md to know what to build. Read progress.md (create it if missing) to know what's already done.

## Rules

- Work on exactly ONE unchecked task per iteration
- No clever architecture. No abstractions. No design patterns. Stateful widgets are fine.
- Use only packages listed in the PRD. Do not add anything else.
- Run `flutter analyze` after every change. Fix all errors. Do not leave warnings.
- Commit after each completed task: `git add -A && git commit -m "feat: <task name>"`
- Make decisions yourself. Do not ask questions. Do not leave TODOs.
- If something is ambiguous, pick the dumbest implementation that works.

## State

After completing a task, append a line to progress.md:
```
- [x] Task N: <task name>
```

## Done

When all tasks in PRD.md are complete:
1. Run `flutter build apk`
2. Run `flutter build ios --no-codesign`
3. Fix any errors
4. Output: `<promise>COMPLETE</promise>`

Now read PRD.md and progress.md and get to work.