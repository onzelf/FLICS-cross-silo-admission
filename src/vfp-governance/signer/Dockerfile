FROM python:3.12-slim

WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn cryptography

COPY signer.py /app/signer.py

ENV HOLDER_KEYS_DIR=/vault/holder_keys
EXPOSE 8090
CMD ["uvicorn","signer:app","--host","0.0.0.0","--port","8090"]
