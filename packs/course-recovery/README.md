# Experimental course recovery

Steward supervision of unanswered internal requests, enabled only by the eval
overlay. The production system pack and harness core are unchanged.

The steward holds a request when an agent addresses it with `to = "steward"`
(a depth-0 agent that is not `workflow_only`). Its `correct_course` escalates
the correction to the front desk by name; the front desk stays the one that
asks the client.

See [how to measure course recovery](../../docs/how-to-measure-course-recovery.md).
