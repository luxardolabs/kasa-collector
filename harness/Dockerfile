# Fake Kasa device emulator image (e2e test harness). Pure stdlib — no deps.
FROM python:3.14-slim
COPY fake_kasa.py fake_smart.py /
# IOT protocol port (UDP + TCP); SMART discovery (UDP 20002) and KLAP over HTTP (80).
# Internal only in the e2e stack.
EXPOSE 9999/udp 9999/tcp 20002/udp 80/tcp
# The IOT emulator by default; a SMART strip runs `python3 /fake_smart.py`.
CMD ["python3", "/fake_kasa.py"]
