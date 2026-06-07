# Training Loop Feedback

Unified behavioral quality feedback for the three training dimensions:
SkillOpt (skill triggers), MultiAgentOpt (parallel dispatch), ToolCallOpt (tool usage).

## SkillOpt — Skill Trigger Accuracy

### Miss
Skill should have triggered but did not.

### False Positive
Skill triggered but was irrelevant.

## MultiAgentOpt — Agent Dispatch Accuracy

### Miss
Multi-agent dispatch should have been suggested but was not.

### False Positive
Multi-agent dispatch was suggested but was inappropriate.

## ToolCallOpt — Tool Call Pattern Quality

### Positive
What worked well in tool usage. e.g. Read-before-Edit, test-after-change, efficient batching.

### Negative
What should be corrected. e.g. Blind Edit, Retry Loop, Tiny Steps, Write-then-Read.
