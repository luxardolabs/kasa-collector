# Fake Kasa device emulator image (e2e test harness). Pure stdlib — no deps.
FROM python:3.14-slim
COPY fake_kasa.py /fake_kasa.py
# IOT protocol port (UDP + TCP). Internal only in the e2e stack.
EXPOSE 9999/udp 9999/tcp
CMD ["python3", "/fake_kasa.py"]
