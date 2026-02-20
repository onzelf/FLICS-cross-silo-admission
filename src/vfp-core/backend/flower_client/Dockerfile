FROM python:3.10-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc && \
    rm -rf /var/lib/apt/lists/*

# Install PyTorch CPU-only
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu \
    torch torchvision

# Install Flower
RUN pip install --no-cache-dir flwr

WORKDIR /app
COPY client.py .

ENV ROLE=even
ENV SERVER_ADDRESS=flower-backend:8080
ENV LOCAL_EPOCHS=1
ENV LEARNING_RATE=0.01

CMD ["python", "client.py"]
