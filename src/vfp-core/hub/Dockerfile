FROM python:3.10-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl iputils-ping \
     && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir fastapi uvicorn[standard] requests redis

WORKDIR /app

COPY hub.py /app/

ENV REDIS_URL=redis://redis:6379

EXPOSE 8080
CMD ["python","-m","uvicorn","hub:app","--host","0.0.0.0","--port","8080","--log-level","warning"]
