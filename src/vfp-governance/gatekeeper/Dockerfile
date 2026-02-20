FROM python:3.11-slim

WORKDIR /app
COPY *.py /app/

# runtime dirs (created if missing)
RUN mkdir -p /app/state/envelopes /app/events

RUN pip install --no-cache-dir fastapi uvicorn pynacl requests pillow numpy redis
RUN pip install --no-cache-dir python-multipart PyJWT cryptography

EXPOSE 9000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9000"]
