# PR #10 follow-up

- Public sign-up checks the locked event's visibility. Admin bookings can still use a private event. A context test submits using the stale public event.
- iCal validates the expected URL under the service lock before reconciling any rows. Status updates also match the URL. A regression test replaces a feed and delivers an empty response from the previous one.
- Event details reload the event and active service together, follow moves to another service's topic, and remove the form on withdrawal. The LiveView tests exercise these transitions on an already connected page.
- Public host lookups filter for active profiles. The schedule batches its service lookups, and a LiveView test covers an inactive host on both the open detail page and the schedule.
- Cancellation snapshots recipients under the event lock, before new bookings can enter a reopened event. Moves lock the active bookings they update. Cancelling during an edit sends the cancellation notice and skips the reschedule notice.
- Service, event, host and regular-slot changesets map missing referenced rows to field errors. A database-backed test covers a stale host selection on both service and event updates.
