---
name: spex
description: Launch the spex agentic workflow for a spec file
arguments:
  - name: spec
    description: Path to the feature spec markdown file
    required: true
---

# Spex Workflow

Launch the agentic dev workflow for the given spec.

## Steps

1. Validate that `.specify/config.yaml` exists in the current repo
2. If not, run init to scaffold it:

```bash
bash <spex-install-path>/init.sh .
```

3. Run the launcher:

```bash
bash <spex-install-path>/spex.sh --spec $ARGUMENTS.spec --repo .
```

Where `<spex-install-path>` is the directory where spex is installed (check `~/.specify-path` or use the absolute path).

## If `.specify/` Does Not Exist

Run init first, then edit `.specify/config.yaml` to configure:
- `app_runner.command` — the command to start your application
- `reviewer.skills` — which review skills to run
- `workflow.dev_agents` — how many dev agents to use
- `reviewer.severity_gate` — minimum severity to block approval

## After Launch

The workflow runs inline in your terminal. You can:
- Watch agents work in real time as output streams to your terminal
- Press Ctrl+C to abort the workflow
- Review agent logs in `.specify/messages/`

## Workflow

1. Dev agent reads spec and implements the feature
2. Reviewer agent reviews against repo standards and configured skills
3. Dev agent addresses review feedback
4. Repeats up to `max_rounds` or until reviewer approves
5. PR is created with review history
