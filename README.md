# HomeKit Monitor

A macOS Catalyst app that monitors HomeKit events in real-time and publishes them to MQTT.

Subscribe to specific events with pattern matching, then configure MQTT topics and JSON payloads with value interpolation using `{{value}}`. All accessories show room information for easy identification across multiple devices.

Events are logged with timestamps and kept to the last 1000 entries for performance.
