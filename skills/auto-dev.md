---
name: auto-dev
description: Launch the auto-dev multi-terminal agentic workflow for a spec file
arguments:
  - name: spec
    description: Path to the feature spec markdown file
    required: true
---

# Auto-Dev Workflow

Launch the multi-terminal agentic dev workflow for the given spec.

## Steps

1. Validate that `.auto-dev/config.yaml` exists in the current repo
2. If not, run init to scaffold it:

```bash
bash <auto-dev-install-path>/templates/init.sh .
```

3. Run the launcher:

```bash
bash <auto-dev-install-path>/auto-dev.sh --spec $ARGUMENTS.spec --repo .
```

Where `<auto-dev-install-path>` is the directory where auto-dev is installed (check `~/.auto-dev-path` or use the absolute path).

## If `.auto-dev/` Does Not Exist

Run init first, then edit `.auto-dev/config.yaml` to configure:
- `app_runner.command` — the command to start your application
- `reviewer.skills` — which review skills to run
- `workflow.dev_agents` — how many dev agents to use
- `reviewer.severity_gate` — minimum severity to block approval

## After Launch

The workflow runs in tmux. You can:
- `tmux attach -t auto-dev-<project>` to view the session
- Watch the summary dashboard in the bottom pane
- Each agent works in its own visible pane

## Workflow

1. Dev agent reads spec and implements the feature
2. Reviewer agent reviews against repo standards and configured skills
3. Dev agent addresses review feedback
4. Repeats up to `max_rounds` or until reviewer approves
5. PR is created with review history
