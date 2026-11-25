# KASACOLLEC-166: the collector's output defaults to a named volume

The collector-only and local stacks used to bind the host path /mnt/docker/kasa-collector/output when OUTPUT_DIR was unset. Docker creates that path owned by root, and the collector runs as uid 1000, so on most hosts nothing could be written there. From this release the default is the named volume kasa_collector_output, which the collector can write. It holds the device roster (known_devices.json) and any .jsonl exports.

If your collector did write to /mnt/docker/kasa-collector/output, because the directory already existed owned by uid 1000, keep using it: set `OUTPUT_DIR=/mnt/docker/kasa-collector/output` in your env file before upgrading. Otherwise the collector starts on the new, empty volume and rebuilds its roster from the next discovery. The dev stack's .env.dev sets it already.
