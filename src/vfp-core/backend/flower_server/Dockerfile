FROM python:3.10-slim

WORKDIR /app

 RUN pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cpu \
    torch torchvision \
    flwr requests uvicorn fastapi redis pydantic pillow

COPY server.py /app/server.py

# Mount certs at runtime
VOLUME ["/run/certs"]

ENV REDIS_URL=redis://redis:6379
ENV VERIFIER_URL=https://verifier-proxy:8443
ENV HUB_URL=http://fc-hub:8080
ENV VERIFY_TLS=0
ENV NUM_ROUNDS=3
ENV MIN_CLIENTS=2


CMD ["python", "server.py"]