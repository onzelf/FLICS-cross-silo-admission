FROM python:3.10-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl iputils-ping \
     && rm -rf /var/lib/apt/lists/*
     
RUN pip install --no-cache-dir fastapi uvicorn[standard] requests cryptography pynacl

WORKDIR /app
COPY app.py frontend_impl.py /app/
COPY static /app/static

EXPOSE 80
CMD ["python","-m","uvicorn","app:app","--host","0.0.0.0","--port","80","--log-level","info"]
