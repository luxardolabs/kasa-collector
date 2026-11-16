#!/bin/sh
# Entrypoint of the dev Grafana (compose.yml, profile bundled), mounted read-only.
#
# The dev Grafana is served by name on the dev host's edge, so it never starts with a password
# anyone can guess: none, Grafana's default `admin`, or the placeholder in .env.example. Grafana
# applies GF_SECURITY_ADMIN_PASSWORD only when it creates its database, so a volume first started
# with another password would keep it: the password is set on every start, then the image's own
# entrypoint runs.
set -eu

password="${GF_SECURITY_ADMIN_PASSWORD:-}"
case "$(printf '%s' "$password" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" in
"" | admin | choose-a-password)
	echo "REFUSING: set GRAFANA_PASSWORD in the env file to a password of your own; this Grafana is served by name" >&2
	exit 1
	;;
esac

# The CLI reads only the first line of stdin, so a line break would set part of the password:
# `admin` from `admin\n…`. A password is one line.
newline='
'
carriage_return=$(printf '\r')
case "$password" in
*"$newline"* | *"$carriage_return"*)
	echo "REFUSING: GRAFANA_PASSWORD holds a line break; set it on one line" >&2
	exit 1
	;;
esac

# On stdin, not as an argument: a password starting with `-` would be read as a flag, and an
# argument shows in `ps`. The CLI's own reason goes to stderr; its stdout is discarded.
if ! printf '%s' "$password" |
	grafana cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin >/dev/null; then
	echo "REFUSING: could not set the admin password from GRAFANA_PASSWORD (grafana cli's reason above)" >&2
	exit 1
fi

exec /run.sh "$@"
