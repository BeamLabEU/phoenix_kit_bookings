# Review of PR #10

Reviewed the proposed V3 booking features at `6954a6c` against upstream main at `162698b`.

| Severity | Finding | Impact |
| --- | --- | --- |
| BUG - HIGH | Public event sign-up checked the event's status and time under lock but omitted its visibility. | A visitor could submit an already-open form after the organiser withdrew the event. |
| BUG - HIGH | iCal sync used the fetched service's URL without comparing it to the current URL under the import lock. | A response from a removed or replaced feed could delete the current feed's imported bookings, reopen occupied time, and overwrite the sync status. |
| BUG - MEDIUM | Event details refreshed seat counts using the event captured on navigation. Moving an empty event also skipped the announcement to its old service. | Connected visitors could see obsolete times, titles, or sign-up forms. |
| BUG - MEDIUM | Public event cards and the detail page fetched hosts without filtering their status. | An inactive host's name and profile link remained visible. |
| BUG - MEDIUM | Cancellation chose recipients after releasing the event lock using timestamps with one-second precision. Event moves read the bookings to update without locking them. | A rapid reopening could cancel a new sign-up, and a cancellation racing a move could receive a reschedule notice. |
| BUG - MEDIUM | Several admin changesets omitted database foreign-key mappings for selected accounts or hosts. | A selection deleted before save could raise an exception and disconnect the form. |
| IMPROVEMENT - MEDIUM | Each distinct service on the public schedule triggered an individual read. | Rendering a schedule with many services required a growing number of database round trips. |

The resolution for each finding is in [FOLLOW_UP.md](FOLLOW_UP.md).
