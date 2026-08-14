# Telemetry status

Superduper Dictation does not ship a telemetry SDK, destination, or application
identifier. The retained telemetry service is an inert compatibility seam for
upstream architecture and tests; production sends no analytics events.

Diagnostic logs remain local under
`~/Library/Application Support/Superduper Dictation/Logs/`. Logs are useful for
troubleshooting and may contain operational metadata. Review a log before
attaching it to a public issue.
